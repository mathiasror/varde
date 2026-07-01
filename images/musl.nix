# Minimal distroless musl base for dynamically-linked (musl) binaries.
#
# Supplies the musl dynamic loader at /lib/ld-musl-<arch>.so.1 plus musl libc and
# libstdc++/libgcc_s at standard FHS paths (via `fhs = true`), so an externally
# compiled musl binary runs as-is. There is NO language runtime in the image —
# the binary is self-contained — hence a single variant.
#
# Works for any musl-dynamic binary. A fully static musl binary needs none of
# this — use the smaller varde-static instead.
#
# Contract: COPY your compiled binary to /app/app. The inherited WorkingDir=/app
# and entrypoint run it.
{ pkgs, vardeLib, lib }:
{
  description = "Minimal distroless musl base for dynamically-linked binaries";
  latest = "latest";
  variants."latest" = vardeLib.muslSpec;
}
