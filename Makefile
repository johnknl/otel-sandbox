BIN_DIR=$(CURDIR)/bin
CLUSTER = otel-sandbox
KUBE_CONTEXT=$(CLUSTER)
REGISTRY = 10.0.0.1:5000
REGISTRY_PUSH := 127.0.0.1:5000
GRAFANA_NODEPORT := 30030
AKHQ_NODEPORT := 30181
PROTO_SRCS := $(shell find proto/ -type f -name '*.proto')
MODULE := $(shell go list -m)
KUBECTL=kubectl --context $(KUBE_CONTEXT)
HELM=helm --kube-context $(KUBE_CONTEXT)

PROTOC_VERSION=34.1
PROTOC_SHA256=af27ea66cd26938fe48587804ca7d4817457a08350021a1c6e23a27ccc8c6904 
PROTOC_ZIP=protoc-$(PROTOC_VERSION)-linux-x86_64.zip

#  get random (first) node IP address to access NodePort services
NODE_IP ?= $(shell $(KUBECTL) get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

.PHONY: help
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Available targets:\n"} /^[a-zA-Z0-9_.%\/-]+:.*## / {printf "  make %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: build
build: proto registry ## Build and push the services to the registry
	docker build -t $(REGISTRY_PUSH)/backend:latest --target backend .
	docker build -t $(REGISTRY_PUSH)/frontend:latest --target frontend .
	docker build -t $(REGISTRY_PUSH)/consumer:latest --target consumer .

	docker push $(REGISTRY_PUSH)/backend:latest
	docker push $(REGISTRY_PUSH)/frontend:latest
	docker push $(REGISTRY_PUSH)/consumer:latest

# This is a bit of pain but otherwise we have to setup TLS or add extra host
# Docker setup to configure insecure-resitries in daemon.json. We do configure
# Talos to allow insecure traffic with thevm network bridge gateway.
.PHONY: registry
registry: ## Run local container registry on :5000
	@docker rm -f otel-sandbox-registry >/dev/null 2>&1 || true
	@docker run -d --restart=always \
		--network host \
		-e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
		--name otel-sandbox-registry \
		registry:2 >/dev/null

.PHONY: services
services: ns build ## Update the services
	$(KUBECTL) apply -n sandbox -k deploy/
	$(KUBECTL) -n sandbox rollout restart deployment frontend backend consumer

.PHONY: proto
proto: tools ### Generate Go code from proto files
	$(BIN_DIR)/protoc \
	  --go_out=. \
	  --go_opt=module=$(MODULE) \
	  --go-grpc_out=. \
	  --go-grpc_opt=module=$(MODULE) \
	  --plugin=protoc-gen-go-grpc="$(BIN_DIR)/protoc-gen-go-grpc" \
	  $(PROTO_SRCS)

bin/protoc:
	curl --fail -L -O \
  	"https://github.com/protocolbuffers/protobuf/releases/download/v$(PROTOC_VERSION)/$(PROTOC_ZIP)"

	@echo "$(PROTOC_SHA256) $(PROTOC_ZIP)" | sha256sum -c -

	unzip -o "$(PROTOC_ZIP)" bin/protoc

	rm "$(PROTOC_ZIP)"

.PHONY: fmt
fmt: ## Format Go code
	go fmt ./...
	$(BIN_DIR)/golangci-lint run --fix

.PHONY: lint
lint: tools ## Run golangci-lint
	$(BIN_DIR)/golangci-lint run

.PHONY: tools
tools: bin/protoc ## Build and install tools defined in tools/tools.go to $(BIN_DIR)
	mkdir -p "$(BIN_DIR)"
	@for tool in $$(awk -F'"' '/^\t_ "[^"]+"/ {print $$2}' tools/tools.go); do \
		GOBIN="$(BIN_DIR)" go -C tools install $$tool; \
	done

.PHONY: ns
ns: ## Create the sandbox namespace
	$(KUBECTL) create ns sandbox || true

	# Talos by default enforces the pod security admission controller 
	# on all namespaces, but this is not a security testing sandbox
	# so we'll just bypass that 👌.
	$(KUBECTL) label ns sandbox \
  	pod-security.kubernetes.io/enforce=privileged \
  	pod-security.kubernetes.io/audit=privileged \
  	pod-security.kubernetes.io/warn=privileged

.PHONY: open
open: ## Open the Grafana and AKHQ dashboards in the browser
	xdg-open "http://$(NODE_IP):$(GRAFANA_NODEPORT)" || true
	xdg-open "http://$(NODE_IP):$(AKHQ_NODEPORT)" || true

.PHONY: setup
setup: ns ## Prepare the cluster
	$(HELM) repo add grafana-community https://grafana-community.github.io/helm-charts
	$(HELM) repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	$(HELM) repo add jetstack https://charts.jetstack.io
	$(HELM) repo add strimzi https://strimzi.io/charts/
	$(HELM) repo add akhq https://akhq.io/
	$(HELM) repo update

	$(HELM) upgrade --wait --install cert-manager jetstack/cert-manager \
		-n cert-manager \
		--create-namespace \
		--set crds.enabled=true

	$(HELM) upgrade --wait --install tempo grafana-community/tempo \
   	-n sandbox \
   	-f setup/tempo.yaml

	$(HELM) upgrade --wait --install grafana grafana-community/grafana \
  	-n sandbox \
  	-f setup/grafana.yaml \
   	--set adminPassword=admin

	$(HELM) upgrade --wait --install strimzi strimzi/strimzi-kafka-operator \
  	-n sandbox

	$(KUBECTL) apply -f setup/kafka.yaml -n sandbox

	$(HELM) upgrade --wait --install otel-operator \
  		open-telemetry/opentelemetry-operator \
  	-n sandbox \
  	-f setup/operator.yaml

	$(HELM) upgrade --install akhq akhq/akhq \
  		-n sandbox \
  		-f setup/akhq.yaml

	$(KUBECTL) apply -n sandbox -f setup/collector.yaml

	## Patch the Grafana and AKHQ services to use NodePort with the specified ports
	$(KUBECTL) -n sandbox patch svc grafana --type merge -p '{"spec":{"type":"NodePort"}}'
	$(KUBECTL) -n sandbox patch svc grafana --type json -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":$(GRAFANA_NODEPORT)}]'
	$(KUBECTL) -n sandbox patch svc akhq --type merge -p '{"spec":{"type":"NodePort"}}'
	$(KUBECTL) -n sandbox patch svc akhq --type json -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":$(AKHQ_NODEPORT)}]'

.PHONY: cluster
cluster: .state/disks/$(CLUSTER) ## Create the Talos cluster

.state/disks/$(CLUSTER):
	./talos/cluster.sh create


.PHONY: up
up: cluster ns setup services ## Bring everything up 

.PHONY: down
down: ## Tear down the cluster
	./talos/cluster.sh destroy
