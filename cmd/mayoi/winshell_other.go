//go:build !windows

package main

import "errors"

// shellSupported reports whether the app sets up its shell integration,
// which is Windows's; macOS installs its command with the cli package.
const shellSupported = false

func shellBinDir() string { return "" }

func installShell(exe string) (string, error) { return "", errors.ErrUnsupported }

func uninstallShell() error { return errors.ErrUnsupported }
