# Aldgate

Log and SNMP collection for the whole network, with a search UI that is actually
usable. Built to **receive**: hosts and devices send here; nothing here reaches
out to scrape.

    syslog (514/udp, 514/tcp, 6514/tls) ──► Vector ──┐
                                                     ├──► OpenSearch ──► Dashboards
    SNMP traps (162/udp) ─────────────────► Telegraf ┘

| Component | Why this one |
|---|---|
| **OpenSearch 2.19** + Dashboards | Apache-2.0, full-text search, and Alerting and Security Analytics (SIEM rules) included rather than gated behind a licence tier. |
| **Vector** | One small Rust binary that speaks syslog properly (RFC3164 *and* 5424), transforms without a JVM, and buffers to disk so a restart does not lose what it already received. |
| **Telegraf** | Vector cannot do SNMP. Telegraf receives traps *and* can poll devices, so one agent covers both halves. |

## Deploy

On a Debian host with Docker:

    git clone <this repo> aldgate && cd aldgate
    make up

That is the whole thing. `make up` generates `.env` with a random admin
password, renders the Vector config, starts the four services, and applies the
index templates, the retention policy and the Dashboards index patterns. It is
idempotent — run it again any time.

Then open **http://<host>:5601** and log in as `admin` with the password in
`.env`.

    make health          what is arriving, and from which hosts
    make status          container and cluster state
    make test-syslog     send a message and confirm it was stored
    make logs            follow everything
    make bootstrap       re-apply templates/retention/index patterns

## Enrol a host

Any Debian/Ubuntu machine, via Provenance (Automation → Playbooks) or directly:

    ansible-playbook -i <inventory> ansible/enroll-syslog.yml -e aldgate_host=<collector>

It installs rsyslog if the host has only journald (every cloud-image VM does),
turns on `ForwardToSyslog`, and writes a **disk-queued** forwarding rule so a
collector outage does not become a hole in the host's history.

Container logs are a separate hole — docker keeps them to itself:

    ansible-playbook -i <inventory> ansible/enroll-docker-logs.yml -e aldgate_host=<collector>

That sets the daemon's default log driver. It deliberately does not recreate
existing containers; they pick it up next time they are deployed.

### Network devices

Network gear rarely allows key auth, so these run through Provenance, which
holds the device passwords. Both are plain playbooks and work with
`ansible-playbook` too if you have credentials of your own.

**MikroTik RouterOS** — `ansible/enroll-routeros.yml`. Syslog and SNMP traps in
one pass. It does four things worth knowing about:

- points the existing `remote` logging action at the collector, because the four
  default rules already route to it — on a stock device there is nothing to add
