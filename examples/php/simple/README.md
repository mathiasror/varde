# varde-php — simple

The "hello world" of the distroless PHP contract: one `COPY`, no builder stage.

```console
$ docker build -t php-simple .
$ docker run --rm php-simple
varde ok
```

## The contract in 20 seconds

- The base is the PHP CLI plus `php-fpm` with nixpkgs' **default extension set
  minus `ldap`** (bcmath curl dom fileinfo gd intl mbstring opcache openssl
  pdo_mysql pdo_pgsql pdo_sqlite sodium zip …) — no shell, no composer, no
  pecl. `mail()` fails cleanly (there is no sendmail): send over SMTP from the
  app.
- Non-root `1000:1000`, `WORKDIR /app`, `ENTRYPOINT ["/runtime/bin/php"]`,
  `CMD ["/app/index.php"]` — so dropping `index.php` in `/app` is all it takes.
- Bare tags are musl (`:8.5`); opt into glibc with `:8.5-glibc`.
- **Dependencies**: there is no composer in the image — resolve `vendor/` in a
  `composer:2` builder stage and `COPY` it into `/app/vendor`.
- **php-fpm** (e.g. behind varde-nginx): override the entrypoint and the stop
  signal —
  `ENTRYPOINT ["/runtime/bin/php-fpm", "-F", "-y", "/app/php-fpm.conf"]` plus
  `STOPSIGNAL SIGQUIT`. php-fpm treats SIGTERM/SIGINT (what `docker stop` and
  a Kubernetes pod termination send by default) as immediate termination —
  workers are SIGTERMed and in-flight requests abort — while SIGQUIT is the
  graceful stop that lets workers finish their current request (same reason
  varde-nginx and the official `php:*-fpm` images set it; the base image
  leaves the stop signal unset because its default entrypoint is the CLI).
  SIGQUIT alone is **not** enough: `process_control_timeout` defaults to `0`,
  so the master escalates to SIGTERM on the next event-loop tick and kills
  workers mid-request anyway — set it, and keep it below the container's stop
  grace period (`docker stop`: 10s, Kubernetes `terminationGracePeriodSeconds`:
  30s), otherwise the outer SIGKILL lands first.
  The conf **must** set `error_log`: php-fpm's compiled-in default log path
  lives inside the read-only Nix store, which uid 1000 cannot open, so fpm
  aborts at startup (`failed to open error_log` / `FPM initialization
  failed`). `-p <prefix>` is not a workaround unless that prefix has a
  writable `log/` dir. No `user`/`group` lines are needed (already
  `1000:1000`). Minimum `/app/php-fpm.conf`:

  ```ini
  [global]
  error_log = /proc/self/fd/2
  process_control_timeout = 5s
  [www]
  listen = 9000
  pm = static
  pm.max_children = 4
  ```

- **Extra ini settings**: extensions load from the default
  `PHP_INI_SCAN_DIR=/runtime/lib`; append your own directory instead of
  replacing it: `ENV PHP_INI_SCAN_DIR=/runtime/lib:/app/php.d`.
- **More extensions**: pecl/phpize are deliberately absent (a package manager
  has no place in a distroless runtime). Build your own runtime with Nix
  (`php85.withExtensions` / `php85.buildEnv`) and relocate it the way
  [`images/php.nix`](../../../images/php.nix) does.
