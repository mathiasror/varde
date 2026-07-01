# syntax=docker/dockerfile:1
#
# varde example: a configured Redis on the varde-redis base image.
# -----------------------------------------------------------------------------
# THE varde-redis CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app, NO shell, NO package manager.
#   - The base sets ENTRYPOINT ["/runtime/bin/redis-server"] and NO default CMD.
#     `redis-server` takes an OPTIONAL config-file path as its FIRST positional
#     argument, so:
#         * with no CMD, it starts with built-in defaults (binds 0.0.0.0:6379);
#         * with `CMD ["/app/redis.conf"]`, Docker appends that path to the
#           entrypoint, i.e. it runs `redis-server /app/redis.conf`.
#     That is exactly how you hand Redis a config in a shell-less image — there
#     is no entrypoint script and no `redis-server ...` shell line to edit.
#   - Redis runs non-root and writes its working files under WORKDIR /app (see
#     `dir /app` in redis.conf); /app is owned by 1000:1000, so that's writable.
#   - This is a single-stage image: there is nothing to compile, we only add a
#     config file on top of the base.
#
#   Running it:
#     docker build -t my-redis .
#     docker run --rm -p 6379:6379 my-redis
#     redis-cli -p 6379 ping      # -> PONG   (this is what e2e verifies)
#
#   libc note: varde's DEFAULT libc is musl (bare `:latest` is musl); opt into
#   glibc with `:latest-glibc`. Redis works on either.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-redis:latest

# --- Runtime stage (single stage — no builder needed) ------------------------
# MANDATORY: the only stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# Bake the config into the image at a path the app user can read.
COPY redis.conf /app/redis.conf

# CMD supplies the config path as the entrypoint's first argument, so the
# container runs: /runtime/bin/redis-server /app/redis.conf
CMD ["/app/redis.conf"]
