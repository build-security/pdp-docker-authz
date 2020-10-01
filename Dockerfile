FROM scratch

LABEL maintainer="Kfir Peled <kfir@build.security>"

COPY pdp-docker-authz /pdp-docker-authz

ENTRYPOINT ["/pdp-docker-authz"]
