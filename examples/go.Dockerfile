# Example: package your Go app on top of the varde base image.
#
# The base is scratch-like: no shell, no libc, no loader. Your binary MUST be
# fully static (CGO_ENABLED=0) so it runs here. If you need cgo / dynamic
# linking, use the glibc-based varde-rust image instead.
#
# Pin to a digest in production: varde-go:latest@sha256:...

# Stage 1: build a fully static binary (no cgo).
FROM golang:1-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0 -> static; -trimpath + -ldflags="-s -w" for a small, reproducible binary.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

# Stage 2: the distroless base — no shell, no libc, non-root.
FROM ghcr.io/mathiasror/varde-go:latest

# Inherited from the base — no need to repeat:
#   USER 1000:1000
#   WORKDIR /app
#   ENTRYPOINT ["/app/app"]
#
# CA certs (/etc/ssl/certs) and tzdata (/usr/share/zoneinfo) are already present,
# so outbound TLS and time.LoadLocation work out of the box.
COPY --from=build /out/app /app/app

# --- Optional: pass app args by overriding CMD ---------------------------------
# CMD ["--listen", ":8080"]
#
# --- Optional: force one architecture via an explicit per-arch tag ------------
# FROM ghcr.io/mathiasror/varde-go:latest-arm64  # or :latest-amd64

# Note: `trivy image` reads the dependency list embedded in the Go binary's build
# info (go version -m), so this final app image is scannable for vulnerable deps.
