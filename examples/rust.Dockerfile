# Example: package your Rust app on top of the varde base image.
#
# The default target (x86_64-unknown-linux-gnu) is dynamically linked against
# glibc. This base supplies glibc + libgcc_s at FHS paths (via fhs = true), plus
# the dynamic loader, so a normal `cargo build --release` binary runs as-is —
# no shell, no cargo, non-root. CA certs ship at /etc/ssl/certs/ca-certificates.crt,
# so TLS clients (reqwest, rustls) work out of the box.
#
# If you instead build a FULLY STATIC musl binary, it embeds everything and links
# no libc — use the smaller varde-go (scratch-like) base instead of this one:
#   rustup target add x86_64-unknown-linux-musl
#   cargo build --release --target x86_64-unknown-linux-musl
#
# Pin to a digest in production: varde-rust:latest@sha256:...

# Name of the produced binary (Cargo's [package].name / [[bin]].name).
ARG APP=app

# Stage 1: build a release binary (default gnu target -> dynamically linked).
FROM rust:1-bookworm AS build
ARG APP
WORKDIR /src
COPY . .
RUN cargo build --release --locked && \
    mkdir -p /out && \
    cp "target/release/${APP}" /out/app

# Stage 2: the distroless glibc base — no shell, no cargo, non-root.
FROM ghcr.io/mathiasror/varde-rust:latest

# Inherited from the base — no need to repeat:
#   USER 1000:1000
#   WORKDIR /app
#   ENTRYPOINT ["/app/app"]

COPY --from=build /out/app /app/app

# --- Optional: pass arguments to your binary by setting CMD --------------------
# CMD ["--config", "/app/config.toml"]
#
# --- Optional: force one architecture via an explicit per-arch tag ------------
# FROM ghcr.io/mathiasror/varde-rust:latest-arm64  # or :latest-amd64
#
# Note: `trivy image` reads dependency metadata embedded in Rust binaries (the
# cargo-auditable / Cargo.lock data), so the final app image stays scannable for
# CVEs in your crate dependencies.
