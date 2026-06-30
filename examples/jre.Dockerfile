# Example: package your JVM app on top of the varde base image.
#
# The base runs `java -jar /app/app.jar` as an unprivileged user. It has NO shell,
# so your app must be a self-contained executable JAR:
#   - Spring Boot:   ./gradlew bootJar      (or mvn package with spring-boot plugin)
#   - Gradle Shadow: ./gradlew shadowJar
#   - Plain Kotlin:  produce an uber/fat jar
#
# Pin to a digest in production: varde-jre:21@sha256:...

FROM ghcr.io/mathiasror/varde-jre:21

# Inherited from the base — no need to repeat:
#   USER 1000:1000
#   WORKDIR /app
#   ENTRYPOINT ["/runtime/bin/java"]
#   CMD ["-jar", "/app/app.jar"]

COPY build/libs/app-all.jar /app/app.jar

# --- Optional: set JVM flags by overriding CMD ---------------------------------
# CMD ["-XX:MaxRAMPercentage=75", "-XX:+ExitOnOutOfMemoryError", "-jar", "/app/app.jar"]
#
# --- Optional: pick a different LTS by changing the tag ------------------------
# FROM ghcr.io/mathiasror/varde-jre:17        # or :25
#
# --- Optional: force one architecture via an explicit per-arch tag ------------
# FROM ghcr.io/mathiasror/varde-jre:21-arm64  # or :21-amd64
