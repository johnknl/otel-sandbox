# OpenTelemetry Go Auto-Instrumentation Sandbox

Personal playground for OTEL Go auto-instrumentation.

_Disclaimer: this repo is intentionally permanently a work in progress, 
sometimes intentionally shitty, and not to be used as an example of how to do anything._

## Sandbox Architecture

```mermaid
graph TD
  FE[frontend]
  BE[backend]
  CO[consumer]
  K[(Kafka)]

  OP[OTel Operator]
  OCOL[OTel Collector]
  T[Tempo]
  J[Jaeger]

  FE -->|gRPC| BE
  BE --> K --> CO

  OP -. injects sidecar .-> FE
  OP -. injects sidecar .-> BE
  OP -. injects sidecar .-> CO

  FE -->|OTLP spans| OCOL
  BE -->|OTLP spans| OCOL
  CO -->|OTLP spans| OCOL

  OCOL -->|exports| T
  OCOL -->|exports| J
```

## eBPF auto-instrumentation findings

### Wall clock shenanigans

Originally this sandbox used `microk8s` but the eBPF auto-instrumentation
uses a kernel wall clock that does not take suspension time into account.
As such, the Go SDK reported time and eBPF auto-instrumented time were
off by the accumulated time my workstation had been suspended since last
restart, which added up to 11 days. Moving to KVM + Talos solved this.

Not something you would encounter in many production deployments.

### Version sensitivity

The eBPF auto-instrumentation is sensitive to memory layout and internal
library structures. It does not use only public package APIs, so even patch
releases can break tracing.

In this sandbox, `frontend` and `backend` communicate using gRPC. I had to
pin `google.golang.org/grpc` to `v1.82.0` because `v1.82.1` did not (yet)
work with `v0.24.0` of the Go auto-instrumentation image.

For production deployments, you likely want multiple `Instrumentation` CRs
for different runtime/library combinations.

## Context propagation issues

Current contrived flow:

- `frontend` sends a gRPC request to `backend` every 5 seconds
- `backend` responds to `frontend`, and also publishes a Kafka message
- `consumer` reads and logs the Kafka message (arguably out-of-band)

Observations so far (WiP):

- the span `backend -> consumer` is sporadically added a root frontend trace 
  but when it isn't it does not start a new trace either
  (seems like parent span is closed depending on timings because of async)
- the span `frontend -> backend` stops being collected a couple of minutes
  after a cold boot of the cluster

```mermaid
sequenceDiagram
  autonumber
  participant FE as frontend
  participant BE as backend
  participant K as Kafka
  participant C as consumer

  FE->>BE: gRPC request
  BE->>K: publish message
  BE-->>FE: gRPC response

  C->>K: fetch message
```
