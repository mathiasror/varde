# syntax=docker/dockerfile:1
#
# varde-python + uv (modern, fully-locked dependency workflow).
#
# THE CONTRACT (same as every varde-python example): the runtime is only the
# CPython interpreter — NO shell, NO pip, NO uv, NO package manager — running as
# non-root 1000:1000 with ENTRYPOINT ["/runtime/bin/python3"] and
# CMD ["/app/main.py"]. All resolution happens in a builder stage; the runtime
# only receives already-installed packages plus PYTHONPATH.
#
# WHY uv export -> uv pip install --target (instead of `uv sync`):
#   * `uv.lock` pins every transitive dependency to an exact version + hash, so
#     the build is reproducible: `uv export --frozen` fails if the lock is stale
#     rather than silently re-resolving.
#   * We export the lock to a requirements file and install it into a PLAIN
#     directory (--target). No .venv, no interpreter, no uv or pip is carried
#     into the runtime — the distroless image stays pip-free by construction.
#   * --no-dev drops dev-only deps; --no-emit-project skips the app itself
#     (it is a plain script we COPY separately, not an installable package).
#
# ── musl vs glibc: the builder must match the runtime's libc ─────────────────
# varde's DEFAULT libc is musl (bare `:3.13`). Wheels with COMPILED native code
# are libc-specific (manylinux=glibc, musllinux=musl); a mismatched .so will not
# load. So build on a libc that matches the runtime:
#   * default musl runtime (:3.13)       -> python:3.13-alpine (musl), below.
#   * opt-in glibc runtime (:3.13-glibc) -> python:3.13-slim (glibc) instead.
# python-dateutil is pure Python (no .so), so it is libc-agnostic either way.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-python:3.13

# ---- builder stage: musl, matches the default varde-python runtime ----------
FROM python:3.13-alpine AS deps
# Pull the standalone uv binary from its official image (pinned by tag/digest in
# production). Alternatively: `pip install uv`.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /build
# Copy only the dependency manifest + lock first for good layer caching.
COPY pyproject.toml uv.lock ./
# 1) export the frozen lock to a requirements file (fails if uv.lock is stale);
# 2) install those exact pins into a copyable directory. uv pip needs a target
#    interpreter to resolve wheel tags — alpine's python3 (musl) is that, which
#    is exactly why native wheels here would be musllinux and load on the base.
RUN uv export --frozen --no-dev --no-emit-project -o requirements.txt \
 && uv pip install --no-cache --target=/app/site-packages -r requirements.txt

# ---- runtime stage: the distroless varde-python base ------------------------
FROM ${BASE_IMAGE}

# Resolved, locked dependency tree.
COPY --from=deps /app/site-packages /app/site-packages
# Application code (CMD already points at /app/main.py).
COPY main.py /app/main.py
# Put the copied packages on the import path — the no-shell equivalent of
# activating a virtualenv.
ENV PYTHONPATH=/app/site-packages
