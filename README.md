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

**MikroTik RouterOS**

    /system logging action add name=aldgate target=remote remote=<collector> remote-port=514
    /system logging add topics=info,error,warning,critical action=aldgate
    /snmp set enabled=yes trap-target=<collector> trap-version=2 trap-community=public

**OpenWrt**

    uci set system.@system[0].log_ip='<collector>'
    uci set system.@system[0].log_port='514'
    uci set system.@system[0].log_proto='tcp'
    uci commit system && /etc/init.d/log restart

**Proxmox** — it is Debian; use the playbook.

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

SNMP traps land in `snmp-*` with the trap variables MIB-translated, e.g.
`snmp_trap.ifIndex`. Note the shapes differ: trap fields nest under
`snmp_trap.*` and their tags under `tag.*`, because that is how Telegraf's
OpenSearch output structures a document.

## Retention

Daily indices, read-only after two days, deleted after 30. Change the window:

    ALDGATE_RETENTION_DAYS=90 make bootstrap

## What is exposed

| Port | Who should reach it |
|---|---|
| 514/udp, 514/tcp, 6514/tcp | every host and device on the LAN |
| 162/udp | network devices |
| 5601 | the UI. Set `ALDGATE_UI_BIND=127.0.0.1` once Provenance proxies it |
| 9200 | **loopback only** — the host's own tooling. Never the LAN |

## Notes worth keeping

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
