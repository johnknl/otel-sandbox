BIN_DIR=$(CURDIR)/bin
REGISTRY=localhost:32000
MK8S=$(shell which microk8s)
PROTO_SRCS := $(shell find proto/ -type f -name '*.proto')
MODULE := $(shell go list -m)
PROTOC_VERSION=34.1
PROTOC_SHA256=af27ea66cd26938fe48587804ca7d4817457a08350021a1c6e23a27ccc8c6904 
PROTOC_ZIP=protoc-$(PROTOC_VERSION)-linux-x86_64.zip

.PHONY: help
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Available targets:\n"} /^[a-zA-Z0-9_.%\/-]+:.*## / {printf "  make %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: build
build: services ## Alias for services target

.PHONY: services
services: proto ## Build and push the services
	docker build -t $(REGISTRY)/backend:latest --target backend .
	docker build -t $(REGISTRY)/frontend:latest --target frontend .

	docker push $(REGISTRY)/backend:latest
	docker push $(REGISTRY)/frontend:latest

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

.PHONY: up
up: build setup ## 'up' the system
	$(MK8S) kubectl apply -k deploy/

	# do a possibly redundant recreation of the pods 
	$(MK8S) kubectl rollout restart deployment frontend backend

	$(MK8S) kubectl port-forward svc/grafana 3000:80

.PHONY: setup
setup: ## Prepare the cluster
	$(MK8S) enable dns registry helm3 cert-manager

	$(MK8S) helm3 repo add grafana-community https://grafana-community.github.io/helm-charts
	$(MK8S) helm3 repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	$(MK8S) helm3 repo add strimzi https://strimzi.io/charts/

	$(MK8S) helm3 repo update

	#
	# just stuff everything in the default namespace for convenience
	#
	
	$(MK8S) helm3 upgrade --wait --install tempo grafana-community/tempo \
  	-n default \
  	-f setup/tempo.yaml

	$(MK8S) helm3 upgrade --wait --install grafana grafana-community/grafana \
  	-n default \
  	-f setup/grafana.yaml

	$(MK8s) helm3 upgrade --wait --install strimzi strimzi/strimzi-kafka-operator \
  	-n default

	$(MK8S) helm3 upgrade --wait --install otel-operator \
  		open-telemetry/opentelemetry-operator \
  	-n default \
  	-f setup/operator.yaml

	$(MK8S) kubectl apply -f setup/collector.yaml
