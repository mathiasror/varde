# syntax=docker/dockerfile:1
#
# varde example: a static Go binary on the varde-static base image.
# -----------------------------------------------------------------------------
# WHY varde-static here?
#   `CGO_ENABLED=0` produces a fully STATIC binary with no libc dependency, so
#   we run it on varde-static (a.k.a. varde-go) — the scratch-like base with no
#   dynamic loader at all. This is the smallest, tightest option.
#
#   If this program instead used cgo or was built with the default
#   `CGO_ENABLED=1` (dynamically linked against glibc), you would target the
#   glibc base image `ghcr.io/mathiasror/varde-glibc:latest` (a.k.a.
#   varde-rust) instead. Remember: in varde, musl is the DEFAULT libc (bare
#   tags are musl); `glibc` and `static` are separate, explicitly-named images.
#
# The varde runtime contract (all varde base images):
#   - non-root user 1000:1000
#   - WORKDIR /app
#   - no shell, no package manager, no build tools in the runtime image
#   - ENTRYPOINT ["/app/app"] — so we copy our binary to exactly /app/app
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-static:latest

# --- Builder stage -----------------------------------------------------------
# A normal upstream toolchain image; none of this leaks into the runtime image.
FROM golang:1-bookworm AS build
WORKDIR /src

# Copy module metadata first so dependency resolution is cached independently
# of source changes. (This trivial example has no deps and thus no go.sum; a
# real project copies both: `COPY go.mod go.sum ./`.)
COPY go.mod ./
RUN go mod download

# Copy the rest of the source and build.
COPY . .

# CGO_ENABLED=0  -> no libc linkage -> a fully static binary (see note above).
# -trimpath      -> strip local filesystem paths for reproducible builds.
# -ldflags "-s -w" -> drop the symbol table and DWARF debug info to shrink it.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .

# --- Runtime stage -----------------------------------------------------------
# MANDATORY: the final runtime stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# The base already sets WORKDIR /app, USER 1000:1000, and
# ENTRYPOINT ["/app/app"]. We only need to drop the binary in place.
COPY --from=build /out/app /app/app
