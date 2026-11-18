# egg-otel

OpenTelemetry traces for [Egg](https://github.com/femto/egg), written in
Egg. Spans go to an OpenTelemetry Collector, or straight to a backend that
takes OTLP (Better Stack, Honeycomb, Grafana Cloud, Jaeger...), over
OTLP/HTTP, `http://` or `https://`, in batches, from a thread of their own;
W3C `traceparent` carries a trace from service to service. It is
configured as every OpenTelemetry SDK is, by `OTEL_*` environment
variables.

What Egg adds: a span is owned, so **a span that is never finished does
not compile**, on any path, error paths included. `defer
tracer.finish(a, span)` is the usual way to say so.

```egg
uses alloc, args, fs, net, rand, thread, time

const otel = @import("otel")

fn main(env: Args, files: Fs, net: Net, a: Allocator, threads: Threads, clock: Clock, rng: Random) !void {
    const tp = try otel.provider(threads, net, files, a, clock, rng, otel.config_from_env(env, "my-service"))
    defer tp.close()                      // sends what is left
    const tracer = tp.tracer()            // one per thread: tracer.clone()
    defer tracer.close()

    var span = tracer.start(a, "load user", .internal, otel.none())
    defer tracer.finish(a, span)
    span.set_int(a, "user.id", 42)
    tracer.event(a, &span, "cache miss")
    span.ok()
}
```

It needs Egg after 0.2.1 (`tx.try_send`, femto/egg#133; `http.fetch_once`
as egg-tls calls it, #134; `select` compiling quickly, #135), and
[egg-tls](https://github.com/femto/egg-tls) for `https://`. In a project's
`clutch.toml`:

```toml
[dependencies]
otel = { git = "https://github.com/femto/egg-otel" }
```

## Sending to Better Stack (or any OTLP backend)

The same variables as for an SDK in any other language:

```sh
export OTEL_SERVICE_NAME=my-service
export OTEL_EXPORTER_OTLP_ENDPOINT=https://$INGESTING_HOST        # your source's
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer $SOURCE_TOKEN"
```

`tp.close()` sends what is left and stops the exporter; `tp.shutdown()`
does the same and returns what happened: spans the backend took
(`sent`), and batches and spans it did not (`failed_batches`,
`failed_spans`), with the last failure's HTTP status (`last_status`: 401
for a wrong token, 0 when no connection was made), since a span that cannot
be sent is let go rather than kept.

## Configuration

`otel.config_from_env(env, service)` reads the OpenTelemetry environment
variables over `otel.config(service)`'s defaults; or set the fields in
code:

| Field | Variable | Default | Meaning |
| --- | --- | --- | --- |
| `service` | `OTEL_SERVICE_NAME` | | `service.name` in the backend |
| `endpoint` | `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4318` | OTLP/HTTP base; spans go to `/v1/traces` under it |
| `traces_endpoint` | `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | | the full URL for spans, if set |
| `headers` | `OTEL_EXPORTER_OTLP_HEADERS` (`_TRACES_` wins) | | `key=value,...`, percent-encoded |
| `timeout_ms` | `OTEL_EXPORTER_OTLP_TIMEOUT` (`_TRACES_` wins) | 10000 | per request |
| `batch` | `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | 512 | spans per request |
| `interval_ms` | `OTEL_BSP_SCHEDULE_DELAY` | 5000 | a batch goes at most this long after the last |
| `queue` | `OTEL_BSP_MAX_QUEUE_SIZE` | 2048 | spans that may wait for the exporter; more are dropped |
| `ratio` | `OTEL_TRACES_SAMPLER`, `_ARG` | 1.0 | share of new traces sampled (`always_on`, `always_off`, `traceidratio` and `parentbased_` forms; a child always follows its parent); `OTEL_SDK_DISABLED=true` samples none |

A value that does not parse is ignored, as the spec asks. Spans go as
OTLP/HTTP JSON, which every OTLP/HTTP receiver takes;
`OTEL_EXPORTER_OTLP_PROTOCOL` is not read. For `https://`, the server's
certificate is checked against the system's roots (egg-tls).

`finish` never waits: with the queue full (or the exporter gone) the span
is dropped, not the request held up. A batch that the collector does not
take is let go too.

## Spans

`tracer.start(a, name, kind, parent)` starts one (`kind`: `.internal`,
`.server`, `.client`, `.producer`, `.consumer`; `parent`: another span's
`span.context()`, or `otel.none()` for a new trace). On a span:
`set_text`, `set_int`, `set_float`, `set_bool` (a key set again is
replaced), `rename`, `ok()`, `fail(a, message)`; `tracer.event(a, &span,
name)` marks a moment. A span that is not sampled records nothing and is
never sent, but its context still passes on.

## HTTP

With `std/http`, a server continues the caller's trace, and a client
passes its own on:

```egg
fn handle(tracer: otel.Tracer, c: TcpConn, a: Allocator, req: http.Request) !void {
    var span = tracer.server_span(a, req)          // reads traceparent
    defer tracer.finish(a, span)
    span.rename(a, "GET /users/{id}")              // method only, by default
    ...
    otel.http_status(a, &span, 200)
}

var call = tracer.client_span(a, "GET", url, span.context())
defer tracer.finish(a, call)
var headers: Buf(u8) = .empty
defer a.free(headers)
otel.inject(a, &headers, call.context())         // "traceparent: ...\r\n"
const r = try http.fetch(net, a, "GET", url, headers, "", http.options())
```

`otel.parse_traceparent` and `otel.inject` are there for anything else
that carries a trace (a queue message, say).

## Capabilities

Starting and finishing spans reads the clock and random bytes and sends
on a channel, so a module that does it declares `uses time, rand,
thread` (Egg checks this along the call graph). Making the provider needs
`net`, `fs` (the system's roots for `https://`) and `alloc` too, and
`config_from_env` needs `args`.

## Not yet

Metrics and logs; OTLP protobuf and gRPC; retrying a failed batch;
attributes that are arrays or maps; span links; resource attributes
beyond `service.name` (`OTEL_RESOURCE_ATTRIBUTES`).

## Tests

`clutch test` checks traceparent against W3C Trace Context, the OTLP JSON
of fixed spans, sampling at its bounds, the `OTEL_*` settings and header
parsing, and the whole way through a provider to a collector thread of
the test (batches by size and by time). With `OTEL_EXPORTER_OTLP_*` set,
`./build/test/live` sends a trace to that backend and prints what it
took. `sh test/live.sh` (Docker) sends spans across an HTTP call to the
OpenTelemetry Collector and checks what it got: one trace, each parent
linked, the server's through the `traceparent` it was sent.
