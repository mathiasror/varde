# syntax=docker/dockerfile:1
#
# varde example: Memcached with explicit flags on the varde-memcached base image.
# -----------------------------------------------------------------------------
# THE varde-memcached CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app, NO shell, NO package manager.
#   - The base sets ENTRYPOINT ["/runtime/bin/memcached"] and NO default CMD.
#     memcached is configured entirely with command-line FLAGS (no config
#     file), so:
#         * with no CMD, it starts with built-in defaults — listens on
#           0.0.0.0:11211, 64MB cache, 1024 connections, no auth;
#         * with `CMD ["-m", "128"]`, Docker appends the flags to the
#           entrypoint, i.e. it runs `memcached -m 128`.
#     That is exactly how you configure memcached in a shell-less image —
#     there is no entrypoint script and no `memcached ...` shell line to edit.
#   - Memcached refuses to start as root; the base runs as uid 1000, so it
#     starts without a `-u` flag. It is purely in-memory: nothing is written
#     to disk, no volumes needed.
#
#   Running it:
#     docker build -t my-memcached .
#     docker run --rm -p 11211:11211 my-memcached
#     printf 'stats\r\nquit\r\n' | nc localhost 11211   # -> STAT uptime ...
#
#   libc note: varde's DEFAULT libc is musl (bare `:latest` is musl); opt into
#   glibc with `:latest-glibc`. Memcached works on either.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-memcached:latest

# --- Runtime stage (single stage — no builder needed) ------------------------
# MANDATORY: the only stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# CMD supplies flags appended to the entrypoint, so the container runs:
#   /runtime/bin/memcached -m 64 -c 1024 -v
#   -m 64   cache memory cap in MB (the default, made explicit — tune this)
#   -c 1024 max simultaneous connections (the default, made explicit)
#   -v      log warnings/errors to stderr so `docker logs` shows liveness
CMD ["-m", "64", "-c", "1024", "-v"]
