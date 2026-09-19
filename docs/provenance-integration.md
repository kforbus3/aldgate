# Viewing Aldgate logs inside Provenance

The goal is one place to look. Provenance already knows every host, brokers
access to them, and records who did what; Aldgate holds what those hosts said.
Joining the two means a host's logs are one click from the host itself.

Two surfaces, for the same reason the Kubernetes page has both:

1. **A Logs page in Provenance** — search scoped to a host, joined to the host
   inventory Provenance already has. Fast, integrated, and the answer to "what
   was this machine saying at 03:00".
2. **The Dashboards console, embedded** — proxied under Provenance's own origin
   and framed, for the analysis the built-in view should not try to reproduce:
   visualisations, alerting rules, Security Analytics.

Both go through a broker in Provenance rather than talking to OpenSearch
directly, so the OpenSearch credential stays on the collector, every query is
recorded against the person who ran it, and what a person may see is decided by
their Provenance role — the same arrangement the Kubernetes broker uses.

## Wiring it up

Four values from this collector's `.env` into Provenance's, then restart
Provenance's backend. Nothing on the collector needs to change.

On the collector:

```bash
grep -E '^ALDGATE_(ADMIN|CONSOLE)' .env      # the four passwords
```

In Provenance's `.env`:

```ini
# Where to search. The broker reaches OpenSearch directly, so this is the
# collector's address and API port -- not the Dashboards port.
PROV_ALDGATE_URL=http://<collector>:9200
PROV_ALDGATE_USER=admin
PROV_ALDGATE_PASSWORD=<ALDGATE_ADMIN_PASSWORD>

# Where to proxy the embedded console. host:port of Dashboards.
ALDGATE_HOST=<collector>:5601

# The two console tiers. Logs.View opens the console read-only, Logs.Administer
# opens it fully; Provenance picks one per request from the person's role, so no
# browser is ever sent a collector password.
PROV_ALDGATE_CONSOLE_VIEWER_PASSWORD=<ALDGATE_CONSOLE_VIEWER_PASSWORD>
PROV_ALDGATE_CONSOLE_ADMIN_PASSWORD=<ALDGATE_CONSOLE_ADMIN_PASSWORD>
```

Then, still on the collector, two settings that only matter once Provenance is
proxying it:

```ini
ALDGATE_BASEPATH=/aldgate          # Dashboards serves under the sub-path
ALDGATE_REWRITE_BASEPATH=true
ALDGATE_API_BIND=0.0.0.0           # only when Provenance is on ANOTHER machine
```

`make up` to apply them, then `make redeploy-single` on Provenance's host. The
**Logs** page appears for anyone holding `Logs.View`.

## Checking it worked

| What | Where |
|---|---|
| Logs are arriving at all | `make health` on the collector |
| Provenance can search them | the **Logs** page — an empty result with hosts listed means the search is fine and the filter is narrow |
| The console opens without a password | **Open log console** — it should land on the *Fleet logs — overview* dashboard |

If the page says no collector is configured, `PROV_ALDGATE_URL` is empty. If the
console asks for a username and password, the two `PROV_ALDGATE_CONSOLE_*` values
have not reached Provenance — it falls back to Dashboards' own login rather than
pretending to work.

See `aldgate.md` in Provenance's docs for the shipped behaviour.
