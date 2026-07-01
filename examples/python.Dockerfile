# Example: package your Python app on top of the varde base image.
#
# The base is the CPython interpreter only — non-root, no shell, no pip. It runs
# `python3 /app/main.py` directly (there is no shell to invoke). Because it has
# no package manager, install dependencies in a builder stage and COPY the
# resolved site-packages into the runtime.
#
# Pin to a digest in production: varde-python:3.13@sha256:...

# --- Stage 1: install deps with a full Python (has pip) into a portable dir ----
FROM python:3.13-slim AS deps
WORKDIR /build
COPY requirements.txt .
# --target installs into a plain directory we can lift wholesale into the runtime.
# Pure-Python and manylinux wheels both work; the runtime's FHS glibc lets the
# manylinux wheels' compiled .so extensions load.
RUN pip install --no-cache-dir --target=/app/site-packages -r requirements.txt

# --- Stage 2: the distroless runtime — interpreter only, non-root, no shell ----
FROM ghcr.io/mathiasror/varde-python:3.13

# Inherited from the base — no need to repeat:
#   USER 1000:1000
#   WORKDIR /app
#   ENTRYPOINT ["/runtime/bin/python3"]
#   CMD ["/app/main.py"]

COPY --from=deps /app/site-packages /app/site-packages
COPY src/ /app/

# Put the copied deps on the import path.
ENV PYTHONPATH=/app/site-packages

# --- Optional: run a different entry module by overriding CMD -------------------
# CMD ["/app/server.py"]
# Or run a stdlib/installed module:
# CMD ["-m", "http.server"]
#
# --- Optional: pick a different Python by changing the tag ---------------------
# FROM ghcr.io/mathiasror/varde-python:3.11        # or :3.12
#   Change the deps stage to the matching python:3.11-slim too: manylinux wheels
#   carry a version-specific ABI tag (cp311), so builder major.minor must match.
#
# --- Optional: force one architecture via an explicit per-arch tag -------------
# FROM ghcr.io/mathiasror/varde-python:3.13-arm64  # or :3.13-amd64
#
# --- Note on extra system libraries -------------------------------------------
# The base bundles glibc + libstdc++/libgcc_s (enough for typical manylinux
# wheels). A wheel that links EXTRA shared libraries — e.g. psycopg2 needs
# libpq, or some image libs need libjpeg — must have those .so files added
# explicitly; the base intentionally stays minimal and does not ship them.
# Prefer self-contained wheels (e.g. psycopg2-binary) where one exists, or COPY
# the needed libs into /lib alongside the FHS layout.
