#!/usr/bin/env python3
"""Generate the saved objects the console ships with.

Written as a generator rather than hand-edited ndjson because every one of these
objects embeds JSON *inside* JSON strings (visState, searchSourceJSON,
panelsJSON), and hand-maintaining that is how a dashboard ends up subtly broken
in a way nobody notices until they open it.

    python3 opensearch/dashboards/build.py > opensearch/dashboards/aldgate.ndjson

The committed .ndjson is what bootstrap imports; regenerate it when changing this.
"""
import json
import sys

SYSLOG = "aldgate-syslog"   # index-pattern id, matching bootstrap.sh
SNMP = "aldgate-snmp"
objects = []


def ref(pattern=SYSLOG, name="kibanaSavedObjectMeta.searchSourceJSON.index"):
    return {"name": name, "type": "index-pattern", "id": pattern}


def search_source(pattern=SYSLOG, query="", filters=None):
    return json.dumps({
        "query": {"query": query, "language": "kuery"},
        "filter": filters or [],
        "indexRefName": "kibanaSavedObjectMeta.searchSourceJSON.index",
    })


def vis(vid, title, description, vis_state, pattern=SYSLOG, query=""):
    objects.append({
        "id": vid, "type": "visualization", "version": 1,
        "attributes": {
            "title": title,
            "description": description,
            "visState": json.dumps(vis_state),
            "uiStateJSON": "{}",
            "kibanaSavedObjectMeta": {"searchSourceJSON": search_source(pattern, query)},
        },
        "references": [ref(pattern)],
    })


def metric(vid, title, description, query, pattern=SYSLOG):
    vis(vid, title, description, {
        "title": title, "type": "metric", "aggs": [
            {"id": "1", "enabled": True, "type": "count", "schema": "metric", "params": {}},
        ],
        "params": {"metric": {"percentageMode": False, "style": {"fontSize": 48},
                              "labels": {"show": True}}},
    }, pattern, query)


def terms_bar(vid, title, description, field, size=12, query="", pattern=SYSLOG):
    vis(vid, title, description, {
        "title": title, "type": "horizontal_bar", "aggs": [
            {"id": "1", "enabled": True, "type": "count", "schema": "metric", "params": {}},
            {"id": "2", "enabled": True, "type": "terms", "schema": "segment",
             "params": {"field": field, "orderBy": "1", "order": "desc", "size": size,
                        "otherBucket": False, "missingBucket": False}},
        ],
        "params": {"type": "histogram", "addLegend": False, "addTimeMarker": False,
                   "categoryAxes": [{"id": "CategoryAxis-1", "type": "category",
                                     "position": "left", "show": True, "scale": {"type": "linear"},
                                     "labels": {"show": True, "truncate": 100}}],
                   "valueAxes": [{"id": "ValueAxis-1", "name": "LeftAxis-1", "type": "value",
                                  "position": "bottom", "show": True,
                                  "scale": {"mode": "normal", "type": "linear"},
                                  "labels": {"show": True, "rotate": 0, "filter": True,
                                             "truncate": 100},
                                  "title": {"text": "Messages"}}],
                   "seriesParams": [{"show": True, "type": "histogram", "mode": "normal",
                                     "data": {"label": "Messages", "id": "1"},
                                     "valueAxis": "ValueAxis-1", "drawLinesBetweenPoints": True,
                                     "showCircles": True}]},
    }, pattern, query)


def over_time(vid, title, description, query="", pattern=SYSLOG, time_field="timestamp",
              split_field=None):
    aggs = [
        {"id": "1", "enabled": True, "type": "count", "schema": "metric", "params": {}},
        {"id": "2", "enabled": True, "type": "date_histogram", "schema": "segment",
         "params": {"field": time_field, "timeRange": {"from": "now-24h", "to": "now"},
                    "useNormalizedOpenSearchInterval": True, "interval": "auto",
                    "drop_partials": False, "min_doc_count": 1, "extended_bounds": {}}},
    ]
    if split_field:
        aggs.append({"id": "3", "enabled": True, "type": "terms", "schema": "group",
                     "params": {"field": split_field, "orderBy": "1", "order": "desc",
                                "size": 8, "otherBucket": False, "missingBucket": False}})
    vis(vid, title, description, {
        "title": title, "type": "area", "aggs": aggs,
        "params": {"type": "area", "grid": {"categoryLines": False},
                   "categoryAxes": [{"id": "CategoryAxis-1", "type": "category",
                                     "position": "bottom", "show": True,
                                     "scale": {"type": "linear"},
                                     "labels": {"show": True, "truncate": 100}}],
                   "valueAxes": [{"id": "ValueAxis-1", "name": "LeftAxis-1", "type": "value",
                                  "position": "left", "show": True,
                                  "scale": {"mode": "normal", "type": "linear"},
                                  "labels": {"show": True, "rotate": 0, "filter": False,
                                             "truncate": 100},
                                  "title": {"text": "Messages"}}],
                   "seriesParams": [{"show": True, "type": "area", "mode": "stacked",
                                     "data": {"label": "Messages", "id": "1"},
                                     "drawLinesBetweenPoints": True, "showCircles": False,
                                     "interpolate": "linear", "valueAxis": "ValueAxis-1"}],
                   "addTimeMarker": False, "addLegend": bool(split_field),
                   "legendPosition": "right"},
    }, pattern, query)


