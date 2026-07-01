# Minimal distroless glibc base for dynamically-linked (glibc) binaries.
#
# Supplies the glibc dynamic loader at /lib64/ld-linux-*.so plus glibc and
# libstdc++/libgcc_s at standard FHS paths (via `fhs = true`), so an externally
# compiled glibc binary runs as-is. There is NO language runtime in the image —
# the binary is self-contained — hence a single variant.
#
# Works for any glibc-dynamic binary: a default `cargo build` (…-linux-gnu),
# cgo Go, C/C++, etc. Published also as the `varde-rust` alias.
#
# Contract: COPY your compiled binary to /app/app. Fully static musl binary?
# Use varde-static. Dynamically-linked musl binary? Use varde-musl.
{ pkgs, vardeLib, lib }:
{
  description = "Minimal distroless glibc base for dynamically-linked binaries";
  latest = "latest";
  variants."latest" = vardeLib.glibcSpec;
}
