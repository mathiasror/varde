// A minimal but production-shaped Express server for the varde-node example.
//
// Design notes (why it looks like this):
//   - Binds process.env.PORT || 8080. Express/Node bind 0.0.0.0 by default when
//     no host is given, so a container `-p 8080:8080` publish works out of the
//     box — do NOT pass "127.0.0.1" here or the published port would be dead.
//   - A dedicated /healthz endpoint returns 200 for liveness/readiness probes.
//   - A SIGTERM handler drains in-flight requests before exit. Containers are
//     stopped with SIGTERM; because varde-node runs `node` as PID 1 with no
//     shell wrapper, this signal reaches the process directly — handle it so
//     orchestrators get a clean, fast shutdown instead of a 10s SIGKILL wait.
"use strict";

const express = require("express");

const app = express();
const port = process.env.PORT || 8080;

// Root: plain-text "varde ok" (the e2e smoke test asserts the body contains it).
app.get("/", (req, res) => res.type("text/plain").send("varde ok"));

// Health check: cheap 200 for liveness/readiness probes.
app.get("/healthz", (req, res) => res.sendStatus(200));

const server = app.listen(port, () => {
  console.log(`varde-example-express listening on ${port}`);
});

// Graceful shutdown: stop accepting new connections, let in-flight requests
// finish, then exit. A short safety timer forces exit if something hangs.
function shutdown() {
  console.log("SIGTERM received, shutting down");
  server.close(() => {
    console.log("server closed");
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on("SIGTERM", shutdown);
