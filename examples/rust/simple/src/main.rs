// Minimal Rust program used as a varde base-image example.
//
// Its only job is to demonstrate the varde runtime contract: a single binary
// copied to /app/app, run as the non-root 1000:1000 user, with no shell and no
// build tools present in the final image.
fn main() {
    // The e2e smoke test greps stdout for the exact string "varde ok".
    println!("varde ok");
}
