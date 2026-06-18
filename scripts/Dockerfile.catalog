ARG CATALOG_IMAGE=registry.redhat.io/redhat/redhat-operator-index:v4.22
FROM ${CATALOG_IMAGE} AS rh-catalog

FROM quay.io/operator-framework/opm:latest

ENTRYPOINT ["/bin/opm"]
CMD ["serve", "/configs", "--cache-dir=/tmp/cache"]

COPY --from=rh-catalog /configs /configs
COPY --chown=0:0 lifecycle-overlay/ /configs/
RUN ["/bin/opm", "serve", "/configs", "--cache-dir=/tmp/cache", "--cache-only"]

LABEL operators.operatorframework.io.index.configs.v1=/configs
