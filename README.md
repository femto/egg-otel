# egg-otel

OpenTelemetry traces for [Egg](https://github.com/femto/egg), written in
Egg. Spans go to an OpenTelemetry Collector (or anything that takes
OTLP/HTTP: Jaeger, Grafana Tempo, Honeycomb's collector...) in batches,
from a thread of their own; W3C `traceparent` carries a trace from
service to service.

What Egg adds: a span is owned, so **a span that is never finished does
not compile**, on any path, error paths included. `defer
tracer.finish(a, span)` is the usual way to say so.

```egg
uses alloc, net, rand, thread, time

const otel = @import("otel")

fn main(net: Net, a: Allocator, threads: Threads, clock: Clock, rng: Random) void {
    const tp = otel.provider(threads, net, a, clock, rng, otel.config("my-service"))
    defer tp.shutdown()                   // sends what is left
    const tracer = tp.tracer()            // one per thread: tracer.clone()
    defer tracer.close()

    var span = tracer.start(a, "load user", .internal, otel.none())
    defer tracer.finish(a, span)
    span.set_int(a, "user.id", 42)
    tracer.event(a, &span, "cache miss")
    span.ok()
}
```

It needs Egg after 0.2.1 (`tx.try_send`, femto/egg#133). In a project's
`clutch.toml`:

```toml
[dependencies]
otel = { git = "https://github.com/femto/egg-otel" }
```

## Configuration

`otel.config(service)` gives OTel's defaults; change any field:

| Field | Default | Meaning |
| --- | --- | --- |
| `service` | | `service.name` in the collector |
| `endpoint` | `http://localhost:4318` | the collector's OTLP/HTTP base; spans go to `/v1/traces` (http:// only for now) |
| `batch` | 512 | spans per request |
| `interval_ms` | 5000 | a batch goes at most this long after the last |
| `queue` | 2048 | spans that may wait for the exporter; more are dropped |
| `timeout_ms` | 10000 | per request to the collector |
| `ratio` | 1.0 | share of new traces sampled (`TraceIdRatioBased`); a child follows its parent |

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
thread` (Egg checks this along the call graph); making the provider needs
`net` and `alloc` too.

## Not yet

Metrics and logs; OTLP protobuf and gRPC; https to the collector (with
egg-tls); attributes that are arrays or maps; span links; resource
attributes beyond `service.name`.

## Tests

`clutch test` checks traceparent against W3C Trace Context, the OTLP JSON
of fixed spans, sampling at its bounds, and the whole way through a
provider to a collector thread of the test (batches by size and by
time). `sh test/live.sh` (Docker) sends spans across an HTTP call to the
OpenTelemetry Collector and checks what it got: one trace, each parent
linked, the server's through the `traceparent` it was sent.
