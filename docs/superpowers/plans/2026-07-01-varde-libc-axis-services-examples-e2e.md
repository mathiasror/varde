# varde expansion — libc axis, bases, services, examples, e2e — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make musl the default libc (glibc opt-in) across varde's runtime/service images, replace `varde-go`/`varde-rust` with `varde-static`/`varde-musl`/`varde-glibc` (go/rust kept as alias digests), add `varde-nginx`/`varde-redis`, restructure examples into per-image buildable projects, and add a CI e2e harness with size budgets.

**Architecture:** Keep the data-driven flake. `lib/default.nix` gains a libc-aware FHS layout (`mkLibcEnv`) and a `mkVariants` helper that crosses `version × libc`. Modules emit libc-qualified variant tags (`3.13-musl`, `3.13-glibc`); the flake maps them to per-arch images and exposes `imageAliases`; CI's manifest job assembles multi-arch lists, bare/`latest`/`latest-glibc` aliases, and the go/rust image-alias digests. Examples take `ARG BASE_IMAGE` so a CI e2e job can build them against locally-built bases and assert size budgets.

**Tech Stack:** Nix flakes, nixpkgs `dockerTools.buildLayeredImage`, `pkgsMusl`, GitHub Actions, skopeo/buildx, Trivy, sbomnix, Docker.

## Global Constraints