def pie(vid, title, description, field, query="", pattern=SYSLOG, size=10):
    vis(vid, title, description, {
        "title": title, "type": "pie", "aggs": [
            {"id": "1", "enabled": True, "type": "count", "schema": "metric", "params": {}},
            {"id": "2", "enabled": True, "type": "terms", "schema": "segment",
             "params": {"field": field, "orderBy": "1", "order": "desc", "size": size,
                        "otherBucket": False, "missingBucket": False}},
        ],
        "params": {"type": "pie", "addTooltip": True, "addLegend": True,
                   "legendPosition": "right", "isDonut": True,
                   "labels": {"show": True, "values": True, "last_level": True,
                              "truncate": 100}},
    }, pattern, query)


def saved_search(sid, title, description, query, columns, pattern=SYSLOG, sort_field="timestamp"):
    objects.append({
        "id": sid, "type": "search", "version": 1,
        "attributes": {
            "title": title, "description": description,
            "columns": columns, "sort": [[sort_field, "desc"]],
            "kibanaSavedObjectMeta": {"searchSourceJSON": search_source(pattern, query)},
        },
        "references": [ref(pattern)],
    })


# --- the content ------------------------------------------------------------
# Chosen to answer the questions somebody actually opens a log console with:
# is anything broken, who is noisy, what changed, and is everything still
# reporting. Nothing here needs configuring after import.
metric("aldgate-total", "Messages received",
       "Everything in the selected time range, across every host and both streams.", "")
metric("aldgate-errors", "Errors or worse",
       "severity_code <= 3: error, critical, alert and emergency together.",
       "severity_code <= 3")
over_time("aldgate-volume", "Log volume over time",
          "The shape of normal. A cliff is a host that stopped sending; a spike is "
          "usually one service in a loop.")
over_time("aldgate-errors-time", "Errors or worse over time",
          "The same window filtered to error and above, split by host so a spike "
          "names its source.", query="severity_code <= 3", split_field="host")
pie("aldgate-severity", "Severity mix",
    "Proportions, not counts: a shift in this is worth looking at even when the "
    "total is flat.", "severity")
terms_bar("aldgate-hosts", "Messages by host",
          "Who is talking. A host missing from this list is not sending at all.",
          "host", size=20)
terms_bar("aldgate-programs", "Messages by program",
          "Which daemon. Usually how a spike gets a name.", "program", size=15)
terms_bar("aldgate-error-hosts", "Error sources",
          "Hosts ranked by error-or-worse, which is a different ranking from volume.",
          "host", size=15, query="severity_code <= 3")
saved_search("aldgate-search-errors", "Errors or worse",
             "Every message at error or above, newest first.",
             "severity_code <= 3",
             ["host", "program", "severity", "message"])
saved_search("aldgate-search-auth", "Authentication and SSH",
             "Logins, failures and sudo across the fleet — the first place to look "
             "after an alert about access.",
             'program:(sshd or sudo or su or dropbear) or facility:authpriv',
             ["host", "program", "severity", "message"])
saved_search("aldgate-search-traps", "SNMP traps",
             "Network devices only: link state, reboots, sensor thresholds.",
             "log_type:snmp_trap",
             ["host", "program", "severity", "message"])

panels = [
    ("aldgate-total", 0, 0, 12, 8), ("aldgate-errors", 12, 0, 12, 8),
    ("aldgate-severity", 24, 0, 24, 8),
    ("aldgate-volume", 0, 8, 24, 15), ("aldgate-errors-time", 24, 8, 24, 15),
    ("aldgate-hosts", 0, 23, 16, 18), ("aldgate-programs", 16, 23, 16, 18),
    ("aldgate-error-hosts", 32, 23, 16, 18),
    ("aldgate-search-errors", 0, 41, 48, 20),
]
panels_json, refs = [], []
for i, (pid, x, y, w, h) in enumerate(panels, start=1):
    name = "panel_%d" % i
    ptype = "search" if pid.startswith("aldgate-search") else "visualization"
    panels_json.append({
        "version": "2.19.0", "gridData": {"x": x, "y": y, "w": w, "h": h, "i": str(i)},
        "panelIndex": str(i), "embeddableConfig": {}, "panelRefName": name,
    })
    refs.append({"name": name, "type": ptype, "id": pid})

objects.append({
    "id": "aldgate-overview", "type": "dashboard", "version": 1,
    "attributes": {
        "title": "Fleet logs — overview",
        "description": "Everything the fleet has sent: volume, severity, who is "
                       "noisy and what is failing. Shipped with Aldgate; edit a copy "
                       "rather than this, so a re-run of bootstrap does not overwrite "
                       "your changes.",
        "panelsJSON": json.dumps(panels_json),
        "optionsJSON": json.dumps({"hidePanelTitles": False, "useMargins": True}),
        "version": 1,
        "timeRestore": True,
        "timeTo": "now", "timeFrom": "now-24h",
        "refreshInterval": {"pause": False, "value": 60000},
        "kibanaSavedObjectMeta": {"searchSourceJSON": json.dumps(
            {"query": {"query": "", "language": "kuery"}, "filter": []})},
    },
    "references": refs,
})

for o in objects:
    sys.stdout.write(json.dumps(o) + "\n")
