.PHONY: all build

VERSION := v0.4
GO_VERSION := 1.14.7
REPO := buildsecurity/pdp-docker-authz

all: build

build:
	@docker container run --rm \
		-e VERSION=$(VERSION) \
		-v $(PWD):/go/src/github.com/build-security/pdp-docker-authz \
		-w /go/src/github.com/build-security/pdp-docker-authz \
		golang:$(GO_VERSION) \
		./build.sh

plugin: build
	VERSION=$(VERSION) REPO=$(REPO) ./plugin.sh

plugin-push:
	@for plugin in `docker plugin ls --format '{{.Name}}'`; do \
		if [ "$$plugin" = "$(REPO):$(VERSION)" ]; then \
		    echo "\nPushing plugin $(REPO):$(VERSION) ..."; \
            docker plugin push $(REPO):$(VERSION); \
			exit; \
		fi \
	done; \
	echo "\nNo local copy of $(REPO):$(VERSION) exists, create it before attempting push"

clean:
	@if [ -f ./pdp-docker-authz ]; then \
		echo "\nRemoving pdp-docker-authz binary ..."; \
		rm -rvf ./pdp-docker-authz; \
	fi
	@for plugin in `docker plugin ls --format '{{.Name}}'`; do \
		if [ "$$plugin" = "$(REPO):$(VERSION)" ]; then \
		    echo "\nRemoving local copy of plugin $(REPO):$(VERSION) ..."; \
            docker plugin rm -f $(REPO):$(VERSION); \
		fi \
	done
