# Minimal distroless Redis server.
#
# Relocates the nixpkgs redis package under /runtime (redis-server + redis-cli),
# which finds its libraries via RPATH, so no FHS layout is needed. Runs non-root
# (redis needs no privileges) and writes to the inherited WORKDIR /app.
#
# Built for both libcs: the bare tag (:latest) is musl; opt into glibc with
# :latest-glibc.
#
# Contract: run as-is, or pass a config by overriding CMD:
# `CMD ["/app/redis.conf"]` (see examples/redis/). Run as-is, redis listens on
# all interfaces (`* -::*`), port 6379, with upstream defaults — which include
# protected mode: with no password set, Redis 8 answers every non-loopback
# client with -DENIED, so only same-network-namespace clients (docker exec, a
# sidecar over localhost) get in. Unlike the docker-library image, this one
# does NOT patch that default off. To serve remote clients (`-p 6379:6379`,
# other containers), supply a redis.conf via CMD (the example sets
# `protected-mode no` for the demo) or pass directives through CMD, e.g.
# `docker run -p 6379:6379 varde-redis --requirepass <secret>` (preferred) or
# `--protected-mode no` (trusted networks only).
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  redisSpec =
    p:
    let
      # sd_notify is dead weight in a container (no systemd to talk to), and
      # systemd's build closure drags in clang/llvm/bpftools/tpm2-tss — on musl
      # that's hours of from-source compiles that blow the 6h CI job limit.
      # (nixpkgs' redis skips its TCL test suite on every platform — it lives
      # in a `tests` passthru — so the image's runtime proof is CI's docker
      # smoke test + the e2e example, which exercise the actual redis-server
      # binary.)
      # jemalloc's output bundles bin/ scripts — jemalloc-config and
      # jemalloc.sh are bash, jeprof is perl — and redis's RPATH link to
      # lib/libjemalloc.so dragged that whole output (bash included) into the
      # image closure. redis only needs the library; drop the scripts at the
      # source. (The lib closure guard fails the build if this ever regresses.)
      # On x86_64 musl, jemalloc's check phase hangs in
      # test/integration/cpp/infallible_new_false — no output, until the job
      # limit kills it (twice in run 38873651543, 4.5 min into checks both
      # times). Being our own override, this drv is never in a public cache,
      # so the hang hits every cache-cold musl build. Skip its checks on musl
      # only; glibc keeps them, and the runtime proof is the redis smoke test
      # + e2e example.
      jemalloc = p.jemalloc.overrideAttrs (prev: {
        postInstall = (prev.postInstall or "") + ''
          rm -rf "$out/bin"
        '';
        doCheck = (prev.doCheck or false) && !p.stdenv.hostPlatform.isMusl;
      });
      redis = p.redis.override {
        withSystemd = false;
        inherit jemalloc;
      };
    in
    {
      contents = [ (vardeLib.relocate p "varde-redis-root-${redis.version}" "runtime" redis) ];
      entrypoint = [ "/runtime/bin/redis-server" ];
      env = [ "PATH=/runtime/bin" ];
      # no fhs: the nixpkgs redis binary finds its libs via RPATH.
    };
in
{
  description = "Minimal distroless Redis server";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs {
    versions."latest" = {
      spec = redisSpec;
    };
  };
}
