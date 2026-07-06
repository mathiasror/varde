# memcached/simple

Memcached on the `varde-memcached` base image. There is nothing to compile and
no config file — memcached is configured entirely with command-line flags, so
this example is just the base image plus a `CMD` with explicit flags.

The base image runs as-is too:

```sh
docker run --rm -p 11211:11211 ghcr.io/mathiasror/varde-memcached:latest
```

That listens on `0.0.0.0:11211` with memcached's defaults (64MB cache, 1024
connections, no auth). To change anything, override `CMD` — Docker appends it
to the `ENTRYPOINT ["/runtime/bin/memcached"]`:

```dockerfile
# runs: memcached -m 256
CMD ["-m", "256"]
```

or pass flags directly on `docker run`:

```sh
docker run --rm -p 11211:11211 ghcr.io/mathiasror/varde-memcached:latest -m 256
```

Build and try this example:

```sh
docker build -t my-memcached .
docker run --rm -p 11211:11211 my-memcached
printf 'stats\r\nquit\r\n' | nc localhost 11211   # -> STAT uptime ...
```

Notes:

- Memcached refuses to start as root; the varde base runs as uid 1000 (`app`),
  so no `-u` flag is needed.
- Purely in-memory: no volumes, nothing written to disk.
- No authentication is compiled in (no SASL); keep it on a private network or
  front it with a proxy.
- The bare `:latest` tag is musl (varde's default libc); use `:latest-glibc`
  for glibc. Memcached works on either.
