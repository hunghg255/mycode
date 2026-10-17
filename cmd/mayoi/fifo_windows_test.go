package main

import "testing"

// makeFifo makes a named pipe at path, and reports whether it did, as
// Windows has none.
func makeFifo(t *testing.T, path string) bool { return false }
