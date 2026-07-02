#!/usr/bin/env bash
# varde example e2e: build each base image locally with Nix, then build every
# example on top of it, smoke-test that the app runs, and assert an image-size
# budget. Linux + Docker + Nix required (the bases can't be built on Darwin).
#
#   scripts/e2e.sh                 # run all examples
#   scripts/e2e.sh node-express …  # run only the named example(s)
#
# The default bases are the MUSL variants (varde's default libc), so this also
# proves the musl images build and run end to end. musl node/nginx/redis build
# from source, so a full run can take a while. Failures are collected (the run
# does not stop at the first one) and reported in a table; exit is non-zero if
# any example failed to build, failed its smoke test, or exceeded its budget.
set -euo pipefail

cd "$(dirname "$0")/.."
ONLY=("$@")

# name | dir | baseAttr (nix) | baseName (varde-<name>) | smoke | budgetMB
#   smoke: stdout:<needle> | http:<cport>:<path>:<needle> | redis | postgres | mysql | memcached
#   budgetMB: measured size + ~15% from the first green run (2026-07-02). If one
#   trips after a deliberate runtime addition, re-derive it the same way; if it
#   trips unexpectedly, investigate the closure regression — that's its job.
read -r -d '' TABLE <<'EOF' || true
go-simple|examples/go/simple|image-static-latest|static|stdout:varde ok|10
rust-simple|examples/rust/simple|image-glibc-latest|glibc|stdout:varde ok|55
python-simple|examples/python/simple|image-python-3_13-musl|python|stdout:varde ok|185
python-requirements-venv|examples/python/requirements-venv|image-python-3_13-musl|python|stdout:varde ok|190
python-uv|examples/python/uv|image-python-3_13-musl|python|stdout:varde ok|190
node-simple|examples/node/simple|image-node-24-musl|node|stdout:varde ok|215
node-express|examples/node/express|image-node-24-musl|node|http:8080:/:varde ok|220
jre-spring-boot|examples/jre/spring-boot-gradle|image-jre-21-musl|jre|http:8080:/:varde ok|320
php-simple|examples/php/simple|image-php-8_5-musl|php|stdout:varde ok|230
nginx-static-site|examples/nginx/static-site|image-nginx-latest-musl|nginx|http:8080:/:varde ok|30
redis-simple|examples/redis/simple|image-redis-latest-musl|redis|redis|35
postgres-simple|examples/postgres/simple|image-postgres-18-musl|postgres|postgres|115
mysql-simple|examples/mysql/simple|image-mysql-8_4-glibc|mysql|mysql|385
rabbitmq-simple|examples/rabbitmq/simple|image-rabbitmq-latest-musl|rabbitmq|http:15672:/:RabbitMQ|105
memcached-simple|examples/memcached/simple|image-memcached-latest-musl|memcached|memcached|15
EOF

