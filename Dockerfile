FROM scratch

LABEL maintainer="Build Security <community@build.security>"

COPY pdp-docker-authz /pdp-docker-authz

ENTRYPOINT ["/pdp-docker-authz"]
