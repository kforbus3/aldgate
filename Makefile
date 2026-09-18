# Aldgate — one command per thing you actually do.
SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help
.PHONY: help up down restart logs status bootstrap health test-syslog test-snmp enroll clean render

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t22 | sed 's/^/  /'

.env:
	@echo "No .env yet. Creating one with a generated password."
	@sed "s|^ALDGATE_ADMIN_PASSWORD=.*|ALDGATE_ADMIN_PASSWORD=$$(openssl rand -base64 24)|" .env.example > .env
	@echo "Wrote .env — keep it; it is the only copy of the admin password."

render: .env ## Render vector.yaml.tmpl with the values from .env
	@set -a; . ./.env; set +a; \
	  export ALDGATE_TIMEZONE="$${ALDGATE_TIMEZONE:-UTC}"; \
	  export ALDGATE_DEVICE_MAP="$${ALDGATE_DEVICE_MAP:-}"; \
	  envsubst '$$ALDGATE_ADMIN_PASSWORD $$ALDGATE_TIMEZONE $$ALDGATE_DEVICE_MAP' < vector/vector.yaml.tmpl > vector/vector.rendered.yaml
	@chmod 600 vector/vector.rendered.yaml
	@echo "  rendered vector/vector.rendered.yaml"

up: .env render ## Start the stack and apply templates/retention/index patterns
	$(COMPOSE) up -d
	@set -a; . ./.env; set +a; ./bootstrap/bootstrap.sh

down: ## Stop the stack (data is kept in volumes)
	$(COMPOSE) down

restart: ## Restart every service
	$(COMPOSE) restart

logs: ## Follow logs for all services
	$(COMPOSE) logs -f --tail=100

status: ## Show container and cluster status
	@$(COMPOSE) ps
	@set -a; . ./.env; set +a; \
	  echo; curl -fsS -u admin:$$ALDGATE_ADMIN_PASSWORD http://localhost:9200/_cluster/health?pretty 2>/dev/null | head -12 || echo "OpenSearch not reachable"

bootstrap: .env ## Re-apply templates, retention and index patterns
	@set -a; . ./.env; set +a; ./bootstrap/bootstrap.sh

health: .env ## What is arriving, and how much of it
	@set -a; . ./.env; set +a; \
	  echo "  indices:"; \
	  curl -fsS -u admin:$$ALDGATE_ADMIN_PASSWORD "http://localhost:9200/_cat/indices/syslog-*,snmp-*?v&h=index,docs.count,store.size&s=index" 2>/dev/null | sed 's/^/    /'; \
	  echo; echo "  hosts sending in the last hour:"; \
	  curl -fsS -u admin:$$ALDGATE_ADMIN_PASSWORD -H 'Content-Type: application/json' \
	    "http://localhost:9200/syslog-*/_search" -d '{"size":0,"query":{"range":{"timestamp":{"gte":"now-1h"}}},"aggs":{"h":{"terms":{"field":"host","size":50}}}}' 2>/dev/null \
	    | python3 -c 'import json,sys; d=json.load(sys.stdin); b=d.get("aggregations",{}).get("h",{}).get("buckets",[]); print("\n".join("    %-28s %d" % (x["key"], x["doc_count"]) for x in b) or "    (nothing yet)")' 2>/dev/null || echo "    (no data yet)"

test-syslog: ## Send a test syslog message and confirm it was stored
	@logger --server $${ALDGATE_HOST:-localhost} --port 514 --udp --tag aldgate-selftest "aldgate self test $$(date +%s)" 2>/dev/null \
	  || printf '<134>%s aldgate aldgate-selftest: aldgate self test %s\n' "$$(date '+%b %e %H:%M:%S')" "$$(date +%s)" | nc -u -w1 $${ALDGATE_HOST:-localhost} 514
	@echo "  sent; waiting for it to be indexed..."; sleep 12
	@set -a; . ./.env; set +a; \
	  curl -fsS -u admin:$$ALDGATE_ADMIN_PASSWORD -H 'Content-Type: application/json' \
	    "http://localhost:9200/syslog-*/_search?size=1" \
	    -d '{"query":{"match":{"program":"aldgate-selftest"}},"sort":[{"timestamp":"desc"}]}' \
	  | python3 -c 'import json,sys; d=json.load(sys.stdin); h=d["hits"]["hits"]; print("  FOUND:", h[0]["_source"]["message"]) if h else print("  NOT FOUND — check: docker compose logs vector")'

test-snmp: ## Send a test SNMP trap (needs snmptrap on this box)
	@command -v snmptrap >/dev/null || { echo "  snmptrap not installed: apt-get install -y snmp"; exit 1; }
	snmptrap -v 2c -c public $${ALDGATE_HOST:-localhost}:162 '' 1.3.6.1.6.3.1.1.5.3 2>/dev/null || true
	@echo "  sent; check 'make health' for the snmp-* index"

enroll: ## Print the one-liner that points a host's rsyslog here
	@echo "  On the collector, run 'make enroll-playbook' for the Ansible version."
	@echo "  Manually, on any Debian/Ubuntu host:"
	@echo "    echo '*.* @@$${ALDGATE_HOST:-10.10.0.177}:514' | sudo tee /etc/rsyslog.d/60-aldgate.conf"
	@echo "    sudo systemctl restart rsyslog"

clean: ## Stop and DELETE all stored logs
	@read -p "  This deletes every stored log. Type DELETE to continue: " c; [ "$$c" = DELETE ] || exit 1
	$(COMPOSE) down -v