CONTAINERS=()
# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap
cleanup() { for c in "${CONTAINERS[@]:-}"; do [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

selected() { # $1=name -> 0 if it should run
  [ "${#ONLY[@]}" -eq 0 ] && return 0
  local n; for n in "${ONLY[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

# --- build each needed base once, tag it varde-<name>:e2e -------------------
declare -A BUILT
build_base() { # $1=attr $2=name ; returns non-zero on failure
  [ -n "${BUILT[$2]:-}" ] && return 0
  echo "==> nix build .#$1  (base varde-$2)"
  nix build -L ".#$1" || return 1
  local ref
  ref=$(docker load -i result | sed -n 's/^Loaded image: //p' | head -n1) || return 1
  [ -n "$ref" ] || return 1
  docker tag "$ref" "varde-$2:e2e" || return 1
  BUILT[$2]=1
}

# --- smoke helpers (explicit returns; safe under `if !`) --------------------
smoke_stdout() { # $1=image $2=needle
  docker run --rm "$1" | grep -q "$2"
}
smoke_http() { # $1=image $2=cport $3=path $4=needle
  local cid host body
  cid=$(docker run -d -p "127.0.0.1:0:$2" "$1"); CONTAINERS+=("$cid")
  host=$(docker port "$cid" "$2/tcp" | head -n1 | sed 's/.*://')
  # 30s: nginx answers in one tick; rabbitmq's management UI needs ~10s.
  for _ in $(seq 1 60); do
    body=$(curl -fsS "http://127.0.0.1:${host}${3}" 2>/dev/null || true)
    if printf '%s' "$body" | grep -q "$4"; then docker rm -f "$cid" >/dev/null; return 0; fi
    sleep 0.5
  done
  echo "   http smoke failed; last 20 log lines:"; docker logs "$cid" 2>&1 | tail -20
  docker rm -f "$cid" >/dev/null; return 1
}
smoke_redis() { # $1=image
  local cid
  cid=$(docker run -d "$1"); CONTAINERS+=("$cid")
  for _ in $(seq 1 40); do
    if docker exec "$cid" /runtime/bin/redis-cli ping 2>/dev/null | grep -q PONG; then
      docker rm -f "$cid" >/dev/null; return 0
    fi
    sleep 0.5
  done
  echo "   redis smoke failed; last 20 log lines:"; docker logs "$cid" 2>&1 | tail -20
  docker rm -f "$cid" >/dev/null; return 1
}
smoke_postgres() { # $1=image ; one-time initdb against a volume, then run + query
  local cid vol="vpg-$$"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "$vol:/app" --entrypoint /runtime/bin/initdb "$1" -U postgres --auth=trust \
    || { docker volume rm "$vol" >/dev/null; return 1; }
  cid=$(docker run -d -v "$vol:/app" "$1"); CONTAINERS+=("$cid")
  for _ in $(seq 1 40); do
    if docker exec "$cid" /runtime/bin/psql -U postgres -tAc 'SELECT 1' 2>/dev/null | grep -qx 1; then
      docker rm -f "$cid" >/dev/null; docker volume rm "$vol" >/dev/null; return 0
    fi
    sleep 0.5
  done
  echo "   postgres smoke failed; last 20 log lines:"; docker logs "$cid" 2>&1 | tail -20
  docker rm -f "$cid" >/dev/null; docker volume rm "$vol" >/dev/null; return 1
}
smoke_mysql() { # $1=image ; example bakes its datadir at build -> run + ping
  local cid
  cid=$(docker run -d "$1"); CONTAINERS+=("$cid")
  for _ in $(seq 1 60); do
    if docker exec "$cid" /runtime/bin/mysqladmin -u root ping 2>/dev/null | grep -q alive; then
      docker rm -f "$cid" >/dev/null; return 0
    fi
    sleep 0.5
  done
  echo "   mysql smoke failed; last 20 log lines:"; docker logs "$cid" 2>&1 | tail -20
  docker rm -f "$cid" >/dev/null; return 1
}
memcached_probe() { # $1=host port -> 0 if stats answer; bash /dev/tcp, no client needed
  exec 3<>"/dev/tcp/127.0.0.1/$1" || return 1
  printf 'stats\r\nquit\r\n' >&3
  local rc=1
  grep -q "STAT uptime" <&3 && rc=0
  exec 3>&- 3<&- || true
  return "$rc"
}
smoke_memcached() { # $1=image ; no client in the image -> host-side TCP stats
  local cid host
  cid=$(docker run -d -p "127.0.0.1:0:11211" "$1"); CONTAINERS+=("$cid")
  host=$(docker port "$cid" "11211/tcp" | head -n1 | sed 's/.*://')
  for _ in $(seq 1 40); do
    if memcached_probe "$host" 2>/dev/null; then docker rm -f "$cid" >/dev/null; return 0; fi
    sleep 0.5
  done
  echo "   memcached smoke failed; last 20 log lines:"; docker logs "$cid" 2>&1 | tail -20
  docker rm -f "$cid" >/dev/null; return 1
}

row() { ROWS+=("$(printf '%-26s %-14s %8s  %8s  %s' "$1" "$2" "$3" "$4" "$5")"); }

# --- run --------------------------------------------------------------------
ROWS=(); FAILED=0
while IFS='|' read -r name dir attr base smoke budget; do
  [ -n "$name" ] || continue
  selected "$name" || continue
  echo "::group::$name"

  if ! build_base "$attr" "$base"; then
    row "$name" "varde-$base" "-" "${budget}MB" "BASE-FAIL"; FAILED=1; echo "::endgroup::"; continue
  fi

  img="varde-ex-${name}:e2e"
  echo "==> docker build $dir  (BASE_IMAGE=varde-$base:e2e)"
  if ! docker build --build-arg "BASE_IMAGE=varde-$base:e2e" -t "$img" "$dir"; then
    row "$name" "varde-$base" "-" "${budget}MB" "BUILD-FAIL"; FAILED=1; echo "::endgroup::"; continue
  fi

  smoke_rc=0
  case "$smoke" in
    stdout:*) smoke_stdout "$img" "${smoke#stdout:}" || smoke_rc=$? ;;
    http:*)   IFS=: read -r _ cport path needle <<<"$smoke"; smoke_http "$img" "$cport" "$path" "$needle" || smoke_rc=$? ;;
    redis)    smoke_redis "$img" || smoke_rc=$? ;;
    postgres) smoke_postgres "$img" || smoke_rc=$? ;;
    mysql)    smoke_mysql "$img" || smoke_rc=$? ;;
    memcached) smoke_memcached "$img" || smoke_rc=$? ;;
    *)        echo "unknown smoke kind: $smoke"; smoke_rc=1 ;;
  esac

  bytes=$(docker image inspect -f '{{.Size}}' "$img")
  mb=$(( (bytes + 1048575) / 1048576 ))
  result="OK"
  [ "$smoke_rc" -eq 0 ] || { result="SMOKE-FAIL"; FAILED=1; }
  if [ "$mb" -gt "$budget" ]; then result="SIZE-FAIL(${mb}>${budget})"; FAILED=1; fi
  row "$name" "varde-$base" "${mb}MB" "${budget}MB" "$result"
  echo "::endgroup::"
done <<<"$TABLE"

# --- report -----------------------------------------------------------------
{
  echo ""
  printf '%-26s %-14s %8s  %8s  %s\n' "EXAMPLE" "BASE" "SIZE" "BUDGET" "RESULT"
  [ "${#ROWS[@]}" -gt 0 ] && printf '%s\n' "${ROWS[@]}"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "$FAILED"
