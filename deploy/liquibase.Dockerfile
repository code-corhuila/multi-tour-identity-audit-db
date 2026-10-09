# Liquibase 5 ships without JDBC drivers (checked with 5.0.4), and Mongo needs two packages: the extension and the
# Java driver it connects with (Annex B). Installing only the driver fails with "Driver class was not specified".
# Exact versions, as lpm resolved them on 2026-10-09.
FROM liquibase/liquibase:5.0.4
RUN lpm add liquibase-mongodb@5.0.3 mongodb@3.12.14 --global
