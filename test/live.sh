#!/bin/sh
# test/live.egg against the OpenTelemetry Collector (contrib, in Docker),
# which writes what it receives to a file; then the spans in it are
# checked: three, one trace, each parent the span that made it, the
# server's from the traceparent it was sent.
#   CLUTCH=path/to/clutch sh test/live.sh
set -eu
# Only what this script sets: OTEL_* settings in the environment (another
# backend, its token, OTEL_SDK_DISABLED, a service name) must neither
# send these spans elsewhere nor change what the collector gets.
for v in $(env | sed -n 's/^\(OTEL_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$v"
done
# The collector is local: past any proxy the environment names.
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'docker rm -f egg-otel-collector >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
cat > "$work/config.yaml" <<'YAML'
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  file:
    path: /out/spans.json
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [file]
YAML
chmod 777 "$work"
docker run -d --name egg-otel-collector -p 4318:4318 \
  -v "$work/config.yaml:/etc/otelcol-contrib/config.yaml:ro" -v "$work:/out" \
  otel/opentelemetry-collector-contrib:0.115.1 >/dev/null
# Until it takes requests.
i=0
until python3 -c 'import urllib.request as u; u.urlopen(u.Request("http://127.0.0.1:4318/v1/traces", b"{}", {"Content-Type": "application/json"}), timeout=2)' 2>/dev/null; do
  i=$((i + 1)); [ $i -lt 60 ] || { docker logs egg-otel-collector; exit 1; }
  sleep 1
done
cd "$here"
# clutch test builds it (and, without OTEL_LIVE_ENDPOINT, runs it as a
# test that does nothing); then it runs against the collector.
"${CLUTCH:-clutch}" test live >/dev/null
OTEL_LIVE_ENDPOINT=http://127.0.0.1:4318 ./build/test/live
# The file exporter writes when it flushes.
i=0
until [ -s "$work/spans.json" ] && grep -q '"GET /hello"' "$work/spans.json"; do
  i=$((i + 1)); [ $i -lt 30 ] || { echo "no spans in the collector's file"; docker logs egg-otel-collector; exit 1; }
  sleep 1
done
python3 - "$work/spans.json" <<'PY'
import json, sys
spans = []
for line in open(sys.argv[1]):
    for rs in json.loads(line)["resourceSpans"]:
        svc = {a["key"]: a["value"] for a in rs["resource"]["attributes"]}
        assert svc["service.name"] == {"stringValue": "egg-otel-live"}, svc
        for ss in rs["scopeSpans"]:
            spans += ss["spans"]
by = {s["name"]: s for s in spans}
assert sorted(by) == ["GET", "GET /hello", "live test"], sorted(by)
root, call, server = by["live test"], by["GET"], by["GET /hello"]
assert len({s["traceId"] for s in spans}) == 1, "one trace"
assert "parentSpanId" not in root or root["parentSpanId"] == "", root
assert call["parentSpanId"] == root["spanId"], "client under root"
assert server["parentSpanId"] == call["spanId"], "server under the client, by traceparent"
assert call["kind"] == "SPAN_KIND_CLIENT" or call["kind"] == 3, call["kind"]
assert server["kind"] == "SPAN_KIND_SERVER" or server["kind"] == 2, server["kind"]
attrs = lambda s: {a["key"]: a["value"] for a in s.get("attributes", [])}
assert attrs(server)["http.route"] == {"stringValue": "/hello"}
assert attrs(server)["http.response.status_code"] == {"intValue": "200"}
assert attrs(call)["http.response.status_code"] == {"intValue": "200"}
assert root["events"][0]["name"] == "called"
assert root["status"].get("code") in ("STATUS_CODE_OK", 1), root["status"]
for s in spans:
    assert int(s["endTimeUnixNano"]) >= int(s["startTimeUnixNano"]) > 1700000000000000000
print("collector: 3 spans, one trace, parents linked across the HTTP call")
PY
