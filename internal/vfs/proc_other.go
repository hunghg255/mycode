//go:build !windows

package vfs

import "os/exec"

// HideWindow has cmd run without a console window flashing up, which
// only Windows opens.
func HideWindow(cmd *exec.Cmd) {}
