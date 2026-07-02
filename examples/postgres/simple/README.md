# varde-postgres: the two-step contract

`varde-postgres` is distroless: **no shell, no package manager, no
entrypoint script**. The docker-library image initializes the cluster from a
shell script on first boot; that approach is impossible here, and faking it
would mean smuggling a shell back in. So initialization is honest and explicit
— two steps that share one volume:

1. **once**: run `initdb` as the container command (via `--entrypoint`);
2. **always**: run the image as-is — the entrypoint is `postgres`.

Everything below execs real binaries from the image (`/runtime/bin/...`);
nothing needs a shell inside the container.

## 1. Build

```sh
docker build -t my-postgres .
```

This bakes in [`pg_hba.conf`](pg_hba.conf) (trust in-container connections,
require SCRAM passwords from everyone else) — see the Dockerfile for why.

## 2. Initialize the cluster (one time)

```sh
echo 'change-me' | docker run --rm -i -v pgdata:/app \
  --entrypoint /runtime/bin/initdb my-postgres \
  -U postgres --pwfile=/dev/stdin \
  --auth-local=trust --auth-host=scram-sha-256
```

- **Mount the volume at `/app`, not `/app/data`.** The image's `/app` is owned
  by `1000:1000`, so a fresh named volume inherits that ownership and `initdb`
  (uid 1000) can create the data directory `/app/data` inside it. A volume
  mounted directly at `/app/data` would be root-owned and initdb would refuse.
- `PGDATA=/app/data` is set by the base image — no `-D` needed.
- `-U postgres` names the superuser (otherwise it would be `app`, the OS user).
- `--pwfile=/dev/stdin` reads the superuser password from the piped stdin — no
  password file to `COPY` in, nothing left behind in the image or the volume.
- The framework's `LANG=C.UTF-8` gives you a UTF8-encoded cluster.

Bind mounts work too (`-v "$PWD/pgdata:/app"`) if the host directory is owned
by uid 1000.

## 3. Run

```sh
docker run -d --name pg -p 5432:5432 -v pgdata:/app my-postgres
```

## 4. Verify / use

```sh
docker exec pg /runtime/bin/pg_isready -U postgres
docker exec pg /runtime/bin/psql -U postgres -c 'SELECT version();'
```

(These connect over the unix socket in `/tmp` — `PGHOST=/tmp` is set in the
image — and are trusted by `pg_hba.conf`, like a local `sudo -u postgres psql`.)

From the host or another container, it's a normal PostgreSQL with password
auth:

```sh
psql -h 127.0.0.1 -U postgres   # password: change-me
```

## Tuning and notes

- Extra server flags append to the run command (they go straight to
  `postgres`, later flags override earlier ones):

  ```sh
  docker run -d -p 5432:5432 -v pgdata:/app my-postgres \
    -c hba_file=/etc/postgresql/pg_hba.conf -c shared_buffers=512MB
  ```

  Note a `docker run` command **replaces** the Dockerfile `CMD`, so restate the
  `hba_file` flag as above (or bake all your flags into your own `CMD`).
- Major upgrades are new clusters: `pg_upgrade` orchestration is out of scope
  for a distroless image — dump/restore across versions instead.
- Parallel-query-heavy workloads may want more shared memory than Docker's
  64 MB `/dev/shm` default: add `--shm-size=256m`.
- libc collations can't be imported at initdb time (that requires `locale -a`
  through a shell); `C`/`C.UTF-8` plus ICU collations
  (`CREATE COLLATION ... (provider = icu, ...)` or
  `initdb --locale-provider=icu`) cover the usual cases.
- Prefer glibc? Use the `:18-glibc` tag — the contract is identical.