- `syslog-time-format=iso8601`, so the timestamp carries an offset (see
  [Timestamps](#timestamps) for what the default costs you)
- `syslog-severity=auto`, so severity comes from the logging topic. A device with
  a fixed severity stamps every message with it: the cAP here was sending "admin
  logged out" as **emerg**, so a search for "error or worse" returned its whole
  log and buried everything real
- narrows the SNMP community to the collector, because enabling SNMP for traps
  also opens the read-only agent and the community list ships as `::/0`

Both MikroTik devices here had their `remote` action aimed at a host where
nothing listens — configured, forwarding, and arriving nowhere. Check where
yours points before assuming it is unconfigured:

    /system logging action print detail where name=remote

**MikroTik SwOS** (the CRS3xx switches) has neither syslog nor traps. It is
configured over HTTP only; there is nothing to enrol.

**MikroTik SwOS** (the CRS3xx switches) has neither syslog nor traps. It is
configured over HTTP only; there is nothing to enrol.

**OpenWrt** — `ansible/enroll-openwrt.yml`. `raw` throughout, because OpenWrt
has no python and every other module needs it.

**Proxmox** — it is Debian; use the playbook.

### Naming devices

A device names itself, and it is usually wrong: the core switch here announces
itself as `mikrotik`, the factory default, so its logs arrive under a name that
matches neither its DNS name nor anything you would think to search for. An SNMP
trap is worse — it identifies its sender only by IP.

`ALDGATE_DEVICE_MAP` in `.env` settles it. It maps sending address to the name
you actually use, for both syslog and traps, so one device is one name
everywhere:

    ALDGATE_DEVICE_MAP=10.10.0.1=router,10.10.0.111=coreswitch,10.10.0.156=nas

Hosts that already know their own name need no entry. An unmapped device keeps
its IP rather than becoming "unknown" — an address you can look up beats a
placeholder.

### SNMP traps

Telegraf receives traps on 162 and hands them to Vector, which normalises them
into the **same fields as syslog** — `host`, `program`, `severity`, `message` —
so one search covers the network and the machines together. A trap has no
severity of its own, so the standard ones are classified (`linkDown` is an
error, `coldStart` a warning) and anything unrecognised is a notice.

The varbinds land in `snmp_vars` as a list of `{name, index, value}`, and the
readable rendering goes in `message`:

    linkDown: ifAdminStatus.2=2 ifIndex.2=2 ifOperStatus.2=2 sysUpTimeInstance=51871

The list shape is not cosmetic — see [Notes worth
keeping](#notes-worth-keeping).

## Searching

Dashboards → **Discover** → the `syslog-*` pattern. Every message carries the
same small set of fields, which is what makes it searchable rather than
greppable:

| Field | Use |
|---|---|
| `host`, `host_short` | which machine (`host_short` drops the domain so `web01` and `web01.example.com` group) |
| `program` | which daemon — `sshd`, `kernel`, a container name |
| `severity` / `severity_code` | words to filter, a number to compare: `severity_code <= 3` is "error or worse" |
| `facility` | syslog facility |
| `message` | the text. Full-text searchable; `message.keyword` groups identical lines |
| `timestamp` vs `received_at` | what the sender claimed vs when it arrived — they differ when a device's clock is wrong |
| `source_address` | who sent it, as an IP |

SNMP traps live in `snmp-*` and carry **every field in that table**, with the
same meanings — that is the point of routing them through Vector rather than
letting Telegraf write its own shape. So `severity_code <= 3` finds a link
dropping alongside the kernel message from the host behind it, and `host` means
the same thing in both. `log_type` separates them when you want one or the
other (`syslog` or `snmp_trap`), and traps add `oid`, `mib` and `snmp_vars`.

In Discover, add both patterns (`syslog-*` and `snmp-*`) or search `*-*`.
Provenance's Logs page already queries both.

## Retention

Daily indices, read-only after two days, deleted after 30. Change the window:

    ALDGATE_RETENTION_DAYS=90 make bootstrap

## What is exposed

| Port | Who should reach it |
|---|---|
| 514/udp, 514/tcp, 6514/tcp | every host and device on the LAN |
| 162/udp | network devices |
| 8180 | nothing. Vector's trap intake, reachable only from Telegraf on the compose network — it is not published to the host |
| 5601 | the UI. Set `ALDGATE_UI_BIND=127.0.0.1` once Provenance proxies it |
| 9200 | loopback by default. Set `ALDGATE_API_BIND=0.0.0.0` only when Provenance is on another machine and needs to broker searches |

## Timestamps

Hosts enrolled by the playbook forward **RFC5424**, which carries an explicit
UTC offset. That matters more than it sounds: RFC3164 — rsyslog's default — sends
`Sep 18 16:32:25` with no timezone at all, so a collector in UTC files a host in
EDT four hours in the past. Every time-based search then misses that host, and a
"last hour" view looks exactly like a machine that has stopped sending.

Network gear that can only speak RFC3164 is covered by `ALDGATE_TIMEZONE` in
`.env`, which tells Vector what offset to assume. Set it to the LAN's timezone.

Both timestamps are stored either way: `timestamp` is what the sender claimed,
`received_at` is when it arrived. If they disagree, the sender's clock or
timezone is wrong, and that is worth knowing rather than hiding.

## What is not forwarded

A control plane that probes every host every 30 seconds generates more log
traffic than the fleet does. Measured here before any filtering: **12,887
messages in four minutes**, of which over 90% was Provenance's own footsteps —
each probe is an SSH login, a logind session, a per-user systemd instance
starting and exiting, a sudo, and the whole thing torn down again. A log system
whose own monitoring buries the logs is not a log system.

The enrolment playbook therefore filters that churn **at the forwarding action
only**. The host's `/var/log` keeps every line — 85,808 of them on one host at the
time of writing — so nothing is destroyed and anything can be read back on the
machine itself.

Dropped: the per-user systemd instance's unit chatter (gpg-agent and ssh-agent
sockets, `app.slice`, the user runtime directory), the per-session units keyed to
the **service accounts' own UIDs**, and session open/close for the service
accounts. Kept, deliberately:

- every session for a **human** account, opened and closed
- every authentication **failure**, from anyone, service accounts included
- every `sudo`, including Provenance's — that records what actually ran as root
- logind's `New session` / `Removed session`
- anything at severity **warning or worse**, whatever it says

Result: 12,887 → 3,641 per four minutes, same 18 hosts, with errors and warnings
untouched. Tune it with `aldgate_service_accounts` in the playbook.

## Notes worth keeping

**A dotted key can reject a whole document.** Real traps name their variables
with the instance appended: `ifIndex.2`. A dot in a JSON key is a path in
OpenSearch, so `snmp_vars.ifIndex.2` collides with the `snmp_vars.ifIndex` a
previous trap created as a `long`, and the entire document is rejected with a 400
`mapper_parsing_exception`. Vector does not retry that, correctly, so the trap is
simply gone. Every hand-written test trap indexed fine; the first one from an
actual switch disappeared, and neither Telegraf nor OpenSearch said a word —
the only evidence was in Vector's sink log. Hence the fixed
`{name, index, value}` shape, which also stops the mapping growing by one field
per port per device.

**`encoding: json` on Vector's http_server does nothing.** The option is
accepted without complaint; the body still arrives as a JSON *string* in
`.message`, which the transform then overwrites. Every trap indexed as a
well-formed document with every field empty. The option is `decoding.codec`.

**`raw` hangs against RouterOS.** Ansible's paramiko connection opens an exec
channel that RouterOS never closes, so the first task sits there until something
kills the run — no error, no output, nothing to diagnose. The RouterOS playbook
uses `community.routeros.command` over `network_cli`, which speaks the console
properly. OpenWrt is fine with `raw`.

**Network gear refuses key auth**, so it cannot be enrolled from a laptop with
an SSH key — the credentials live in Provenance's vault. Run the two device
playbooks from Provenance (Automation → Playbooks); it injects the password per
host. Note that Provenance's *Run command* page cannot do this: it dials with
certificates only, so a vault-credential host fails there with a bare "unable to
authenticate".

- **OpenSearch's security plugin mandates transport TLS** and refuses to load
  without certificates. Turning off the demo config removes the thing that
  generates them, and OpenSearch dies with "Wrong Transport SSL configuration".
  The demo config therefore runs; the admin password comes from `.env`, not a
  default.
- **HTTP TLS on 9200 is off deliberately.** Nothing off this host can reach it,
  so the alternative is a self-signed certificate every client is then told not
  to verify — which looks like security and is not.
- **Vector's `${VAR}` interpolation is not used.** It left the placeholder text
  in place as the literal password and every write got 401 while the correct
  credentials sat in the environment. `make render` substitutes them instead, so
  what Vector reads is what is on disk.
- **Telegraf must use `outputs.opensearch`, not `outputs.elasticsearch`.** The
  latter reads OpenSearch's `2.19.6` as Elasticsearch 2.x and refuses. Its
  `index_name` is a Go template, not strftime — `%Y` is passed through literally
  and rejected as an uppercase index name.
