// Minimal Node.js program used as a varde-node base-image example.
//
// It exists purely to demonstrate the varde-node runtime contract: a single
// source file copied to /app/main.js, run as the non-root 1000:1000 user by a
// runtime that has NO shell and NO npm — the base's ENTRYPOINT is the node
// binary itself and its CMD points straight at this file.
//
// The e2e smoke test greps stdout for the exact string "varde ok".
console.log("varde ok");
