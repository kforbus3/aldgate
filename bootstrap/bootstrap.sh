#!/usr/bin/env bash
# Apply the index templates, the retention policy, and the saved index patterns
# that make Dashboards usable on first open.
#
# Idempotent on purpose: it runs on every `make up`, so a fresh box and a box
# that has been running for a month both end up in the same state, and nobody
# has to remember whether they did this step.
set -euo pipefail

OS_URL="${OS_URL:-http://localhost:9200}"
DASH_URL="${DASH_URL:-http://localhost:5601}"
RETENTION_DAYS="${ALDGATE_RETENTION_DAYS:-30}"
: "${ALDGATE_ADMIN_PASSWORD:?set ALDGATE_ADMIN_PASSWORD (see .env)}"
AUTH=(-u "admin:${ALDGATE_ADMIN_PASSWORD}")
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '  %s\n' "$*"; }

wait_for_opensearch() {
  say "waiting for OpenSearch at ${OS_URL} ..."
  for _ in $(seq 1 90); do
    if curl -fsS "${AUTH[@]}" "${OS_URL}/_cluster/health" >/dev/null 2>&1; then
      say "OpenSearch is up"
      return 0
    fi
    sleep 5
  done
  echo "OpenSearch did not become reachable. Try: docker compose logs opensearch" >&2
  return 1
}

put() { # put <description> <path> <file-or-->
  local what="$1" path="$2" body="$3" code
  code=$(curl -s -o /tmp/aldgate-put.out -w '%{http_code}' -X PUT "${AUTH[@]}" \
    -H 'Content-Type: application/json' "${OS_URL}${path}" --data-binary "@${body}")
  if [[ "$code" =~ ^2 ]]; then
    say "${what}: ok"
  else
    say "${what}: HTTP ${code}"
    sed 's/^/      /' /tmp/aldgate-put.out >&2 || true
    return 1
  fi
}

wait_for_opensearch

# Retention: the policy file carries a placeholder so the window is a setting
# rather than an edit to a JSON file somebody has to find.
tmp_policy="$(mktemp)"
sed "s/RETENTION_DAYS/${RETENTION_DAYS}/" "${HERE}/opensearch/ism/retention.json" > "$tmp_policy"
# ISM rejects a create for a policy that exists, so update-if-present.
if curl -fsS "${AUTH[@]}" "${OS_URL}/_plugins/_ism/policies/aldgate-retention" >/dev/null 2>&1; then
  seq=$(curl -fsS "${AUTH[@]}" "${OS_URL}/_plugins/_ism/policies/aldgate-retention" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["_seq_no"], d["_primary_term"])')
  read -r sno pterm <<<"$seq"
  put "retention policy (${RETENTION_DAYS}d, updated)" \
      "/_plugins/_ism/policies/aldgate-retention?if_seq_no=${sno}&if_primary_term=${pterm}" "$tmp_policy"
else
  put "retention policy (${RETENTION_DAYS}d, created)" \
      "/_plugins/_ism/policies/aldgate-retention" "$tmp_policy"
fi
rm -f "$tmp_policy"

put "syslog index template" "/_index_template/aldgate-syslog" "${HERE}/opensearch/templates/syslog.json"
put "snmp index template"   "/_index_template/aldgate-snmp"   "${HERE}/opensearch/templates/snmp.json"

# Dashboards index patterns. Without these, opening Discover asks the user to
# create one before they can see anything -- the first impression of the whole
# system is a configuration form.
create_index_pattern() { # <id> <title> <time-field>
  local id="$1" title="$2" tf="$3" code
  code=$(curl -s -o /tmp/aldgate-dash.out -w '%{http_code}' -X POST \
    "${DASH_URL}/api/saved_objects/index-pattern/${id}?overwrite=true" \
    "${AUTH[@]}" -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"attributes\":{\"title\":\"${title}\",\"timeFieldName\":\"${tf}\"}}")
  if [[ "$code" =~ ^2 ]]; then say "index pattern ${title}: ok"
  else say "index pattern ${title}: HTTP ${code} (Dashboards may still be starting; re-run 'make bootstrap')"; fi
}

# Probed WITH credentials. Dashboards answers 401 to an anonymous request once
# the security plugin is on, and an unauthenticated gate read that as "not
# running" while it was serving perfectly -- so the index patterns were skipped
# on every run and Discover kept asking the user to create one.
dash_up=false
for _ in $(seq 1 30); do
  if curl -fsS "${AUTH[@]}" "${DASH_URL}/api/status" >/dev/null 2>&1; then dash_up=true; break; fi
  sleep 5
done
if [ "$dash_up" = true ]; then
  create_index_pattern "aldgate-syslog" "syslog-*" "timestamp"
  create_index_pattern "aldgate-snmp"   "snmp-*"   "@timestamp"
else
  say "Dashboards not reachable yet; re-run 'make bootstrap' to add its index patterns"
fi

say "bootstrap complete"
