// Package main is a minimal Go program used as a varde base-image example.
//
// It exists purely to demonstrate the varde runtime contract: a single
// static binary copied to /app/app, run as the non-root 1000:1000 user,
// with no shell and no build tools present in the final image.
package main

import "fmt"

func main() {
	// The e2e smoke test greps stdout for the exact string "varde ok".
	fmt.Println("varde ok")
}
