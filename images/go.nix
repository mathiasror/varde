# Minimal distroless base for statically-linked Go binaries.
#
# A Go binary built with CGO_ENABLED=0 is fully static: it embeds the Go runtime
# and links no libc, so it needs no dynamic loader and no shared libraries. That
# makes the image essentially "scratch + the framework scaffolding" — CA certs
# (TLS), tzdata (time.LoadLocation), a non-root user, and a sticky /tmp. There is
# NO language runtime in the image, hence no version axis: a single variant.
#
# Contract: COPY your static binary to /app/app. The inherited WorkingDir=/app
# and this entrypoint run it. If you need cgo/dynamic linking, use a glibc base.
{ pkgs, vardeLib, lib }:
{
  description = "Minimal distroless base for statically-linked Go binaries (CGO_ENABLED=0)";
  latest = "latest";
  variants = {
    # contents omitted ([] — scaffolding is all a static binary needs); no cmd,
    # no env, no fhs (static binaries don't need an FHS layout).
    "latest" = {
      entrypoint = [ "/app/app" ];
    };
  };
}
