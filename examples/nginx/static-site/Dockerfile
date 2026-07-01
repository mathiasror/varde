# syntax=docker/dockerfile:1
#
# varde example: a static website on the varde-nginx base image.
# -----------------------------------------------------------------------------
# THE varde-nginx CONTRACT (read this once, it explains every choice below):
#   - non-root user 1000:1000, WORKDIR /app, NO shell, NO package manager.
#   - The base ships a non-root-friendly default config and runs, as PID 1:
#         nginx -p /tmp -c /etc/nginx/nginx.conf -g "daemon off;"
#     That default config sets `root /app;` and `index index.html;`, listens on
#     :8080 (an UNPRIVILEGED port — required, since a non-root process cannot
#     bind :80), writes its pid/temp under the sticky /tmp, and logs to
#     stdout/stderr.
#   - So the ENTIRE integration is: COPY your static site into /app. There is no
#     builder stage and nothing to compile — this is a single-stage image.
#
#   Running it:
#     docker build -t my-site .
#     docker run --rm -p 8080:8080 my-site      # then open http://localhost:8080
#   Note the port is 8080 on BOTH sides; map it to :80 on the host if you like
#   with `-p 80:8080`.
#
#   Using your own nginx config (two options, since you can't edit files in a
#   shell-less image):
#     1. Bind-mount over the default at run time:
#          docker run -p 8080:8080 \
#            -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" my-site
#     2. Bake a different config path in and override the entrypoint's `-c`
#        flag (keep it listening on an unprivileged port and writing under /tmp,
#        or the non-root process will fail to start).
#
#   libc note: varde's DEFAULT libc is musl (bare `:latest` is musl); opt into
#   glibc with `:latest-glibc`. Static file serving is libc-agnostic, so either
#   works here.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-nginx:latest

# --- Runtime stage (single stage — no builder needed) ------------------------
# MANDATORY: the only stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# Drop the site into the webroot. The base's default config serves /app with
# index.html, so `GET /` returns site/index.html. The trailing slash on `site/`
# copies the directory CONTENTS (index.html, health, ...) into /app, not the
# directory itself.
COPY site/ /app/
