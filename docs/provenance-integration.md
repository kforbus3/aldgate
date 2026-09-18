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

See `aldgate.md` in Provenance's docs for the shipped behaviour.
