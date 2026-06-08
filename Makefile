GOFLAGS := -trimpath
DATE    := $(shell date +%y%m%d)

CONTAINER_ENGINE ?= podman
IMAGE_NAME       ?= quay.io/updateplanner/plcc2fbc
IMAGE_TAG        ?= latest
IMAGE            := $(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: build
build: plcc2fbc

.PHONY: plcc2fbc
plcc2fbc:
	go build $(GOFLAGS) -o bin/plcc2fbc ./cmd/plcc2fbc

.PHONY: test
test:
	go test -v ./...

.PHONY: generate-fbc
generate-fbc: plcc2fbc
	bin/plcc2fbc -o yaml -l fbc-samples/fbc-$(DATE).log fbc-samples/fbc-$(DATE).yaml 2>fbc-samples/fbc-$(DATE).validation.log
	cp -f fbc-samples/fbc-$(DATE).yaml fbc-samples/fbc-latest.yaml
	cp -f fbc-samples/fbc-$(DATE).log fbc-samples/fbc-latest.log
	cp -f fbc-samples/fbc-$(DATE).validation.log fbc-samples/fbc-latest.validation.log

.PHONY: image-build
image-build:
	@echo "NOTE: VPN connection is required to download the Red Hat IT CA certificate"
	$(CONTAINER_ENGINE) build -t $(IMAGE) -f Dockerfile .

.PHONY: image-push
image-push:
	$(CONTAINER_ENGINE) push $(IMAGE)
