# syntax=docker/dockerfile:1
#
# varde example: a production-shaped Express app on the varde-node base.
# -----------------------------------------------------------------------------
# THE varde-node CONTRACT (why this is a MULTI-stage build):
#   The runtime image has NO shell and NO npm — you cannot `RUN npm ci` in it,
#   and there is no `npm start`. So we install dependencies in a normal builder
#   image that DOES have npm, then COPY the resulting node_modules into the
#   distroless runtime. The base runs `node` as its ENTRYPOINT with our CMD
#   pointing at a real file, so it launches `node /app/src/server.js` directly.
#
#   libc note — this is the subtle part:
#     varde's DEFAULT libc is MUSL (bare `:24` is musl; `:24-glibc` is opt-in).
#     Any native addon (a compiled *.node file, e.g. from a package with a
#     C/C++ build step) is linked against a specific libc, so it must be built
#     for the SAME libc as the runtime. That is why the builder below is
#     `node:24-alpine` (musl): anything it compiles into node_modules is
#     musl-built and drops straight into the default musl runtime.
#       -> If you instead target the glibc base `:24-glibc`, use a glibc
#          builder such as `node:24-slim` so native addons match.
#     Express itself is PURE JavaScript (no native addon), so it is actually
#     libc-agnostic here — but we still use the musl builder so this example is
#     a correct template the moment you add a dependency that ships native code.
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-node:24

# --- Builder stage -----------------------------------------------------------
# A normal upstream Node image WITH npm; none of it leaks into the runtime.
# alpine => musl, matching the default varde-node runtime (see libc note above).
FROM node:24-alpine AS deps
WORKDIR /build

# Copy only the manifest + lockfile first so the dependency layer is cached
# independently of source changes.
COPY package.json package-lock.json ./

# `npm ci` installs EXACTLY what package-lock.json pins (reproducible), and
# --omit=dev drops devDependencies so only production deps reach the image.
RUN npm ci --omit=dev

# --- Runtime stage -----------------------------------------------------------
# MANDATORY: the final runtime stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# The base already sets WORKDIR /app, USER 1000:1000 and ENTRYPOINT ["node"].
# Bring in the installed dependencies from the builder, then the app source.
COPY --from=deps /build/node_modules /app/node_modules
COPY src/ /app/src/

# No shell, no `npm start`: point CMD straight at the server entry file, so the
# container runs `node /app/src/server.js`. The server binds 0.0.0.0:8080 by
# default, so a published `-p 8080:8080` reaches it.
CMD ["/app/src/server.js"]
