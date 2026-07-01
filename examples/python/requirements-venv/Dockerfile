# syntax=docker/dockerfile:1
#
# varde-python + pip/requirements.txt (the "built-in tooling" workflow).
#
# THE CONTRACT: the varde-python runtime is only the CPython interpreter —
# NO shell, NO pip, NO package manager — running as non-root 1000:1000 with
# ENTRYPOINT ["/runtime/bin/python3"] and CMD ["/app/main.py"]. You therefore
# cannot `pip install` inside the final image. Instead:
#   1. a normal upstream Python image (the "deps" builder) installs the deps,
#   2. we COPY the installed packages into the runtime, and
#   3. ENV PYTHONPATH puts them on the interpreter's import path.
#
# ── musl vs glibc: the builder must match the runtime's libc ─────────────────
# varde's DEFAULT libc is musl (the bare `:3.13` tag). A wheel that contains
# COMPILED native code (a .so) is built against a specific libc: manylinux
# wheels link glibc, musllinux wheels link musl. Loading a glibc .so on a musl
# interpreter (or vice-versa) fails. So resolve deps with a builder whose libc
# matches the runtime:
#   * default musl runtime (:3.13)        -> build on python:3.13-alpine (musl).
#       Alpine's pip installs musllinux wheels, or compiles from source, so the
#       resulting .so files load on the musl runtime.
#   * opt-in glibc runtime (:3.13-glibc)  -> build on python:3.13-slim (glibc),
#       which installs manylinux wheels.
# PURE-PYTHON deps like python-dateutil have no .so and are libc-agnostic, so
# either builder works — we use alpine here to match the default runtime.
#
# NOTE: a few native libraries expect extra shared objects (e.g. libffi) that
# are intentionally NOT in the distroless base. Ship those .so files explicitly
# alongside your site-packages (COPY them from the builder) — the base stays
# minimal on purpose and does not carry them for you.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-python:3.13

# ---- builder stage: musl, matches the default varde-python runtime ----------
FROM python:3.13-alpine AS deps
WORKDIR /build
COPY requirements.txt .
# --target installs into a plain directory we can COPY wholesale (no venv, no
# interpreter, no pip carried forward). --no-cache-dir keeps the layer lean.
RUN pip install --no-cache-dir --target=/app/site-packages -r requirements.txt

# ---- runtime stage: the distroless varde-python base ------------------------
FROM ${BASE_IMAGE}

# The resolved dependency tree, dropped next to the app.
COPY --from=deps /app/site-packages /app/site-packages
# The application code (CMD already points at /app/main.py).
COPY main.py /app/main.py
# Put the copied packages on the interpreter's import path. This is the step
# that replaces "activate the venv" — there is no shell to source anything.
ENV PYTHONPATH=/app/site-packages
