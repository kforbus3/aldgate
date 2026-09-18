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

**MikroTik RouterOS.** Note `syslog-time-format=iso8601` — the default BSD
format carries no timezone, and see [Timestamps](#timestamps) for what that
costs. Check `/system/logging/print` first: the four default rules already point
at a `remote` action, so on most installs there is nothing to add and one thing
to repoint.

    /system logging action set [find name=remote] remote=<collector> remote-port=514 \
        remote-log-format=syslog syslog-time-format=iso8601
    /snmp set enabled=yes trap-target=<collector> trap-version=2 trap-community=public \
        trap-generators=interfaces,temp-exception

Enabling SNMP for traps also opens the read-only agent, so restrict who may
query it — the community list is `::/0` out of the box:

    /snmp community set [find name=public] addresses=<collector>/32

**MikroTik SwOS** (the CRS3xx switches) has neither syslog nor traps. It is
configured over HTTP only; there is nothing to enrol.

**OpenWrt**

    uci set system.@system[0].log_ip='<collector>'
    uci set system.@system[0].log_port='514'
    uci set system.@system[0].log_proto='tcp'
    uci commit system && /etc/init.d/log restart

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

**Not everything can be enrolled from here.** The OpenWrt router and the NAS
refuse key auth, so their forwarding has to be set from their own UIs. The
commands are above; nothing else is needed on the collector.

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
