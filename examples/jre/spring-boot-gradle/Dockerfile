# syntax=docker/dockerfile:1
#
# varde example: a Spring Boot (Gradle) app on the varde-jre base image.
# -----------------------------------------------------------------------------
# WHY varde-jre here?
#   JVM bytecode needs a Java runtime, not a bare libc. varde-jre ships a
#   headless Temurin JRE relocated under /runtime, and fixes the launch command:
#       ENTRYPOINT ["/runtime/bin/java"]
#       CMD        ["-jar", "/app/app.jar"]
#   So the whole contract is: drop ONE self-contained executable jar at
#   /app/app.jar, and the image runs `java -jar /app/app.jar` as non-root.
#
#   THE FAT-JAR CONTRACT
#   Spring Boot's `bootJar` produces exactly that: a "fat"/uber jar that embeds
#   your compiled classes, every dependency, AND a launcher that runs them. That
#   is why we do NOT use Gradle's `application` plugin start scripts — varde has
#   NO shell, so a generated `bin/app` launch script could never execute. The
#   self-contained fat jar is the entire point of the JRE base.
#
# The varde runtime contract (all varde base images):
#   - non-root user 1000:1000
#   - WORKDIR /app
#   - no shell, no package manager, no build tools in the runtime image
#   - varde-jre specifically: ENTRYPOINT ["/runtime/bin/java"] and
#     CMD ["-jar", "/app/app.jar"]  -> we place the jar at exactly /app/app.jar
#
# TAG SWITCHING (musl vs glibc)
#   The default base tag `:21` is the musl (Alpine Temurin) JRE. JVM bytecode is
#   libc-agnostic, so an ordinary bootJar runs on it just fine. If you pull in a
#   native library that needs glibc, opt into the glibc build by switching the
#   base image:
#       docker build --build-arg BASE_IMAGE=ghcr.io/mathiasror/varde-jre:21-glibc .
# -----------------------------------------------------------------------------

# MANDATORY: the very first instruction pins a real, public default base tag.
# An e2e harness overrides this with a locally-built image via
# `--build-arg BASE_IMAGE=...`, but the default must be a working public tag.
ARG BASE_IMAGE=ghcr.io/mathiasror/varde-jre:21

# --- Builder stage -----------------------------------------------------------
# A normal upstream toolchain image; none of this leaks into the runtime image.
#
# gradle:8.14-jdk21 -> Gradle 8.14.x on a JDK 21 toolchain. Spring Boot 4.1
# requires Gradle 8.14+ (or 9.x) and Java 17+, and JDK 21 matches both our
# Java 21 target and the varde-jre:21 runtime.
#
# WHY NO GRADLE WRAPPER (gradlew / gradle-wrapper.jar)?
#   This builder image already has `gradle` on PATH, so the wrapper would be
#   redundant here. Omitting it also keeps a committed binary jar out of the
#   source tree — these examples aim to be clean and fully auditable.
FROM gradle:8.14-jdk21 AS build
WORKDIR /home/gradle/src

# Copy the whole project as the image's non-root `gradle` user, then build.
# (A trivial single-module project, so we copy everything at once; larger
# projects often split settings/build files out first to cache dependency
# resolution independently of source changes.)
COPY --chown=gradle:gradle . .

# `bootJar` (not `build`) so we produce ONLY the executable fat jar and skip
# tests, the plain jar, and distribution wiring. `--no-daemon` keeps the build
# one-shot — no lingering Gradle daemon in an ephemeral container.
# build.gradle pins the artifact name via `bootJar { archiveFileName = 'app.jar' }`.
RUN gradle bootJar --no-daemon

# --- Runtime stage -----------------------------------------------------------
# MANDATORY: the final runtime stage is FROM ${BASE_IMAGE}.
FROM ${BASE_IMAGE}

# The base already sets WORKDIR /app, USER 1000:1000, ENTRYPOINT java, and
# CMD ["-jar", "/app/app.jar"]. We only need to place the fat jar at /app/app.jar.
#
# We copy the LITERAL filename (app.jar), not a `*.jar` glob: a full `gradle
# build` can emit both the bootJar and a plain `-plain.jar`, and a glob matching
# two jars would fail the COPY. Pinning archiveFileName in build.gradle and
# copying the exact name makes this unambiguous and future-proof.
COPY --from=build /home/gradle/src/build/libs/app.jar /app/app.jar

# OPTIONAL: passing JVM flags.
#   ENTRYPOINT is fixed to `java`; CMD supplies its arguments. To add JVM flags,
#   override CMD (flags MUST come before `-jar`), either at run time:
#       docker run <image> -XX:MaxRAMPercentage=75.0 -jar /app/app.jar
#   or by baking them in — uncomment the line below:
#   (Prefer -XX:MaxRAMPercentage over a fixed -Xmx so the heap tracks the
#   container's cgroup memory limit.)
# CMD ["-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]
