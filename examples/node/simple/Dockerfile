# syntax=docker/dockerfile:1
#
# varde example: the smallest possible Node.js app on the varde-node base.
# -----------------------------------------------------------------------------
# THE varde-node CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app
#   - NO shell and NO npm in the runtime image — you cannot `RUN` anything here,
#     and there is no `npm start`. The base sets:
#         ENTRYPOINT ["/runtime/bin/node"]
#         CMD        ["/app/main.js"]
#     so the container runs `node /app/main.js` DIRECTLY. Point CMD/entry at a
#     real file, never at a shell script or an npm lifecycle command.
#   - This example has zero dependencies, so there is nothing to install and no
#     builder stage is needed — we just drop the single source file in place.
#     (See ../express/Dockerfile for the node_modules + builder pattern.)
#
#   libc note: varde's DEFAULT libc is musl (bare `:24` is musl; `:24-glibc` is
#   opt-in). Pure-JS code like this is libc-agnostic, so it just works. The libc
#   choice only matters once you add native addons (.node) — see the express
#   example for how to build those for the musl runtime.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-node:24

# --- Runtime stage (single stage — no builder needed) ------------------------
# MANDATORY: the final runtime stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# The base already sets WORKDIR /app, USER 1000:1000,
# ENTRYPOINT ["/runtime/bin/node"] and CMD ["/app/main.js"]. We only need to put
# main.js where CMD expects it, and the container runs `node /app/main.js` on
# its own.
COPY main.js /app/main.js
