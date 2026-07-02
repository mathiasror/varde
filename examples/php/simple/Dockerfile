# syntax=docker/dockerfile:1
#
# varde-php — the "hello world" of the distroless PHP contract.
#
# BASE_IMAGE is the varde-php runtime: the PHP CLI (plus php-fpm) with nixpkgs'
# default extension set and nothing else — NO shell, NO composer, NO pecl —
# running as the non-root user 1000:1000 with WORKDIR /app. Its entrypoint is
# the interpreter itself:
#   ENTRYPOINT ["/runtime/bin/php"]   CMD ["/app/index.php"]
# so this image, with no extra config, runs `php /app/index.php` on start.
#
# This app has zero dependencies, so there is nothing to build: a single stage
# that copies the script into place is the whole Dockerfile. Apps that DO have
# dependencies resolve them in a Composer builder stage and COPY vendor/ in,
# because the base has no composer to do it:
#   FROM composer:2 AS deps
#   COPY composer.json composer.lock ./
#   RUN composer install --no-dev --no-scripts
#   ...
#   COPY --from=deps /app/vendor /app/vendor
#
# The first line MUST be the ARG so `--build-arg BASE_IMAGE=...` can retarget it
# (the CI e2e harness builds every example against the locally-built base).
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-php:8.5

FROM ${BASE_IMAGE}

# Drop the script where CMD already points. We inherit USER 1000:1000 and
# WORKDIR /app from the base; no ENTRYPOINT/CMD override is needed.
COPY index.php /app/index.php
