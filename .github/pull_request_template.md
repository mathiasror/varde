<!-- Security issues: report privately (see SECURITY.md), not in a PR. -->

## What and why

<!-- One change per PR. Link the issue, CI run or upstream bug it addresses. -->

## Images and tags affected

<!-- e.g. varde-redis:latest (musl + glibc), or "all" for lib/ or flake changes -->

## Testing

<!-- e.g. nix build .#image-redis-latest-musl + docker run, scripts/e2e.sh redis-simple, or "PR CI only" -->

## Checklist

- [ ] No shell, package manager or `-dev` output in the closure, and nothing new in `closureAllow`
- [ ] Still runs as `1000:1000`
- [ ] New image or tag: README and site lists, a smoke test in `build.yml`, an example and a `scripts/e2e.sh` row
- [ ] Any new VEX statement cites evidence
- [ ] Conventional commit messages (`fix(redis): …`)
