# varde-php — simple

The "hello world" of the distroless PHP contract: one `COPY`, no builder stage.

```console
$ docker build -t php-simple .
$ docker run --rm php-simple
varde ok
```

## The contract in 20 seconds

- The base is the PHP CLI plus `php-fpm` with nixpkgs' **default extension set**
  (bcmath curl dom fileinfo gd intl mbstring opcache openssl pdo_mysql pdo_pgsql
  pdo_sqlite sodium zip …) — no shell, no composer, no pecl.
- Non-root `1000:1000`, `WORKDIR /app`, `ENTRYPOINT ["/runtime/bin/php"]`,
  `CMD ["/app/index.php"]` — so dropping `index.php` in `/app` is all it takes.
- Bare tags are musl (`:8.5`); opt into glibc with `:8.5-glibc`.
- **Dependencies**: there is no composer in the image — resolve `vendor/` in a
  `composer:2` builder stage and `COPY` it into `/app/vendor`.
- **php-fpm** (e.g. behind varde-nginx): override the entrypoint —
  `ENTRYPOINT ["/runtime/bin/php-fpm", "-F", "-y", "/app/php-fpm.conf"]`.
- **Extra ini settings**: extensions load from the default
  `PHP_INI_SCAN_DIR=/runtime/lib`; append your own directory instead of
  replacing it: `ENV PHP_INI_SCAN_DIR=/runtime/lib:/app/php.d`.
- **More extensions**: pecl/phpize are deliberately absent (a package manager
  has no place in a distroless runtime). Build your own runtime with Nix
  (`php85.withExtensions` / `php85.buildEnv`) and relocate it the way
  [`images/php.nix`](../../../images/php.nix) does.