- Non-root `1000:1000`, no shell, no package manager, `/app` + sticky `/tmp`, CA certs, tzdata, OCI labels, per-image SBOM app — unchanged, libc-agnostic. (spec §Component 1)
- **musl = default (bare tag); glibc = opt-in (`-glibc` suffix).** Per-arch tags are always libc-qualified (`<v>-<libc>-<arch>`); bare `<v>`, `latest`, `latest-glibc` are manifest aliases. (spec §Naming)
- `varde-static` has `libc = null` (no FHS); `varde-musl`/`varde-glibc` set `fhs = true`. Aliases: `varde-go`→static, `varde-rust`→glibc. (spec §Component 2)
- musl JRE only where an Adoptium alpine prebuilt exists: `jre-17` is **glibc-only** (no aarch64 alpine); `jre-21`/`25` musl+glibc (verify 25 aarch64). A version with a musl build missing on any published arch is treated glibc-only. (spec §Findings)
- Service images relocate the nixpkgs binary under `/runtime`, **no `fhs`** (RPATH). nginx: non-root config, `listen 8080`, temp/pid in `/tmp`, `root /app`. (spec §Component 3)
- No Cachix now; musl-from-source builds are acceptable (public repo = free CI minutes, `fail-fast: false`). (spec §Findings)
- Every example Dockerfile: `ARG BASE_IMAGE=<pinned public tag>` then `FROM ${BASE_IMAGE}`. (spec §Component 4)
- Verify locally only via `nix eval`/`nix flake check`/`actionlint`/`shellcheck` (Darwin can't build Linux images); real build/smoke proof is CI. (spec §Testing)

---

## Phase A — libc-aware framework + convert jre/python/node

### Task A1: libc-aware FHS layout (`mkLibcEnv`) in `lib/default.nix`

**Files:** Modify `lib/default.nix` (replace `mkFhsEnv`).

**Interfaces:**
- Produces: `vardeLib.mkLibcEnv : pkgs -> ("musl"|"glibc") -> derivation` (an FHS libc layout).

- [ ] **Step 1: Replace `mkFhsEnv` with `mkLibcEnv`.** New code:

```nix
  # FHS-style loader + libc so EXTERNALLY-compiled dynamic binaries (a normal
  # cargo/gcc build, a manylinux/musllinux wheel .so, a native node addon) find
  # their loader and libs. `libc` selects glibc or musl; the targets come from the
  # same package set used for the image's runtime, so there is never a mismatch.
  mkLibcEnv =
    pkgs: libc:
    let
      sel = if libc == "musl" then pkgs.pkgsMusl else pkgs;
      libcPkg = if libc == "musl" then sel.musl else sel.glibc;
      cxx = sel.stdenv.cc.cc.lib; # libstdc++.so.6 + libgcc_s.so.1
      libDirs = [ "${libcPkg}/lib" "${cxx}/lib" ];
    in
    pkgs.runCommand "varde-${libc}-env" { } ''
      mkdir -p "$out/lib" "$out/lib64"
      for d in ${lib.escapeShellArgs libDirs}; do
        for so in "$d"/*.so*; do
          [ -e "$so" ] || continue
          ln -sfn "$so" "$out/lib/$(basename "$so")"
        done
      done
      # Dynamic loader at the conventional path(s): glibc ld-linux-*.so (both /lib
      # and /lib64) and musl ld-musl-<arch>.so.1 (/lib). One glob covers both.
      for ld in ${libcPkg}/lib/ld-*.so*; do
        [ -e "$ld" ] || continue
        ln -sfn "$ld" "$out/lib/$(basename "$ld")"
        ln -sfn "$ld" "$out/lib64/$(basename "$ld")"
      done
      mkdir -p "$out/usr"
      ln -s /lib "$out/usr/lib"
    '';
```

- [ ] **Step 2: Update `imageContents` and `buildImage` to use `libc`.** In `imageContents`, replace the `mkFhsEnv` optional with:

```nix
    ++ lib.optional (spec.fhs or false) (mkLibcEnv pkgs (spec.libc or "glibc"))
    ++ (spec.contents or [ ]);
```

`buildImage`'s `LD_LIBRARY_PATH` line stays gated on `spec.fhs` (unchanged: `lib.optional (spec.fhs or false) "LD_LIBRARY_PATH=/lib:/lib64"`).

- [ ] **Step 3: Verify eval.** Run: `nix eval .#ciMatrix >/dev/null && echo OK`  Expected: `OK` (still evaluates; no images reference musl yet).
- [ ] **Step 4: Commit.** `git add lib/default.nix && git commit -m "lib: libc-aware FHS layout (mkLibcEnv) replacing mkFhsEnv"`

### Task A2: `mkVariants` helper + shared bin specs in `lib/default.nix`

**Files:** Modify `lib/default.nix`.

**Interfaces:**
- Produces:
  - `vardeLib.mkVariants : pkgs -> { versions } -> variantsAttrs` where `versions` is `{ "<tag>" = { spec = libcPkgs: <spec-without-libc>; libcs ? ["musl" "glibc"]; }; }` and the result is `{ "<tag>-<libc>" = <spec with libc set>; }`.
  - `vardeLib.staticSpec`, `vardeLib.glibcSpec`, `vardeLib.muslSpec` (compiled-binary base specs).

- [ ] **Step 1: Add helpers.**

```nix
  # Cross version-tags with libcs into libc-qualified variants. `spec` is a
  # function of the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl),
  # so the runtime is built against the right libc. A version may restrict `libcs`
  # (e.g. jre-17 is glibc-only where no musl prebuilt exists).
  mkVariants =
    pkgs:
    { versions }:
    lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (
      tag: v:
      map (
        libc:
        let libcPkgs = if libc == "musl" then pkgs.pkgsMusl else pkgs;
        in lib.nameValuePair "${tag}-${libc}" ((v.spec libcPkgs) // { inherit libc; })
      ) (v.libcs or [ "musl" "glibc" ])
    ) versions));

  # Compiled-binary bases (single-variant, entrypoint runs /app/app).
  staticSpec = { entrypoint = [ "/app/app" ]; libc = null; };            # scratch-like
  glibcSpec  = { entrypoint = [ "/app/app" ]; libc = "glibc"; fhs = true; };
  muslSpec   = { entrypoint = [ "/app/app" ]; libc = "musl";  fhs = true; };
```

- [ ] **Step 2: Verify eval** (`nix eval .#ciMatrix >/dev/null && echo OK`). Expected `OK`.
- [ ] **Step 3: Commit.** `git commit -am "lib: mkVariants (version×libc) + static/glibc/musl bin specs"`

### Task A3: flake — libc in entries, default-libc bare aliases, `imageAliases`

**Files:** Modify `flake.nix`.

**Interfaces:**
- Produces flake outputs: `packages.*` (attrs like `image-python-3_13-musl`), `apps.*` (`sbom-python-3_13-musl`), `ciMatrix` (each entry now includes `libc`), `latestTags` (unchanged shape: image→version), `imageAliases = { go = "static"; rust = "glibc"; }`.

- [ ] **Step 1:** In `entriesFor`, add `libc = spec.libc or "glibc";` to each entry record and include it in the `ciMatrix` projection. The `attr`/`sbomName`/`tag` already carry the libc suffix because `tag` is now `"3.13-musl"`. Confirm `sanitize` handles it (`3.13-musl` → `3_13-musl`, unique).
- [ ] **Step 2:** Add the alias output:

```nix
      imageAliases = { go = "static"; rust = "glibc"; };
```
and include `inherit imageAliases;` in the returned attrset.

- [ ] **Step 3:** Update `default` package fallback: `image-jre-21` no longer exists (it's `image-jre-21-musl`). Change the fallback to `attrs."image-jre-21-musl"` guarded by `attrs ? "image-jre-21-musl"`.
- [ ] **Step 4:** `latestTags` keeps returning the *version* per image (e.g. `jre="21"`); the bare/`latest` libc resolution (musl-if-present-else-glibc) is done in CI (Task A6) from `ciMatrix`. Keep the `throw`-on-missing-`latest` guard.
- [ ] **Step 5: Verify.** After A4 lands the converted modules, `nix eval --json .#ciMatrix | jq 'length, (.[0])'` shows libc-qualified entries with a `libc` field, and `nix eval --json .#imageAliases`.
- [ ] **Step 6: Commit.** `git commit -am "flake: libc-qualified entries + imageAliases output"`

### Task A4: convert `jre`/`python`/`node` modules to `mkVariants`

**Files:** Modify `images/jre.nix`, `images/python.nix`, `images/node.nix`.

- [ ] **Step 1: python.nix** — `fhs` now applies to whichever libc:

```nix
{ pkgs, vardeLib, lib }:
let
  pySpec = p: py: {
    contents = [ (vardeLib.relocate p "varde-python-root-${py.version}" "runtime" py) ];
    entrypoint = [ "/runtime/bin/python3" ];
    cmd = [ "/app/main.py" ];
    env = [ "PATH=/runtime/bin" "PYTHONDONTWRITEBYTECODE=1" "PYTHONUNBUFFERED=1" ];
    fhs = true; # manylinux (glibc) / musllinux (musl) wheels' native .so
  };
in
{
  description = "Minimal distroless CPython runtime for Python apps";
  latest = "3.13";
  variants = vardeLib.mkVariants pkgs {
    versions = {
      "3.11" = { spec = p: pySpec p p.python311; };
      "3.12" = { spec = p: pySpec p p.python312; };
      "3.13" = { spec = p: pySpec p p.python313; };
    };
  };
}
```

- [ ] **Step 2: node.nix** — same shape, `nodejs-slim_<v>`, `fhs = true`, versions `22`,`24`.
- [ ] **Step 3: jre.nix** — no `fhs`; keep the JRE-home relocate; `17` is `libcs = ["glibc"]`:

```nix
  variants = vardeLib.mkVariants pkgs {
    versions = {
      "17" = { spec = p: jreSpec p p."temurin-jre-bin-17"; libcs = [ "glibc" ]; };
      "21" = { spec = p: jreSpec p p."temurin-jre-bin-21"; };
      "25" = { spec = p: jreSpec p p."temurin-jre-bin-25"; };
    };
  };
```
where `jreSpec = p: jre: { contents = [ (p.runCommand "varde-jre-root-${jre.version}" {} '' ...resolve java home, cp -a to $out/runtime... '') ]; entrypoint = [ "/runtime/bin/java" ]; cmd = [ "-jar" "/app/app.jar" ]; env = [ "JAVA_HOME=/runtime" "PATH=/runtime/bin" ]; };` (same body as today, parameterized by `p`).

- [ ] **Step 4: Verify eval + no accidental musl-17.** Run:
```bash
nix eval --json .#ciMatrix | jq -r '.[]|"\(.image)\t\(.tag)"' | sort
```
Expected includes `jre 21-musl`, `jre 21-glibc`, `jre 17-glibc`, **no** `jre 17-musl`; `python 3.13-musl`/`-glibc`; `node 24-musl`/`-glibc`.
- [ ] **Step 5:** Confirm musl JRE 25 aarch64 exists: `nix eval --raw nixpkgs#legacyPackages.aarch64-linux.pkgsMusl.temurin-jre-bin-25.outPath >/dev/null && echo has-25-arm64-musl || echo MISSING` — if MISSING, set `"25" = { …; libcs = ["glibc"]; }`.
- [ ] **Step 6: Commit.** `git commit -am "images: jre/python/node on the libc axis (musl default, glibc opt-in)"`

### Task A5: eval-level flake check

- [ ] **Step 1:** `nix flake check --no-build 2>&1 | tail` — no eval errors. (`--no-build` avoids Linux builds on Darwin.)
- [ ] **Step 2:** Sanity that a musl derivation *instantiates* (not builds): `nix eval --raw .#packages.x86_64-linux.image-python-3_13-musl.outPath >/dev/null && echo musl-instantiates`.
- [ ] **Step 3: Commit** any fixes.

### Task A6: CI — per-arch libc tags, manifest aliases, image aliases

**Files:** Modify `.github/workflows/build.yml`.

**Interfaces:** Consumes `ciMatrix` (with `libc`), `latestTags`, `imageAliases`.

- [ ] **Step 1: matrix** — `setup` already crosses `ciMatrix × arch`; entries now carry `libc` and libc-qualified `tag`. No change needed beyond passing `libc` through (it's already in each object).
- [ ] **Step 2: push step** — per-arch ref becomes `${img}:${TAG}-${ARCH}` where `TAG` is already libc-qualified (`21-musl`). So the pushed tag is `varde-jre:21-musl-amd64`. No code change (TAG carries libc).
- [ ] **Step 3: manifest job** — replace the assembly with libc-qualified multi-arch lists **plus** bare/`latest`/`latest-glibc` aliases and image aliases. New `run:` (env `MATRIX`, `LATEST`, `ALIASES` from `needs.setup.outputs`):

```bash
owner=$(echo "$OWNER" | tr '[:upper:]' '[:lower:]'); reg="${REGISTRY}"
imgref(){ echo "${reg}/${owner}/varde-$1"; }
# 1) One multi-arch list per image:libc-tag (e.g. varde-jre:21-musl).
printf '%s' "$MATRIX" | jq -r '.include[]|"\(.image) \(.tag)"' | sort -u \
| while read -r image tag; do
    i=$(imgref "$image")
    docker buildx imagetools create -t "${i}:${tag}" "${i}:${tag}-amd64" "${i}:${tag}-arm64"
  done
# 2) Bare version alias -> default libc (musl if built, else glibc).
printf '%s' "$MATRIX" | jq -r '.include[]|"\(.image) \(.tag)"' | sort -u \
| sed -E 's/-(musl|glibc)$//' | sort -u \
| while read -r image ver; do
    i=$(imgref "$image")
    if printf '%s' "$MATRIX" | jq -e --arg t "${ver}-musl" '.include[]|select(.tag==$t)' >/dev/null; then d=musl; else d=glibc; fi
    docker buildx imagetools create -t "${i}:${ver}" "${i}:${ver}-${d}-amd64" "${i}:${ver}-${d}-arm64"
  done
# 3) :latest (default-LTS, default libc) and :latest-glibc per image.
printf '%s' "$LATEST" | jq -r 'to_entries[]|"\(.key) \(.value)"' \
| while read -r image ver; do
    i=$(imgref "$image")
    if printf '%s' "$MATRIX" | jq -e --arg t "${ver}-musl" '.include[]|select(.tag==$t)' >/dev/null; then d=musl; else d=glibc; fi
    docker buildx imagetools create -t "${i}:latest"       "${i}:${ver}-${d}-amd64"    "${i}:${ver}-${d}-arm64"
    docker buildx imagetools create -t "${i}:latest-glibc" "${i}:${ver}-glibc-amd64"   "${i}:${ver}-glibc-arm64"
  done
# 4) Image aliases (varde-go -> varde-static, varde-rust -> varde-glibc): mirror all of the alias source's tags.
printf '%s' "$ALIASES" | jq -r 'to_entries[]|"\(.key) \(.value)"' \
| while read -r alias src; do
    a=$(imgref "$alias"); s=$(imgref "$src")
    for t in $(printf '%s' "$MATRIX" | jq -r --arg s "$src" '.include[]|select(.image==$s)|.tag' | sort -u); do
      docker buildx imagetools create -t "${a}:${t}" "${s}:${t}-amd64" "${s}:${t}-arm64"
      docker buildx imagetools create -t "${a}:latest" "${s}:${t}-amd64" "${s}:${t}-arm64"
    done
  done
```
Add `ALIASES: ${{ needs.setup.outputs.aliases }}` to env and `aliases: ${{ steps.gen.outputs.aliases }}` to `setup` outputs; in `setup`'s `gen` step add `aliases=$(nix eval --json .#imageAliases); echo "aliases=$aliases" >> "$GITHUB_OUTPUT"`.

- [ ] **Step 4: `actionlint`** — Run: `nix run nixpkgs#actionlint -- .github/workflows/build.yml`. Expected: exit 0.
- [ ] **Step 5: Commit.** `git commit -am "ci: libc-qualified tags + bare/latest/glibc + go/rust image aliases"`

---

## Phase B — compiled-binary bases (parallel with C, after A)

### Task B1: `static`/`musl`/`glibc` modules + delete go/rust

**Files:** Create `images/static.nix`, `images/musl.nix`, `images/glibc.nix`. Delete `images/go.nix`, `images/rust.nix`.

- [ ] **Step 1:** Each module (single-variant `latest`, using the shared specs; NOT on the libc-tag axis — the libc is the image identity, so plain `variants`):

```nix
# images/static.nix
{ pkgs, vardeLib, lib }:
{
  description = "Minimal distroless scratch-like base for statically-linked binaries";
  latest = "latest";
  variants."latest" = vardeLib.staticSpec;
}
```
`images/musl.nix` → `vardeLib.muslSpec`, description "…dynamically-linked musl binaries"; `images/glibc.nix` → `vardeLib.glibcSpec`, description "…dynamically-linked glibc binaries".

- [ ] **Step 2:** `git rm images/go.nix images/rust.nix`.
- [ ] **Step 3: Verify.** `nix eval --json .#ciMatrix | jq -r '.[]|.image' | sort -u` → includes `static`,`musl`,`glibc`; excludes `go`,`rust`. `nix eval --json .#imageAliases` → `{go:"static",rust:"glibc"}`.
- [ ] **Step 4:** These bases have tag `latest` (not libc-qualified). Confirm the CI manifest step #1 handles `varde-static:latest` (its per-arch tags are `latest-amd64`/`latest-arm64`, no libc token). ⚠️ The build push uses `TAG` = `latest`; manifest #1 builds `varde-static:latest` from `latest-amd64`/`latest-arm64`. Good. The bare-alias step #2 strips `-(musl|glibc)$` → `latest` unchanged, then looks for `latest-musl` (absent) → falls to glibc → tries `varde-static:latest-glibc-amd64` which doesn't exist. **Fix:** skip the bare-alias/latest-glibc steps for images whose tags have no libc suffix (static). Guard steps #2/#3 with: only process `image` if any of its tags match `-(musl|glibc)$`. Add that jq filter.
- [ ] **Step 5: Commit.** `git commit -m "images: static/musl/glibc bases; go/rust become aliases"`

### Task B2: harden CI manifest for non-libc images

**Files:** Modify `.github/workflows/build.yml` (manifest step from A6).

- [ ] **Step 1:** In steps #2 and #3, before creating bare/latest aliases, skip images with no libc-suffixed tags:
```bash
has_libc=$(printf '%s' "$MATRIX" | jq -r --arg im "$image" '[.include[]|select(.image==$im)|.tag]|any(test("-(musl|glibc)$"))')
[ "$has_libc" = "true" ] || continue
```
For static/musl/glibc, the plain `:latest` multi-arch list from step #1 is the published tag; `:latest` per-image also created in step #3 only for libc images (jre/python/node/redis/nginx). For static/musl/glibc, step #1 already made `:latest`. ✅
- [ ] **Step 2: actionlint**, then **Commit.**

---

## Phase C — service images (parallel with B, after A)

### Task C1: `redis` module + smoke test

**Files:** Create `images/redis.nix`. Modify `.github/workflows/build.yml` (smoke test).

- [ ] **Step 1:** `images/redis.nix`:
```nix
{ pkgs, vardeLib, lib }:
let
  redisSpec = p: {
    contents = [ (vardeLib.relocate p "varde-redis-root" "runtime" p.redis) ];
    entrypoint = [ "/runtime/bin/redis-server" ];
    env = [ "PATH=/runtime/bin" ];
    # no fhs: the nixpkgs redis binary finds its libs via RPATH
  };
in
{
  description = "Minimal distroless Redis server";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs { versions."latest" = { spec = redisSpec; }; };
}
```
This yields `latest-musl` (default) + `latest-glibc`.
- [ ] **Step 2:** Add to the `Smoke test` case in build.yml:
```bash
redis)  docker run --rm -d --name vr "$ref" >/dev/null
        for i in $(seq 1 20); do docker exec vr /runtime/bin/redis-cli ping 2>/dev/null | grep -q PONG && break; sleep 0.5; done
        docker exec vr /runtime/bin/redis-cli ping | grep -q PONG && echo "varde ok" || { docker logs vr; exit 1; }
        docker rm -f vr >/dev/null ;;
```
- [ ] **Step 3:** `nix eval --json .#ciMatrix | jq -r '.[]|select(.image=="redis")|.tag'` → `latest-musl`,`latest-glibc`. `actionlint`.
- [ ] **Step 4: Commit.** `git commit -m "images: varde-redis (musl default, glibc opt-in) + smoke test"`

### Task C2: `nginx` module (non-root config) + smoke test

**Files:** Create `images/nginx.nix`, `images/nginx.conf`. Modify build.yml.

- [ ] **Step 1:** `images/nginx.conf` (non-root):
```nginx
worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 1024; }
http {
  include       mime.types;
  default_type  application/octet-stream;
  access_log /dev/stdout;
  client_body_temp_path /tmp/client_body;
  proxy_temp_path       /tmp/proxy;
  fastcgi_temp_path     /tmp/fastcgi;
  uwsgi_temp_path       /tmp/uwsgi;
  scgi_temp_path        /tmp/scgi;
  sendfile on;
  server {
    listen 8080;
    server_name _;
    root /app;
    index index.html;
    location / { try_files $uri $uri/ =404; }
  }
}
```
- [ ] **Step 2:** `images/nginx.nix` — relocate nginx, and place the config + bundled `mime.types` at `/etc/nginx`:
```nix
{ pkgs, vardeLib, lib }:
let
  nginxSpec = p:
    let
      conf = p.runCommand "varde-nginx-conf" { } ''
        mkdir -p "$out/etc/nginx"
        cp ${./nginx.conf} "$out/etc/nginx/nginx.conf"
        cp ${p.nginx}/conf/mime.types "$out/etc/nginx/mime.types"
      '';
    in {
      contents = [ (vardeLib.relocate p "varde-nginx-root" "runtime" p.nginx) conf ];
      entrypoint = [ "/runtime/bin/nginx" "-g" "daemon off;" "-c" "/etc/nginx/nginx.conf" ];
      env = [ "PATH=/runtime/bin" ];
    };
in
{
  description = "Minimal distroless nginx (non-root, listens on :8080)";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs { versions."latest" = { spec = nginxSpec; }; };
}
```
⚠️ Verify the nixpkgs nginx `prefix`/`mime.types` path at implementation (`${pkgs.nginx}/conf/mime.types`); adjust if the layout differs. nginx uses relative `include mime.types` resolved against `-c` dir (`/etc/nginx`). Confirm nginx doesn't require a writable prefix beyond the `/tmp` temp paths.
- [ ] **Step 3:** Smoke test case:
```bash
nginx)  echo '<h1>varde ok</h1>' > index.html
        docker run --rm -d --name vn -p 18080:8080 -v "$PWD/index.html:/app/index.html:ro" "$ref" >/dev/null
        for i in $(seq 1 20); do curl -fsS localhost:18080 2>/dev/null | grep -q "varde ok" && break; sleep 0.5; done
        curl -fsS localhost:18080 | grep -q "varde ok" && echo "varde ok" || { docker logs vn; exit 1; }
        docker rm -f vn >/dev/null ;;
```
- [ ] **Step 4:** `actionlint`; eval check for `nginx` tags.
- [ ] **Step 5: Commit.** `git commit -m "images: varde-nginx (non-root :8080) + smoke test"`

---

## Phase D — examples restructure (after B/C)

### Task D1: scaffold `examples/<image>/<variant>/` + move simple ones

**Files:** Create dirs; `git rm` the old flat `examples/*.Dockerfile`; create new Dockerfiles/app sources.

- [ ] **Step 1:** Remove flat examples: `git rm examples/{jre,python,node,go,rust}.Dockerfile`.
- [ ] **Step 2:** `examples/go/simple/` — `main.go` (`package main; func main(){ println("varde ok") }` → use `fmt.Println`), `go.mod`, `Dockerfile`:
```dockerfile
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-static:latest   # a.k.a. varde-go:latest
FROM golang:1-bookworm AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .
FROM ${BASE_IMAGE}
COPY --from=build /out/app /app/app
```
- [ ] **Step 3:** `examples/rust/simple/` — `Cargo.toml`, `src/main.rs` (`fn main(){ println!("varde ok"); }`), `Dockerfile` with `ARG BASE_IMAGE=ghcr.io/mathiasror/varde-glibc:latest` (a.k.a. varde-rust), `rust:1-bookworm` build stage, `cargo build --release --locked`, copy to `/app/app`. Comment: musl-static → varde-static, musl-dynamic → varde-musl.
- [ ] **Step 4: Verify** each simple example's Dockerfile parses: `docker build --call=outline -f examples/go/simple/Dockerfile examples/go/simple >/dev/null 2>&1 || true` (真build is e2e/CI). At minimum `hadolint`/manual review. Commit.

### Task D2: python examples (simple, requirements-venv, uv)

**Files:** `examples/python/{simple,requirements-venv,uv}/…`

- [ ] **Step 1: simple** — `main.py` (`print("varde ok")`), `Dockerfile` `ARG BASE_IMAGE=ghcr.io/mathiasror/varde-python:3.13`, `FROM ${BASE_IMAGE}`, `COPY main.py /app/main.py`.
- [ ] **Step 2: requirements-venv** — `requirements.txt` (one small pure-python dep, e.g. `requests` for a musl-friendly test; note native deps need musllinux wheels), `main.py` importing it and printing "varde ok"; two-stage Dockerfile: builder `python:3.13-slim` `pip install --target=/app/site-packages -r requirements.txt`, runtime copies site-packages + `PYTHONPATH`. Note builder must match the runtime ABI+libc (musl → use a musl builder image or pure-python deps).
- [ ] **Step 3: uv** — `pyproject.toml` + `uv.lock` (a tiny project), `main.py`; builder stage `ghcr.io/astral-sh/uv:debian` (or install uv) → `uv export --frozen --no-dev > requirements.txt` then `uv pip install --target=/app/site-packages -r requirements.txt` (or `uv sync` into a copyable venv); runtime copies the resolved env. Keep it musl-aware in comments.
- [ ] **Step 4:** Commit. (e2e verifies builds.)

### Task D3: node examples (simple, express) + jre spring-boot

**Files:** `examples/node/{simple,express}/…`, `examples/jre/spring-boot-gradle/…`

- [ ] **Step 1: node/simple** — `main.js` (`console.log("varde ok")`), `Dockerfile` `ARG BASE_IMAGE=…varde-node:24`, `COPY main.js /app/main.js`.
- [ ] **Step 2: node/express** — production Express app: `package.json` (express dep, `"main":"src/server.js"`), `package-lock.json`, `src/server.js` (listens on `process.env.PORT||8080`, `GET /` → "varde ok", `GET /healthz` → 200). Two-stage: `node:24-slim` `npm ci --omit=dev`; runtime copies `node_modules`+`src`, CMD `/app/src/server.js`. Comment on musl: `node_modules` with native addons need musl-built addons (rebuild in a musl/alpine builder) — pure-JS deps are fine.
- [ ] **Step 3: jre/spring-boot-gradle** — minimal Spring Boot (pin the latest stable at build time; target Java 21): `build.gradle` (`org.springframework.boot` plugin, `java { toolchain=21 }`, a `bootJar`), `settings.gradle`, Gradle wrapper (`gradlew`, `gradle/wrapper/*`), `src/main/java/.../DemoApplication.java` + a `@RestController` `GET /` → "varde ok" and `GET /actuator/health`. Dockerfile: builder `gradle:8-jdk21` (or wrapper) `./gradlew --no-daemon bootJar`; runtime `ARG BASE_IMAGE=…varde-jre:21`, `COPY build/libs/*.jar /app/app.jar`.
- [ ] **Step 4:** Commit.

### Task D4: nginx + redis examples

**Files:** `examples/nginx/static-site/…`, `examples/redis/simple/…`

- [ ] **Step 1: nginx/static-site** — `site/index.html` ("varde ok"), `Dockerfile` `ARG BASE_IMAGE=…varde-nginx:latest`, `COPY site/ /app/`. Note it serves on :8080.
- [ ] **Step 2: redis/simple** — `redis.conf` (e.g. `save ""`, `appendonly no`, `maxmemory 64mb`), `Dockerfile` `ARG BASE_IMAGE=…varde-redis:latest`, `COPY redis.conf /app/redis.conf`, `CMD ["/app/redis.conf"]` (redis-server takes a config path as arg).
- [ ] **Step 3:** Commit.

---

## Phase E — e2e harness (after D)

### Task E1: `scripts/e2e.sh`

**Files:** Create `scripts/e2e.sh` (executable).

- [ ] **Step 1:** Script that: takes a list of `image:base-attr:example-dir:smoke-kind:budgetMB` rows; for each unique base, `nix build .#<attr>`, `docker load`, tag `varde-<image>:e2e`; then per example `docker build --build-arg BASE_IMAGE=varde-<image>:e2e -t varde-ex-<name>:e2e <dir>`; run the smoke test by kind (`http:PORT:PATH:NEEDLE`, `stdout:NEEDLE`, `redis`); read size via `docker image inspect -f '{{.Size}}'`; compare to budget×1MB; accumulate a table; exit non-zero if any build/smoke/size fails. Use `set -euo pipefail`, cleanup trap (`docker rm -f`). Full script written inline here (see repo). Include a data table of examples→bases→budgets matching Phase D.
- [ ] **Step 2:** `shellcheck scripts/e2e.sh` (via `nix run nixpkgs#shellcheck --`). Expected: clean.
- [ ] **Step 3: Commit.** `git commit -m "e2e: scripts/e2e.sh — build examples on local bases, smoke + size budgets"`

### Task E2: `.github/workflows/e2e.yml`

**Files:** Create `.github/workflows/e2e.yml`.

- [ ] **Step 1:** Workflow: `on: pull_request`/`push` `paths: [examples/**, images/**, lib/**, flake.nix, scripts/e2e.sh]`; `runs-on: ubuntu-latest`; steps: checkout, nix-installer (pinned SHA as in build.yml), then `run: scripts/e2e.sh` (Docker present on the runner); emit the size table to `$GITHUB_STEP_SUMMARY`.
- [ ] **Step 2:** `actionlint`. **Commit.**

---

## Phase F — docs & site (last)

### Task F1: README + design.md

**Files:** Modify `README.md`, `docs/design.md`.

- [ ] **Step 1: README image table** → static/musl/glibc(+go/rust aliases), jre/python/node (musl default, `-glibc` opt-in, jre-17 glibc-only note), nginx/redis. Update build/attr examples (`image-python-3_13-musl`). Add an "Examples" section linking `examples/<image>/<variant>/`. Update "Adding a new image" for the `mkVariants`/`libc` shape and the alias mechanism.
- [ ] **Step 2: design.md** → libc axis, `mkLibcEnv`, service-image pattern, alias digests, musl-default rationale.
- [ ] **Step 3:** `nix run nixpkgs#markdownlint-cli -- README.md docs/design.md` (or manual). Commit.

### Task F2: site sync

**Files:** Modify `site/index.html`, `site/styles.css` (if catalog card count/layout changes).

- [ ] **Step 1:** Catalog: replace the go/rust cards' framing; add static/musl/glibc, nginx, redis; add "musl by default, glibc on request" as a security point; keep pills/tag refs accurate (`:3.13` musl default). Update the hero/why copy that says "five runtimes" to the honest framing.
- [ ] **Step 2:** Serve locally + Playwright/Chrome render at desktop+375px; 0 console errors; screenshot the catalog. Commit.

### Task F3: final integration verification

- [ ] **Step 1:** `nix eval --json .#ciMatrix | jq 'group_by(.image)|map({(.[0].image): length})'` — sanity of the full matrix.
- [ ] **Step 2:** `nix flake check --no-build`; `actionlint .github/workflows/*.yml`; `shellcheck scripts/e2e.sh`.
- [ ] **Step 3:** Push; watch `build.yml` + `e2e.yml` in CI (the real build/smoke/size gate). Address any musl build failures by marking that (image,version) glibc-only with a documented note.
- [ ] **Step 4: Final commit** if fixes.

---

## Self-review notes

- **Spec coverage:** Component 1→Phase A; Component 2→Phase B; Component 3→Phase C; Component 4→Phase D; Component 5→Phase E; Component 6→Phase F. Tag scheme + aliases → A3/A6/B2. jre-17 exception → A4. ✅
- **Open items** (spec §Open verification) are wired as explicit verify steps: jre-25-aarch64-musl (A4 S5), musl node/redis/nginx buildability (F3 S3 / e2e), musl loader path (mkLibcEnv A1 + e2e rust), Spring Boot version (D3 S3). ✅
- **Interface consistency:** `mkLibcEnv`, `mkVariants`, `staticSpec/glibcSpec/muslSpec`, `imageAliases`, libc-qualified tags used consistently A→F. ✅
- **Non-libc bases** (static/musl/glibc, tag `latest`) explicitly excluded from bare/latest-glibc alias steps (B2). ✅
