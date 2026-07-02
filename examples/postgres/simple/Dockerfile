# syntax=docker/dockerfile:1
#
# varde example: PostgreSQL with password auth for remote clients, on the
# varde-postgres base image.
# -----------------------------------------------------------------------------
# THE varde-postgres CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app, NO shell, NO package manager.
#     There is no docker-entrypoint.sh and no "initdb on first boot" magic —
#     initialization is an explicit, one-time
#         docker run --entrypoint /runtime/bin/initdb ...
#     against the same volume you later run the server with (see README.md).
#   - The base sets
#         ENTRYPOINT ["/runtime/bin/postgres",
#                     "-c", "unix_socket_directories=/tmp",
#                     "-c", "listen_addresses=*"]
#     and NO default CMD; PGDATA=/app/data supplies the data directory. A CMD
#     only needs to carry YOUR extra flags — postgres treats later command-line
#     -c flags as overriding earlier ones, so everything above stays tunable.
#     (unix_socket_directories: the compiled-in default /run/postgresql does
#     not exist in the image; /tmp is its sticky, writable dir. PGHOST=/tmp
#     makes in-container psql/pg_isready find that socket with no -h flag.)
#   - Mount your data volume at /app, NOT /app/data: the image's /app is owned
#     by 1000:1000, so a fresh named volume inherits that ownership and initdb
#     (running as uid 1000) can create /app/data inside it.
#   - Not a footgun: listen_addresses=* alone admits nobody — initdb's
#     generated pg_hba.conf only allows local/loopback connections. To accept
#     remote clients you must supply an hba rule, which is exactly what this
#     example does: it bakes a pg_hba.conf requiring scram-sha-256 passwords
#     from everything beyond loopback, and points postgres at it via CMD.
#     The file goes under /etc/postgresql, not /app, because /app is shadowed
#     by the data volume at run time.
#   - This is a single-stage image: nothing to compile, we only add a config.
#
#   Running it: see README.md — build, one-time initdb, run, verify.
#
#   libc note: varde's DEFAULT libc is musl (bare tags like :18 are musl); opt
#   into glibc with :18-glibc. PostgreSQL works on either.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
# Pinned to a major version (not :latest): the initdb'd data directory is
# major-version-locked, so a silently moving base would strand the volume.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-postgres:18

# --- Runtime stage (single stage — no builder needed) ------------------------
# MANDATORY: the only stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# Client access policy, outside the volume-shadowed /app (root-owned is fine —
# postgres only needs to read it; only the data directory must be uid 1000).
COPY pg_hba.conf /etc/postgresql/pg_hba.conf

# CMD appends to the entrypoint, so the container runs:
#   postgres -c unix_socket_directories=/tmp -c listen_addresses=* \
#            -c hba_file=/etc/postgresql/pg_hba.conf
CMD ["-c", "hba_file=/etc/postgresql/pg_hba.conf"]
