# Minimal distroless glibc base for dynamically-linked Rust binaries.
#
# Rust's default Linux target (x86_64-unknown-linux-gnu) produces a dynamically
# linked binary: it needs the dynamic loader (ld-linux) plus glibc and libgcc_s
# present at standard FHS paths to run. Setting `fhs = true` is what supplies all
# of that — the framework lays down the loader at /lib64/ld-linux-*.so, the shared
# libs at /lib, and points LD_LIBRARY_PATH=/lib:/lib64. So `contents` stays empty:
# there is NO Rust runtime in the image (the binary is self-contained), hence no
# version axis — a single variant.
#
# Contract: COPY your compiled binary to /app/app. The inherited WorkingDir=/app
# and this entrypoint run it. If you instead build a fully static musl binary
# (--target x86_64-unknown-linux-musl), use the smaller varde-go (scratch-like) base.
{ pkgs, vardeLib, lib }:
{
  description = "Minimal distroless glibc base for dynamically-linked Rust binaries";
  latest = "latest";
  variants = {
    # contents omitted ([] — glibc/libstdc++/libgcc_s come from fhs = true); no
    # cmd, no env. fhs = true provides the loader + shared libs at FHS paths.
    "latest" = {
      entrypoint = [ "/app/app" ];
      fhs = true;
    };
  };
}
