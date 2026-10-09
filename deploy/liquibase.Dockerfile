# Liquibase 5 ships without JDBC drivers (checked with 5.0.4), and Mongo needs two packages: the extension and the
# Java driver it connects with (Annex B). Installing only the driver fails with "Driver class was not specified".
# Exact versions, as lpm resolved them on 2026-10-09.
# The base can be pulled from another registry with the same version (the CI uses GitHub Container Registry,
# because Docker Hub limits the anonymous downloads of a shared runner address).
ARG LIQUIBASE_BASE=liquibase/liquibase:5.0.4
FROM ${LIQUIBASE_BASE}
RUN lpm add liquibase-mongodb@5.0.3 mongodb@3.12.14 --global
