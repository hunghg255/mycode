package vfs

import (
	"os/exec"
	"syscall"
)

// createNoWindow keeps a console program from opening a console window of
// its own: the app is a GUI program, which has none for it to share.
const createNoWindow = 0x08000000

// HideWindow has cmd run without a console window flashing up.
func HideWindow(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
	cmd.SysProcAttr.CreationFlags |= createNoWindow
}
