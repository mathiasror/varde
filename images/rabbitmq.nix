# Minimal distroless RabbitMQ message broker — no shell, not even to boot.
#
# RabbitMQ's stock launcher (`sbin/rabbitmq-server`) is a POSIX shell script,
# but since 3.8 it is only env plumbing: every RABBITMQ_* variable is (re)read
# by the Erlang side (rabbit_env.erl), and the script's real job boils down to
# `exec erl -noinput -s rabbit boot -boot start_sasl <VM flags>`. varde
# replicates exactly that exec line with two ~20-line C shims compiled at image
# build time, so the image ships zero shells and zero shell scripts:
#
#   /runtime/bin/varde-rabbitmq-server  (the ENTRYPOINT) forks `epmd -daemon`,
#     waits for the fork, then execs erlexec (an ELF) with the same VM flags
#     the upstream script computes. epmd must be pre-started here because the
#     only in-tree way RabbitMQ can start it needs a shell: erlexec auto-starts
#     epmd only when -name/-sname is on its own argv, which the broker's exec
#     line never passes (rabbit_prelaunch_dist names the node later), so
#     RabbitMQ would fall back to rabbit_nodes_common:start_epmd/0, which
#     spawns `$BINDIR/erl -sname epmd-starter-N ...`; THAT erlexec then runs
#     system("epmd -daemon"), i.e. /bin/sh, absent here (the failure is
#     swallowed by port_shutdown_loop). With epmd already listening,
#     ensure_epmd/0's net_adm:names/0 succeeds and the fallback is never
#     reached.
#   /runtime/bin/erl and /runtime/erts-*/bin/erl  replace OTP's `erl` shell
#     script: set ROOTDIR/BINDIR/EMU/PROGNAME and exec erlexec. This exists
#     for `escript` (an ELF that execs `<its own dir>/erl`) and so that the
#     epmd-starter fallback above can at least exec cleanly — it still cannot
#     start epmd without a shell.
#
# The CLI tools survive distroless-ification because they are Erlang escripts,
# not scripts: /rabbitmq/escript/rabbitmqctl is one self-contained escript
# archive (upstream ships seven byte-identical CLI names that dispatch on
# argv[0]; this image links six of them as symlinks and deliberately omits
# vmware-rabbitmq, the commercial/Tanzu plugins CLI) whose shebang we point at
# the in-image /runtime/bin/escript ELF. They are on PATH via /runtime/bin, so:
#
#   docker exec <ctr> rabbitmq-diagnostics ping
#   docker exec <ctr> rabbitmqctl status
#
# work with no shell involved anywhere (kernel shebang exec -> escript ELF ->
# erl trampoline ELF -> erlexec -> beam.smp).
#
# Deviations from the upstream package, all in service of "no shell":
#   * rabbit_disk_monitor hardcodes open_port({spawn_executable, "/bin/sh"}) —
#     with no /bin/sh that enoent would crash the boot step. We patch it (one
#     line) to consult os:find_executable("sh") and degrade exactly like its
#     existing error paths: FREE-DISK-SPACE MONITORING IS OFF in this image
#     (it logs "Free disk space monitor failed to start!" and reports NaN).
#     Watch disk usage from the container platform instead.
#   * $RABBITMQ_CONF_ENV_FILE (rabbitmq-env.conf) is not supported: rabbit_env
#     sources it with `sh`, finds none, and skips it (a documented graceful
#     path upstream). Configure via RABBITMQ_* env vars and rabbitmq.conf.
#   * Built against beamMinimal27Packages (no wx/GTK, no systemd hooks) and the
#     runtime tree is pruned to the OTP apps RabbitMQ can load: no dev tooling
#     (dialyzer/debugger/observer/common_test), no wx, no ssh/snmp/megaco/
#     diameter. The systemd/getconf/procps/socat inputs only feed the PATH line
#     of the deleted sbin scripts, so they are stubbed out — on musl that also
#     keeps systemd (clang/llvm-scale build, see images/redis.nix) out of the
#     build closure.
#
# Contract: run as-is (AMQP 0-9-1 on :5672, guest/guest from localhost only).
#   - Config file:      COPY rabbitmq.conf /app/rabbitmq.conf  (see examples/)
#   - Plugins:          COPY enabled_plugins /app/enabled_plugins
#                       (e.g. `[rabbitmq_management].` -> UI on :15672)
#   - Data:             /app/mnesia (ships in the image, writable, uid 1000,
#                       so a named volume mounted there inherits the
#                       ownership: `-v rabbit-data:/app/mnesia`). NOTE: the
#                       node name defaults to rabbit@<container hostname> and
#                       the data dir embeds it — for persistent data run with
#                       a stable `--hostname` (or set RABBITMQ_NODENAME).
#   - Erlang cookie:    auto-created 0400 at /app/.erlang.cookie (HOME=/app).
#   - Ports:            5672 AMQP, 15672 management (if enabled), 4369 epmd +
#                       25672 dist (cluster-internal; don't publish them).
#   - Logs:             stdout (RABBITMQ_LOGS=-).
#   - Extra VM flags:   ERL_FLAGS env var (replaces the wrapper-script-only
#                       RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS mechanism).
#
# Built for both libcs: the bare tag (:latest) is musl; opt into glibc with
# :latest-glibc.
{
  pkgs,
  vardeLib,
  lib,
}:
let
  # `p` is the libc's package set (pkgs for glibc, pkgs.pkgsMusl for musl).
  rabbitmqSpec =
    p:
    let
      # wx-less, systemd-less BEAM (hydra-cached on glibc). The same erlang
      # builds RabbitMQ and ships (pruned) in the image, so beams always match.
      beamPkgs = p.beamMinimal27Packages;
      erlang = beamPkgs.erlang;

      rabbitmq =
        (p.rabbitmq-server.override (
          {
            beam27Packages = beamPkgs;
            # These only appear in the PATH line sed'ed into the sbin scripts,
            # which this image deletes. Stubbing them keeps systemd out of the
            # (musl) build closure entirely — the redis clang/llvm lesson.
            systemd = p.emptyDirectory;
            getconf = p.emptyDirectory;
            procps = p.emptyDirectory;
            socat = p.emptyDirectory;
          }
          # Only used for build-time LANG; on musl it would pointlessly build
          # glibc. Keep it on glibc where it is cached and known-good.
          // lib.optionalAttrs p.stdenv.hostPlatform.isMusl {
            glibcLocales = p.emptyDirectory;
          }
        )).overrideAttrs
          (prev: {
            # No /bin/sh in this image: make the disk monitor's port program
            # optional instead of an enoent crash at boot. With `sh` missing it
            # falls into the module's existing retry-then-disable error path.
            postPatch = (prev.postPatch or "") + ''
              substituteInPlace deps/rabbit/src/rabbit_disk_monitor.erl \
                --replace-fail \
                'erlang:open_port({spawn_executable, "/bin/sh"}, Opts).' \
                'case os:find_executable("sh") of false -> not_used; Sh -> erlang:open_port({spawn_executable, Sh}, Opts) end.'
            '';
          });

      # /runtime — pruned Erlang/OTP root (ROOTDIR): ELF binaries and beams
      # only, every shell script deleted, plus the two C shims. Guarded so the
      # shells/tools referenced by the deleted scripts can never sneak back
      # into the image closure.
      runtime =
        (p.runCommandCC "varde-rabbitmq-erlang-${erlang.version}" {
          disallowedRequisites = [
            p.bash
            p.gawk
            p.gnused
            erlang
          ];
        })
          ''
            mkdir -p "$out/runtime"
            cp -a ${erlang}/lib/erlang/. "$out/runtime/"
            chmod -R u+w "$out/runtime"
            cd "$out/runtime"

            ertsdir=$(basename erts-*)
            bindir="/runtime/$ertsdir/bin"

            # Top-level chaff (docs, install helpers — and their bash refs).
            rm -rf man misc usr Install

            # bin/: keep the escript/epmd ELFs and the boot files the VM
            # resolves against ROOTDIR/bin (-boot start_sasl, the epmd-starter's
            # -boot no_dot_erlang). Everything else is a script or dev tool.
            mkdir keep
            for f in escript epmd no_dot_erlang.boot start.boot start.script \
                     start_clean.boot start_sasl.boot; do
              mv "bin/$f" keep/
            done
            rm -rf bin && mv keep bin

            # erts bin/: the emulator and its helper ELFs only. `erl` (a shell
            # script) is replaced by the trampoline below.
            mkdir keep
            for f in beam.smp erlexec epmd erl_child_setup inet_gethost; do
              mv "$ertsdir/bin/$f" keep/
            done
            rm -rf "$ertsdir/bin" && mv keep "$ertsdir/bin"

            # OTP apps RabbitMQ cannot load anyway: GUI/dev/test tooling and
            # unused protocol stacks. (No plugin references observer_backend —
            # rabbitmq-diagnostics' top/observer commands use recon/observer_cli
            # from /rabbitmq/plugins.) NOT `tools`: rabbit_common and horus
            # both list it in their .app `applications`, so the application
            # controller refuses to boot without it ({error,{tools,{"no such
            # file or directory","tools.app"}}}) — it is pure beams, no ports.
            for app in wx debugger observer et megaco diameter snmp ssh ftp \
                       tftp common_test dialyzer edoc erl_docgen jinterface \
                       odbc reltool erl_interface; do
              rm -rf lib/"$app"-*
            done
            # Runtime needs beams, not sources/examples — and the stray *.sh
            # helpers (inets CGI, …) are what would drag bash back in.
            rm -rf lib/*/src lib/*/examples lib/*/doc lib/*/emacs
            find . -name '*.sh' -delete

            # C shims. Both get ROOTDIR/BINDIR/EMU/PROGNAME baked in, so any
            # exec chain lands on erlexec with a consistent environment.
            cat > erl.c <<'EOF'
            #include <stdlib.h>
            #include <unistd.h>
            /* Drop-in replacement for OTP's `erl` shell script. */
            int main(int argc, char **argv) {
                (void)argc;
                setenv("ROOTDIR", VARDE_ROOT, 1);
                setenv("BINDIR", VARDE_BINDIR, 1);
                setenv("EMU", "beam", 1);
                setenv("PROGNAME", "erl", 1);
                execv(VARDE_BINDIR "/erlexec", argv);
                return 127;
            }
            EOF
            cat > boot.c <<'EOF'
            #include <stdlib.h>
            #include <sys/wait.h>
            #include <unistd.h>
            /* ENTRYPOINT: start epmd, then become the RabbitMQ VM.
             * epmd -daemon double-forks, so the waitpid returns immediately;
             * the daemon is reparented to this process (PID 1), which then
             * execs into beam. rabbit's ensure_epmd() finds it running.
             * A failed pre-start is reported on stderr, not fatal: an external
             * epmd on :4369 (shared network namespace) still lets the broker
             * boot. The status only covers fork/exec and epmd's own argument
             * parsing — `epmd -daemon` exit(0)s in the parent before the
             * detached daemon binds, so a bind/port-in-use failure never comes
             * back here and is diagnosed by RabbitMQ itself (net_kernel). */
            int main(int argc, char **argv) {
                (void)argc;
                pid_t pid = fork();
                if (pid == 0) {
                    char *ep[] = { "epmd", "-daemon", (char *)0 };
                    execv(VARDE_BINDIR "/epmd", ep);
                    _exit(127);
                }
                int status = 0;
                if (pid < 0 || waitpid(pid, &status, 0) < 0
                    || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
                    static const char msg[] =
                        "varde-rabbitmq-server: failed to start epmd -daemon; "
                        "the broker will fail in rabbit_prelaunch_dist unless "
                        "an epmd is already listening on :4369\n";
                    ssize_t n = write(2, msg, sizeof msg - 1);
                    (void)n;
                }
                setenv("ROOTDIR", VARDE_ROOT, 1);
                setenv("BINDIR", VARDE_BINDIR, 1);
                setenv("EMU", "beam", 1);
                setenv("PROGNAME", "erl", 1);
                argv[0] = "erl";
                execv(VARDE_BINDIR "/erlexec", argv);
                return 127;
            }
            EOF
            defs="-DVARDE_ROOT=\"/runtime\" -DVARDE_BINDIR=\"$bindir\""
            $CC -O2 -Wall $defs -o bin/erl erl.c
            cp bin/erl "$ertsdir/bin/erl"
            $CC -O2 -Wall $defs -o bin/varde-rabbitmq-server boot.c
            rm erl.c boot.c

            # CLI on PATH (in-image absolute targets; see the dist derivation).
            for t in rabbitmqctl rabbitmq-diagnostics rabbitmq-plugins \
                     rabbitmq-queues rabbitmq-streams rabbitmq-upgrade; do
              ln -s /rabbitmq/escript/"$t" bin/"$t"
            done
          '';

      # /rabbitmq — plugins (the broker code; ERL_LIBS points here) and the CLI
      # escript. Self-contained by construction: allowedReferences makes the
      # build fail if any store path (e.g. a build-erlang reference) leaks in.
      dist =
        (p.runCommand "varde-rabbitmq-dist-${rabbitmq.version}" {
          nativeBuildInputs = [ p.buildPackages.nukeReferences ];
          allowedReferences = [ "out" ];
        })
          ''
            mkdir -p "$out/rabbitmq/escript"
            cp -a ${rabbitmq}/plugins "$out/rabbitmq/plugins"
            chmod -R u+w "$out/rabbitmq"

            # redbug's generated lexer/parser beams embed the build erlang's
            # store path in their debug line info; zero it (length-preserving).
            nuke-refs "$out"/rabbitmq/plugins/redbug-*/ebin/*.beam

            # One escript archive; upstream's seven CLI names are byte-identical
            # and dispatch on argv[0]. Point the shebang at the in-image escript
            # ELF (also kills the store reference to the build erlang).
            # vmware-rabbitmq is intentionally not linked (here or in runtime).
            printf '#!/runtime/bin/escript\n' > "$out/rabbitmq/escript/rabbitmqctl"
            tail -n +2 ${rabbitmq}/escript/rabbitmqctl >> "$out/rabbitmq/escript/rabbitmqctl"
            chmod 555 "$out/rabbitmq/escript/rabbitmqctl"
            for t in rabbitmq-diagnostics rabbitmq-plugins rabbitmq-queues \
                     rabbitmq-streams rabbitmq-upgrade; do
              ln -s rabbitmqctl "$out/rabbitmq/escript/$t"
            done
          '';
    in
    {
      # /app/mnesia ships as a directory (uid 1000 via lib's chown of ./app) so
      # that `-v rabbit-data:/app/mnesia` works: Docker only copies the
      # mountpoint's ownership into a fresh named volume when the path already
      # exists in the image. Without it the volume would be root-owned and the
      # uid-1000 broker could not create /app/mnesia/rabbit@<host> at boot.
      contents = [
        runtime
        dist
        (p.runCommand "varde-rabbitmq-dirs" { } ''
          mkdir -p "$out/app/mnesia"
        '')
      ];
      # The exact erl line `sbin/rabbitmq-server` execs in its exec branch —
      # the one the official container takes (RUNNING_UNDER_SYSTEMD=true) —
      # with its defaults for SERVER_ERL_ARGS and the allocator flags, via the
      # epmd-starting shim. Deliberately NO `+B i`: upstream only adds that in
      # the non-exec wrapper branch, where the wrapper shell stays alive and
      # its INT trap turns ^C into `rabbitmqctl stop`; with no wrapper it would
      # just make beam ignore SIGINT and a foreground `docker run` impossible
      # to ^C. So, as in the official image, ^C ends the VM at once and
      # `docker stop` (SIGTERM) is the graceful path via rabbit's signal
      # handler.
      entrypoint = [
        "/runtime/bin/varde-rabbitmq-server"
        "-noinput"
        "-s"
        "rabbit"
        "boot"
        "-boot"
        "start_sasl"
        "+W"
        "w"
        "+MBas"
        "ageffcbf"
        "+MHas"
        "ageffcbf"
        "+MBlmbcs"
        "512"
        "+MHlmbcs"
        "512"
        "+MMmcs"
        "30"
        "+pc"
        "unicode"
        "+P"
        "1048576"
        "+t"
        "5000000"
        "+stbt"
        "db"
        "+zdbbl"
        "128000"
        "+sbwt"
        "none"
        "+sbwtdcpu"
        "none"
        "+sbwtdio"
        "none"
        "-syslog"
        "logger"
        "[]"
        "-syslog"
        "syslog_error_logger"
        "false"
        "-kernel"
        "prevent_overlapping_partitions"
        "false"
      ];
      # rabbit_env defaults everything under /var+/etc (read-only here), so
      # point all mutable state at /app (writable, uid 1000) — the same values
      # rabbitmq-env(.conf) would otherwise plumb. HOME=/app also puts the
      # Erlang cookie somewhere writable. ERL_MAX_* mirror rabbitmq-env.
      env = [
        "PATH=/runtime/bin"
        "HOME=/app"
        "ERL_LIBS=/rabbitmq/plugins"
        "ERL_MAX_ETS_TABLES=50000"
        "ERL_MAX_PORTS=65536"
        "RABBITMQ_HOME=/rabbitmq"
        "RABBITMQ_PLUGINS_DIR=/rabbitmq/plugins"
        "RABBITMQ_MNESIA_BASE=/app/mnesia"
        "RABBITMQ_LOG_BASE=/app/log"
        "RABBITMQ_LOGS=-"
        "RABBITMQ_ENABLED_PLUGINS_FILE=/app/enabled_plugins"
        "RABBITMQ_CONFIG_FILE=/app/rabbitmq.conf"
        "RABBITMQ_ADVANCED_CONFIG_FILE=/app/advanced.config"
      ];
      # no fhs: every ELF (beam.smp, erlexec, the shims) finds its libs via
      # RPATH.

      # SBOM: runtime (disallowedRequisites erlang, above) and dist
      # (allowedReferences ["out"]) deliberately sever their references to the
      # source packages, so neither the broker nor OTP would be named
      # components in their own SBOM. NVD identities: RabbitMQ CVEs are filed
      # under `broadcom:rabbitmq_server` (every 3.9+ advisory, including the
      # 2026 ones); the older `vmware:rabbitmq` / `pivotal_software:rabbitmq`
      # CPEs only carry pre-3.9 CVEs and match nothing for the shipped
      # version. OTP's sparse NVD coverage sits under `erlang:erlang\/otp`.
      # Scan metadata only; never enters image contents.
      sbomExtraComponents = [
        (vardeLib.sbomComponent {
          vendor = "broadcom";
          product = "rabbitmq_server";
          name = "rabbitmq";
          version = rabbitmq.version;
        })
        (vardeLib.sbomComponent {
          vendor = "erlang";
          product = "erlang\\/otp";
          name = "erlang-otp";
          version = erlang.version;
        })
      ];
    };
in
{
  description = "Minimal distroless RabbitMQ message broker";
  latest = "latest";
  variants = vardeLib.mkVariants pkgs {
    versions."latest" = {
      spec = rabbitmqSpec;
    };
  };
}
