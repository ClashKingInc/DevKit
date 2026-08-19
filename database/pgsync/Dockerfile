FROM python:3.12.12-slim@sha256:f3fa41d74a768c2fce8016b98c191ae8c1bacd8f1152870a3f9f87d350920b7c

ARG PGSYNC_VERSION=7.2.0
ARG PGSYNC_GIT_REF=d438650e6b6a046505e847a604d5be0e9338f2d6

LABEL org.opencontainers.image.title="ClashKing PGSync" \
      org.opencontainers.image.version="${PGSYNC_VERSION}" \
      org.opencontainers.image.source="https://github.com/toluaina/pgsync" \
      org.opencontainers.image.revision="${PGSYNC_GIT_REF}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "git+https://github.com/toluaina/pgsync.git@${PGSYNC_GIT_REF}" \
    && python -c "from importlib.metadata import version; assert version('pgsync') == '${PGSYNC_VERSION}'" \
    && useradd --no-create-home --shell /usr/sbin/nologin --uid 10001 pgsync

COPY --chown=10001:10001 schema.json /config/schema.json

USER 10001

ENTRYPOINT ["pgsync"]
