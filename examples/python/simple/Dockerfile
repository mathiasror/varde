# syntax=docker/dockerfile:1
#
# varde-python — the "hello world" of the distroless Python contract.
#
# BASE_IMAGE is the varde-python runtime: the CPython interpreter and nothing
# else — NO shell, NO pip, NO package manager — running as the non-root user
# 1000:1000 with WORKDIR /app. Its entrypoint is the interpreter itself:
#   ENTRYPOINT ["/runtime/bin/python3"]   CMD ["/app/main.py"]
# so this image, with no extra config, runs `python3 /app/main.py` on start.
#
# This app has zero dependencies, so there is nothing to build: a single stage
# that copies the script into place is the whole Dockerfile. Examples that DO
# have dependencies (see ../requirements-venv and ../uv) resolve them in a
# separate builder stage and COPY them in, because the base has no pip to do it.
#
# The first line MUST be the ARG so `--build-arg BASE_IMAGE=...` can retarget it
# (the CI e2e harness builds every example against the locally-built base).
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-python:3.13

FROM ${BASE_IMAGE}

# Drop the script where CMD already points. We inherit USER 1000:1000 and
# WORKDIR /app from the base; no ENTRYPOINT/CMD override is needed.
COPY main.py /app/main.py
