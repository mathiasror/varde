# syntax=docker/dockerfile:1
#
# varde example: a configured RabbitMQ (with the management UI) on the
# varde-rabbitmq base image.
# -----------------------------------------------------------------------------
# THE varde-rabbitmq CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app, NO shell, NO package manager.
#     There is genuinely no shell in this image — not even the broker's own
#     launcher script: the base boots the Erlang VM directly (a tiny compiled
#     launcher starts `epmd` and execs the VM with the exact flags the upstream
#     `rabbitmq-server` script would compute).
#   - Configuration is file+env based, exactly like the official image:
#       * /app/rabbitmq.conf     — main config (RABBITMQ_CONFIG_FILE points here)
#       * /app/enabled_plugins   — plugin list (RABBITMQ_ENABLED_PLUGINS_FILE)
#       * any RABBITMQ_* env var — honored by the broker itself (rabbit_env),
#         no wrapper script needed. rabbitmq-env.conf is NOT supported (it
#         requires `sh` to source it); use env vars instead.
#   - The CLI tools work without a shell — they are Erlang escripts on PATH:
#       docker exec <ctr> rabbitmq-diagnostics ping
#       docker exec <ctr> rabbitmqctl list_queues
#   - All mutable state lives under /app (writable, uid 1000): mnesia data in
#     /app/mnesia, the auto-created Erlang cookie at /app/.erlang.cookie.
#     NOTE: RabbitMQ's data dir embeds the node name (rabbit@<hostname>), so
#     for PERSISTENT data run with a stable hostname:
#       docker run --hostname my-rabbit -v rabbit-data:/app/mnesia ...
#   - Free-disk-space monitoring is disabled (it needs /bin/sh + df; this image
#     has neither) — watch disk from your container platform instead.
#
#   Running it:
#     docker build -t my-rabbitmq .
#     docker run --rm -p 5672:5672 -p 15672:15672 my-rabbitmq
#     open http://localhost:15672        # management UI (guest/guest)
#     docker exec <ctr> rabbitmq-diagnostics ping   # -> Ping succeeded
#
#   libc note: varde's DEFAULT libc is musl (bare `:latest` is musl); opt into
#   glibc with `:latest-glibc`. RabbitMQ works on either.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-rabbitmq:latest

# --- Runtime stage (single stage — nothing to compile) -----------------------
# MANDATORY: the only stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# Main config at the path the base's RABBITMQ_CONFIG_FILE already points to.
COPY rabbitmq.conf /app/rabbitmq.conf

# Enable the management plugin (all supported plugins ship in the base under
# /rabbitmq/plugins; this file just turns them on). The UI listens on :15672.
COPY enabled_plugins /app/enabled_plugins

# No CMD: the base's entrypoint boots the broker; AMQP on :5672.
