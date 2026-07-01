# Minimal distroless scratch-like base for statically-linked binaries.
#
# A fully static binary embeds everything and links no libc, so it needs no
# dynamic loader and no shared libraries. That makes the image essentially
# "scratch + the framework scaffolding" — CA certs (TLS), tzdata, a non-root
# user, and a sticky /tmp. There is NO libc in the image, hence `libc = null`.
#
# Works for any static binary: Go (CGO_ENABLED=0), Rust musl (--target
# *-linux-musl), static C/Zig, etc. Published also as the `varde-go` alias.
#
# Contract: COPY your static binary to /app/app. The inherited WorkingDir=/app
# and entrypoint run it. Need a dynamic binary? Use varde-glibc or varde-musl.
{ pkgs, vardeLib, lib }:
{
  description = "Minimal distroless scratch-like base for statically-linked binaries";
  latest = "latest";
  variants."latest" = vardeLib.staticSpec;
}
