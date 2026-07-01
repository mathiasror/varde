# syntax=docker/dockerfile:1
#
# varde example: a dynamically-linked Rust binary on the varde-glibc base.
# -----------------------------------------------------------------------------
# WHY varde-glibc here?
#   A default `cargo build` on the `rust:1-bookworm` image targets
#   `x86_64-unknown-linux-gnu`, i.e. it links DYNAMICALLY against glibc. That
#   binary needs a glibc runtime, so we run it on varde-glibc (a.k.a.
#   varde-rust).
#
#   If you instead produced a fully-static musl binary with
#   `cargo build --release --target x86_64-unknown-linux-musl`, you would run it
#   on the smaller, scratch-like `ghcr.io/mathiasror/varde-static:latest`
#   (a.k.a. varde-go). Note: in varde, musl is the DEFAULT libc (bare tags are
#   musl); `glibc` and `static` are separate, explicitly-named images. A
#   default cargo build is glibc, which is why this example uses varde-glibc.
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
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-glibc:latest

# --- Builder stage -----------------------------------------------------------
# A normal upstream toolchain image; none of this leaks into the runtime image.
FROM rust:1-bookworm AS build
WORKDIR /src

# Copy the whole crate and build a release binary.
#   --release -> optimized build.
#   --locked  -> fail unless Cargo.lock is present and up to date, giving
#                reproducible dependency resolution. (That's why Cargo.lock is
#                committed alongside this example.)
COPY . .
RUN cargo build --release --locked \
    && mkdir -p /out \
    && cp target/release/app /out/app

# --- Runtime stage -----------------------------------------------------------
# MANDATORY: the final runtime stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# The base already sets WORKDIR /app, USER 1000:1000, and
# ENTRYPOINT ["/app/app"]. We only need to drop the binary in place.
COPY --from=build /out/app /app/app
