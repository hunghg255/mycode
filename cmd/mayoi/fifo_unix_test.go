//go:build !windows

package main

import (
	"syscall"
	"testing"
)

// makeFifo makes a named pipe at path, and reports whether it did, as
// Windows has none.
func makeFifo(t *testing.T, path string) bool {
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	return true
}
