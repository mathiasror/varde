# Example: package your Node.js app on top of the varde base image.
#
# The base is npm-less and has NO shell — it runs `node /app/main.js` directly as
# an unprivileged user. There is no `npm start`, so use a direct entry file (or
# override CMD). Install dependencies in a builder that *does* have npm, then copy
# node_modules into the distroless runtime.
#
# Module compatibility:
#   - Pure-JS modules:        work out of the box.
#   - Prebuilt-binary modules work out of the box.
#   - Native addons (.node):  work too — the base ships an FHS glibc + libstdc++,
#                             so addons compiled against system libs load fine.
#   - ESM / TypeScript:       ship compiled/bundled JS (e.g. tsc, esbuild), or
#                             pass the needed flags via CMD (see below).
#
# Pin to a digest in production: varde-node:24@sha256:...

# Stage 1: install production deps with a full Node (has npm).
FROM node:24-slim AS deps
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Stage 2: the distroless runtime — node only, non-root, no shell, no npm.
FROM ghcr.io/mathiasror/varde-node:24

# Inherited from the base — no need to repeat:
#   USER 1000:1000
#   WORKDIR /app
#   ENTRYPOINT ["/runtime/bin/node"]
#   CMD ["/app/main.js"]

COPY --from=deps /build/node_modules /app/node_modules
COPY src/ /app/

# --- Optional: override CMD (no shell, so no npm scripts) -----------------------
# CMD ["/app/server.js"]                       # point at a different entry file
# CMD ["--enable-source-maps", "/app/main.js"] # pass node flags for ESM/TS output
#
# --- Optional: pick a different version by changing the tag --------------------
# FROM ghcr.io/mathiasror/varde-node:20        # or :22
#
# --- Optional: force one architecture via an explicit per-arch tag ------------
# FROM ghcr.io/mathiasror/varde-node:24-arm64  # or :24-amd64
