# Debugging varde images

varde's production images have no shell, so `kubectl exec … sh` and
`docker exec … sh` fail with `exec: "sh": executable file not found in $PATH`.
That is deliberate, so don't add a shell to the image. Bring one alongside the
running container instead:

1. **Attach a debug container** that shares the app container's namespaces:
   a Kubernetes ephemeral container, or a Docker sidecar. The app keeps running,
   unchanged.
2. **Run a `-debug` tag** on a throwaway copy, for an app that won't start.

## The `-debug` tags

Every tag has a `-debug` sibling: `varde-python:3.13` → `varde-python:3.13-debug`,
`:3.13-glibc` → `:3.13-glibc-debug`, `varde-static:latest` →
`varde-static:latest-debug`, and so on. A `-debug` image is the production image
with its layers unchanged, plus a static busybox at `/busybox`. That gives you
`sh`, `ls`, `cat`, `ps`, `top`, `wget`, `netstat`, `nslookup`, `vi` and about
390 other applets. `/busybox` is at the end of `PATH`, so the image's own
binaries come first.

It keeps everything else: the user `1000:1000`, `WORKDIR /app`, and the same
entrypoint and cmd. It is signed and carries the same SBOM, OpenVEX,
vulnerability-scan and SLSA provenance attestations as the production tags (see
the [README](../README.md#supply-chain-signatures-sbom--provenance)). Its SBOM
and scan include the busybox.

> **Never run a `-debug` tag in production.** It contains the shell and userland
> that the production tags leave out on purpose. Use it only to troubleshoot,
> and remove it when you're done.

Two things to know when you use one:

- **The entrypoint is still the app's.** `varde-python:3.13-debug` still starts
  `python3 /app/main.py`. To get a shell, override the command: put `-- sh` at
  the end of a `kubectl debug` command, or pass `--entrypoint sh` to
  `docker run`.
- **Pick the tag that matches the app.** Use the same version and libc as the
  app's image, with `-debug` added. Then the runtime in the debug container
  (`/runtime/bin/python3`, the libc, the CA bundle) is the same one the app runs.
  An app image pinned by digest has no `-debug` digest of its own; use the
  matching `-debug` tag.

Why not just `--image=busybox`? It works for attaching. But the busybox image
runs as root, and Kubernetes refuses to start a root image under
`runAsNonRoot: true` or the `restricted` Pod Security Standard. A `-debug` tag
runs as `1000:1000`, the same user as the app.

## Kubernetes

### Attach to a running pod: an ephemeral container

```sh
kubectl debug -it <pod> --target=<container> \
  --image=ghcr.io/mathiasror/varde-python:3.13-debug -- sh
```

- **`--target=<container>`** puts the debug container in that container's
  process namespace, so `ps` shows the app as PID 1. The container runtime
  must support this; containerd and CRI-O do. If it doesn't, kubectl prints a
  warning and you only see your own processes.
- **The app's filesystem is at `/proc/1/root`.** The debug container has its
  own root filesystem (the `-debug` image), so the app's files are at
  `/proc/<pid>/root/...`, for example `ls /proc/1/root/app` or
  `cat /proc/1/root/etc/ssl/certs/ca-certificates.crt`. The kernel only lets
  you open another process's `/proc/<pid>/root` if you are allowed to trace it.
  Both containers run as uid 1000, so that works without extra capabilities.
  If your pod runs the app as another uid, run the debug container as that uid
  too.
- **The network is the pod's.** For example,
  `wget -qO- http://127.0.0.1:8080/healthz`, `netstat -tln` or
  `nslookup my-service`.
- **Namespaces with the `restricted` Pod Security Standard:** add
  `--profile=restricted`. The debug container then drops all capabilities and
  runs non-root with the `RuntimeDefault` seccomp profile, which a `-debug`
  image allows. kubectl's default profile is `general`.
- An ephemeral container can't be removed or restarted. Exiting the shell stops
  it, and it stays in the pod's status until the pod is deleted. Name it with
  `-c debugger` if you plan to `kubectl attach -it <pod> -c debugger` again
  while it is still running.

### A pod that crashes or never starts: debug a copy

An ephemeral container needs a running pod. For a crashlooping pod, make a copy
in which the app's container runs a shell from the `-debug` tag instead of the
app:

```sh
kubectl debug <pod> -it --copy-to=<pod>-debug --container=<container> \
  --set-image=<container>=ghcr.io/mathiasror/varde-python:3.13-debug -- sh
```

- `--set-image` swaps the container's image for the `-debug` tag. `--container`
  together with `-- sh` replaces that container's command, so the app doesn't
  start (and crash) on its own. Start it from the shell, using the image's
  entrypoint and cmd (`/runtime/bin/python3 /app/main.py` here), to see the
  error.
- The copy keeps the pod's env, volumes and service account. By default it
  drops labels, so Services don't route to it, and drops liveness, readiness
  and startup probes, so the kubelet doesn't restart it. Use `--keep-labels`
  or `--keep-liveness` to change that. Add `--same-node` to run it on the
  original's node.
- Process sharing is on in the copy (`--share-processes`, the default), so PID 1
  is the pod's `pause` container. Use `ps` to find the app's PID for
  `/proc/<pid>/root`.
- Delete the copy when you're done: `kubectl delete pod <pod>-debug`.

## Docker

### Look inside the image

```sh
docker run --rm -it --entrypoint sh ghcr.io/mathiasror/varde-python:3.13-debug
```

To see how your own app image looks with a shell, rebuild it on the `-debug`
base under a throwaway tag. Every example under [`examples/`](../examples/)
takes `ARG BASE_IMAGE`:

```sh
docker build --build-arg BASE_IMAGE=ghcr.io/mathiasror/varde-python:3.13-debug -t myapp:debug .
docker run --rm -it --entrypoint sh myapp:debug
```

### Attach to a running container: a sidecar

Start a `-debug` container in the running container's PID and network
namespaces:

```sh
docker run --rm -it --pid=container:<container> --network=container:<container> \
  --entrypoint sh ghcr.io/mathiasror/varde-python:3.13-debug
```

Inside it, `ps` lists the app's processes and the app's files are at
`/proc/<pid>/root/...`. As in Kubernetes, this works because both containers
run as uid 1000. `wget`/`netstat` against `127.0.0.1` reach the app's ports.

### `docker debug`

Docker Desktop's `docker debug <container>` (it also accepts an image) does the
same thing with its own toolbox, and needs no `-debug` tag. It ships with
Docker Desktop, not with the plain Docker Engine CLI.

### Copy files out without a shell

`docker cp` and `docker export` read the container's filesystem from the host,
so they need nothing inside the image:

```sh
docker cp <container>:/app/config.yaml .        # one file
docker cp <container>:/app - | tar -t           # list a directory
docker export <container> | tar -t              # the whole filesystem; works on a stopped container too
```

To inspect an image without running it, `docker create` a container from it,
export that, then remove it:

```sh
id=$(docker create ghcr.io/mathiasror/varde-python:3.13)
docker export "$id" | tar -t | less
docker rm "$id"
```

## Health checks

Health checks need no shell and no `-debug` tag. Use the exec form with a
binary the image ships, or an HTTP endpoint in the app. See
[Without a shell](../README.md#without-a-shell) in the README.
