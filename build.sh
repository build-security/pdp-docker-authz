#!/usr/bin/env bash

set -e

echo "Building pdp-docker-authz version: $VERSION"

echo -e "\nBuilding pdp-docker-authz ..."
CGO_ENABLED=0 go build -ldflags \
    "-X github.com/build-security/pdp-docker-authz/version.Version=$VERSION" \
    -o pdp-docker-authz

echo -e "\n... done!"
