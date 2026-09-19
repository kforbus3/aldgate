#!/usr/bin/env bash
# Apply the index templates, the retention policy, and the saved index patterns
# that make Dashboards usable on first open.
#
# Idempotent on purpose: it runs on every `make up`, so a fresh box and a box
# that has been running for a month both end up in the same state, and nobody
# has to remember whether they did this step.
set -euo pipefail

OS_URL="${OS_URL:-http://localhost:9200}"
# Dashboards' API lives UNDER the base path when one is set, which it is whenever
# Provenance proxies the console at /aldgate. Without this the readiness check
# asked for /api/status, got a 404, and reported "Dashboards not reachable yet" --
# so every run skipped the index patterns and the dashboard, on a Dashboards that
# was answering perfectly. A 404 is not unreachable, and the check now looks where
# the API actually is.
DASH_URL="${DASH_URL:-http://localhost:5601${ALDGATE_BASEPATH:-}}"
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
# Everything saved here goes to the GLOBAL tenant.
#
# Multi-tenancy is on, and without this header a saved object lands in the
# private tenant of whoever created it -- so the index patterns this script
# created went into `admin`'s private space, in .kibana_92668751_admin_1, and
# every other account opened the console to no data sources at all. Provenance
# pins console sessions to the same tenant, so what is imported here is what a
# person sees.
TENANT=(-H 'securitytenant: global')

create_index_pattern() { # <id> <title> <time-field>
  local id="$1" title="$2" tf="$3" code
  code=$(curl -s -o /tmp/aldgate-dash.out -w '%{http_code}' -X POST \
    "${DASH_URL}/api/saved_objects/index-pattern/${id}?overwrite=true" \
    "${AUTH[@]}" "${TENANT[@]}" -H 'osd-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"attributes\":{\"title\":\"${title}\",\"timeFieldName\":\"${tf}\"}}")
  if [[ "$code" =~ ^2 ]]; then say "index pattern ${title}: ok"
  else say "index pattern ${title}: HTTP ${code} (Dashboards may still be starting; re-run 'make bootstrap')"; fi
}

# The dashboard, visualisations and saved searches the console ships with.
#
# A log console that opens empty is a tool you have to build before it is worth
# anything, and everybody builds the same first five panels. These are imported
# on every run with overwrite=true, so an upgrade brings improvements -- which is
# also why the dashboard's own description says to edit a COPY.
import_saved_objects() {
  local file="${HERE}/opensearch/dashboards/aldgate.ndjson" code
  [ -f "$file" ] || { say "no saved objects to import"; return 0; }
  code=$(curl -s -o /tmp/aldgate-import.out -w '%{http_code}' -X POST \
    "${DASH_URL}/api/saved_objects/_import?overwrite=true" \
    "${AUTH[@]}" "${TENANT[@]}" -H 'osd-xsrf: true' \
    -F "file=@${file};type=application/ndjson")
  if [[ "$code" =~ ^2 ]] && grep -q '"success":true' /tmp/aldgate-import.out; then
    say "console dashboard and saved searches: ok"
  else
    say "console dashboard: HTTP ${code}"
    sed 's/^/      /' /tmp/aldgate-import.out >&2 || true
  fi
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
  import_saved_objects
else
  say "Dashboards not reachable yet; re-run 'make bootstrap' to add its index patterns"
fi

# --- console tiers -----------------------------------------------------------
# Two OpenSearch accounts, so Provenance can open the log console AS somebody
# without anyone typing a password: it injects one of these per request based on
# the person's Provenance role. prov_viewer can read the two log indices and
# nothing else, and Dashboards puts its UI in read-only mode for it
# (kibana_read_only); prov_admin is unrestricted.
#
# The credentials live in .env and .env is the source of truth: every run
# RE-APPLIES the password from there rather than skipping when the user exists.
# The first version wrote the generated password to .env and then skipped if the
# line was present -- so when user creation had failed, .env kept credentials
# that had never been set on anything, and the skip made that permanent. A
# reconcile is idempotent; a skip only looks idempotent.
#
# The password is written to .env only AFTER the account exists, for the same
# reason: a credential on disk should never describe a user that does not.
gen_password() { # 22 random chars plus a fixed suffix, to satisfy the policy
  printf '%sAa1!' "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)"
}

env_get() { # env_get <KEY> -> value from .env, empty if absent
  sed -n "s/^$1=//p" "${HERE}/.env" 2>/dev/null | head -1
}

env_set() { # env_set <KEY> <VALUE> -- append or replace, in place
  local key="$1" val="$2"
  if grep -q "^${key}=" "${HERE}/.env" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v "^${key}=" "${HERE}/.env" > "$tmp"
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    cat "$tmp" > "${HERE}/.env"   # keep the original file's permissions
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >> "${HERE}/.env"
  fi
}

ensure_console_user() { # <username> <env-key> <roles-json> <what>
  local user="$1" key="$2" roles="$3" what="$4" pw code body
  pw="$(env_get "$key")"
  [ -n "$pw" ] || pw="$(gen_password)"
  body="$(mktemp)"
  python3 - "$pw" "$roles" > "$body" <<'PYJSON'
import json, sys
json.dump({"password": sys.argv[1],
           "opendistro_security_roles": json.loads(sys.argv[2]),
           "attributes": {"managed_by": "aldgate-bootstrap"}}, sys.stdout)
PYJSON
  code=$(curl -s -o /tmp/aldgate-user.out -w '%{http_code}' -X PUT "${AUTH[@]}" \
    -H 'Content-Type: application/json' \
    "${OS_URL}/_plugins/_security/api/internalusers/${user}" --data-binary "@${body}")
  rm -f "$body"
  if [[ "$code" =~ ^2 ]]; then
    env_set "$key" "$pw"
    say "console ${what} (${user}): ok"
  else
    say "console ${what} (${user}): HTTP ${code} -- the console will fall back to asking for a password"
    sed 's/^/      /' /tmp/aldgate-user.out >&2 || true
  fi
}

if curl -fsS "${AUTH[@]}" "${OS_URL}/_plugins/_security/api/roles/all_access" >/dev/null 2>&1; then
  put "console reader role" "/_plugins/_security/api/roles/aldgate_reader" "${HERE}/opensearch/security/aldgate_reader.json"
  # kibana_user is what grants a Dashboards account access to the saved-object
  # index at all; kibana_read_only is only the UI mode. With just the latter the
  # console opened, found the global tenant, and then 403'd on
  # indices:data/read/search against .kibana_1 -- a console with no data sources,
  # which is exactly what it looked like from the outside.
  ensure_console_user prov_viewer ALDGATE_CONSOLE_VIEWER_PASSWORD \
    '["aldgate_reader","kibana_user","kibana_read_only"]' "viewer"
  ensure_console_user prov_admin  ALDGATE_CONSOLE_ADMIN_PASSWORD \
    '["all_access"]' "administrator"
else
  # Needs plugins.security.restapi.roles_enabled to include all_access, and note
  # it must be COMMA-SEPARATED in compose: the bracketed JSON form is passed
  # through by -E as one literal string, matches no role, and every call here
  # comes back 403 while the setting looks right.
  say "security REST API is closed; skipping console tiers (see docker-compose.yml)"
fi

say "bootstrap complete"
