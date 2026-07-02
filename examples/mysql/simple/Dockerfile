# syntax=docker/dockerfile:1
#
# varde example: a seeded MySQL on the varde-mysql base image.
# -----------------------------------------------------------------------------
# THE varde-mysql CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app, NO shell, NO package manager.
#   - The base sets ENTRYPOINT ["/runtime/bin/mysqld"] and NO default CMD.
#     Sane defaults are baked into /etc/my.cnf (datadir=/app/data, socket and
#     pid file under /tmp, bind-address=0.0.0.0, X-plugin off, server-side
#     import/export disabled). Any mysqld flag you pass overrides the file.
#   - MySQL needs a ONE-TIME data-directory initialization before it can
#     serve. MySQL 8 does this natively — `mysqld --initialize-insecure` —
#     which is exactly why this image is MySQL and not MariaDB (whose
#     mariadb-install-db is a shell script and can't run here).
#   - Docker's exec-form RUN needs no shell, so this Dockerfile initializes
#     the data directory AT BUILD TIME and bakes it into the image: instant
#     startup, zero moving parts — perfect for demos and CI.
#     For PRODUCTION, keep data out of the image: run the same two steps at
#     deploy time against a volume mounted at /app (see README.md).
#   - `--initialize-insecure` creates 'root'@'localhost' with an EMPTY
#     password, usable only from inside the container (via the unix socket).
#     The --init-file SQL below seeds a real database + user for network
#     clients, natively, during the same initialize run.
#
#   Running it:
#     docker build -t my-mysql .
#     docker run --rm -p 3306:3306 my-mysql
#     mysql -h 127.0.0.1 -u demo -pdemo-password demo -e 'SELECT 1'  # from host
#     # in-container health check (this is what e2e verifies):
#     docker exec <container> /runtime/bin/mysqladmin -u root ping
#
#   libc note: varde-mysql is GLIBC-ONLY (musl MySQL is not buildable from
#   nixpkgs), so the bare :latest tag is already the glibc build.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-mysql:latest

# --- Runtime stage (single stage — nothing to compile) -----------------------
# MANDATORY: the only stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# SQL executed once, at the end of the initialize step below: seeds the demo
# database and a user network clients can log in as. (DEMO credentials — for
# real deployments inject secrets at deploy time, not into the image.)
COPY init.sql /app/init.sql

# One-time native initialization, baked into an image layer. Exec-form RUN
# executes the binary directly — no shell involved. It reads /etc/my.cnf, so
# the data directory lands at /app/data (WORKDIR /app is owned by 1000 and
# writable at build time). --innodb-redo-log-capacity shrinks the preallocated
# redo files for the baked layer (~100MB -> 8MB); at runtime the server simply
# grows them again in the container's writable layer.
RUN ["/runtime/bin/mysqld", "--initialize-insecure", "--init-file=/app/init.sql", "--innodb-redo-log-capacity=8388608"]

# No CMD: the inherited entrypoint starts mysqld with the baked /etc/my.cnf
# defaults, serving the pre-initialized /app/data on 0.0.0.0:3306.
