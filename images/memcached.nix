# Minimal distroless Memcached server.
#
# Relocates the nixpkgs memcached package under /runtime, which finds its
# libraries via RPATH, so no FHS layout is needed. Memcached refuses to start
# as root; varde images run as uid 1000 (`app`), so it starts without a `-u`
# flag and needs no privileges (and nothing on disk — memcached is purely
# in-memory).
#
# Built for both libcs: the bare tag (:latest) is musl; opt into glibc with
# :latest-glibc.
#
# Contract: run as-is (memcached listens on 0.0.0.0:11211 with defaults: 64MB
# cache, 1024 connections, no auth), or pass flags by overriding CMD — Docker
# appends CMD to the entrypoint, e.g. `CMD ["-m", "256"]` runs
# `memcached -m 256` (see examples/memcached/).
{ pkgs, vardeLib, lib }:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  memcachedSpec =
    p:
    let
      # No SASL, deliberately: nixpkgs puts cyrus_sasl in buildInputs but never
      # passes --enable-sasl, so the binary ships without SASL either way
      # (verified: cyrus-sasl is absent from the stock package's runtime
      # closure). Nulling it here just drops cyrus-sasl (and its openssl/db
      # deps) from the *build* closure — which on musl is all from-source —
      # for zero functional loss. SASL would be a poor fit for this image
      # anyway (it wants /etc/sasl2 config files); if you need auth, front
      # memcached with a TLS/auth proxy or keep it on a private network.
      memcached = p.memcached.override { cyrus_sasl = null; };
    in
    {
      contents = [
        (vardeLib.relocate p "varde-memcached-root-${memcached.version}" "runtime" memcached)
      ];
      entrypoint = [ "/runtime/bin/memcached" ];
      env = [ "PATH=/runtime/bin" ];
      # no fhs: the nixpkgs memcached binary finds its libs via RPATH.
    };
in
{
  description = "Minimal distroless Memcached server";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs {
    versions."latest" = { spec = memcachedSpec; };
  };
}
