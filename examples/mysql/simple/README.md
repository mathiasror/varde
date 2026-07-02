# varde-mysql: simple example

A seeded MySQL 8.4 on the `varde-mysql` base image — no shell, no package
manager, non-root (`1000:1000`), `WORKDIR /app`.

## The two-step contract

MySQL needs a one-time data-directory initialization before it can serve.
MySQL 8 does this **natively** (`mysqld --initialize-insecure`), so it works in
an image with no shell — that is why this image is MySQL and not MariaDB
(`mariadb-install-db` is a shell script). The base image's entrypoint **is**
`mysqld`, and `/etc/my.cnf` bakes the sane defaults (`datadir=/app/data`,
socket + pid file under `/tmp`, `bind-address=0.0.0.0`, X-plugin off,
`secure-file-priv=NULL`), so both steps are just arguments:

```sh
# 1) one-time init: creates /app/data with system tables
#    ('root'@'localhost', EMPTY password — socket-only, inside the container)
docker run --rm -v mysql-data:/app ghcr.io/mathiasror/varde-mysql:latest --initialize-insecure

# 2) run it
docker run -d --name db -v mysql-data:/app -p 3306:3306 ghcr.io/mathiasror/varde-mysql:latest

# health check — a real binary, no shell:
docker exec db /runtime/bin/mysqladmin -u root ping   # -> mysqld is alive
```

Mount the volume at **`/app`** (not `/app/data`): `/app` is owned by `1000` in
the image, so a fresh named volume inherits that ownership and the non-root
server can create `data/` inside it. If you bind-mount a host directory
instead, `chown 1000:1000` it first.

## This example: init baked at build time

Docker's exec-form `RUN` needs no shell, so the Dockerfile performs step 1
**during `docker build`** and bakes the initialized data directory into the
image. Startup is instant and self-contained — ideal for demos, CI and
throwaway databases. The same initialize run executes `init.sql` natively
(`--init-file`), seeding a `demo` database and a `demo` user for network
clients:

```sh
docker build -t my-mysql .
docker run --rm -p 3306:3306 my-mysql
mysql -h 127.0.0.1 -u demo -pdemo-password demo -e 'SELECT 1'
```

**Production note:** baked data (and the demo credentials in `init.sql`) belong
to demos only. For real deployments keep the image stock and run the two-step
contract above against a volume, creating users at deploy time.

## Notes and limits of the distroless base

- `mysqld` refuses to run as root; the image already runs as `1000:1000`.
- Ships `mysqld`, `mysql`, `mysqladmin`, `mysqldump` under `/runtime/bin`
  (that's `PATH`) — enough to serve, administer, health-check and back up.
- Only English server messages are shipped (`lc_messages` must stay `en_US`),
  and the time-zone tables are empty — use numeric offsets
  (`SET time_zone = '+02:00'`).
- Override any server default per-run with mysqld flags (they beat
  `/etc/my.cnf`), e.g. `docker run ... my-mysql --port=3307`.
