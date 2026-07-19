# OpenTelemetry Go Auto-Instumentation Sandbox

Personal playground for OTEL Go auto-instumentation.

- OTEL Collector operator injected sidecars
- Adding custom attributes to auto-instrumented gRPC spans
- Kafka auto-instumentation

Debug exporter and Tempo for poking around.

This repo will probably not work as-is on your machine. But it
may be a useful starting point for your own experimentation.

## Uses Talos on KVM
Originally used `microk8s` but the eBPF auto-instumentation
uses a kernel wall clock that doesn't take suspension time into
account. As such the Go SDK reported time and eBPF auto-
instrumented time were off by the accumulated time my
workstation has been suspended since I last restarted it, which
added up to 11d.

