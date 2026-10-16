// Package vfs is the file system of the editor: the files of this
// machine, by the os package. Each function does what the os package's of
// its name does.
package vfs

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
)

// ErrTooLarge is the error of a file read with a limit that it is above.
var ErrTooLarge = errors.New("file too large")

// IsRemote reports whether p is the path of a file of another machine,
// which is never.
func IsRemote(p string) bool { return false }

// Stat stats a file, following a link.
func Stat(p string) (fs.FileInfo, error) { return os.Stat(p) }

// Lstat stats a file, not following a link.
func Lstat(p string) (fs.FileInfo, error) { return os.Lstat(p) }

// StatMany stats files, following links: the map has those that are
// there, by path.
func StatMany(paths []string) (map[string]fs.FileInfo, error) {
	out := map[string]fs.FileInfo{}
	for _, p := range paths {
		if info, err := os.Stat(p); err == nil {
			out[p] = info
		}
	}
	return out, nil
}

// ReadFile reads a file.
func ReadFile(p string) ([]byte, error) { return ReadFileLimit(p, 0) }

// ReadFileLimit reads a file of at most limit bytes when limit is above
// 0, failing with ErrTooLarge for a larger one.
func ReadFileLimit(p string, limit int64) ([]byte, error) {
	if limit > 0 {
		info, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		if info.Size() > limit {
			return nil, ErrTooLarge
		}
	}
	return os.ReadFile(p)
}

// ReadFileInfo stats a file and reads it, as Stat and ReadFileLimit do,
// at once.
func ReadFileInfo(p string, limit int64) (fs.FileInfo, []byte, error) {
	info, err := os.Stat(p)
	if err != nil {
		return nil, nil, err
	}
	if info.IsDir() {
		return nil, nil, &fs.PathError{Op: "read", Path: p, Err: errors.New("is a directory")}
	}
	data, err := ReadFileLimit(p, limit)
	if err != nil {
		return nil, nil, err
	}
	return info, data, nil
}

// WriteFile writes data to a file, made with perm when it is new, and
// returns what stat says of it then. A file of this machine is written
// beside and renamed into place, so that a failure keeps the old one.
func WriteFile(p string, data []byte, perm fs.FileMode) (fs.FileInfo, error) {
	mode := perm
	if info, err := os.Stat(p); err == nil {
		mode = info.Mode().Perm()
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), "."+filepath.Base(p)+".mayoi-*")
	if err != nil {
		if err := os.WriteFile(p, data, mode); err != nil {
			return nil, err
		}
		return os.Stat(p)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return nil, err
	}
	os.Chmod(tmp.Name(), mode)
	if err := os.Rename(tmp.Name(), p); err != nil {
		os.Remove(tmp.Name())
		return nil, err
	}
	return os.Stat(p)
}

// Create makes an empty file, and the folders above it, unless a file is
// there.
func Create(p string) error {
	if _, err := os.Lstat(p); err == nil {
		return &fs.PathError{Op: "create", Path: p, Err: fs.ErrExist}
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, nil, 0o644)
}

// MkdirAll makes a folder and those above it.
func MkdirAll(p string) error {
	return os.MkdirAll(p, 0o755)
}

// Rename moves a file, unless another is at to.
func Rename(from, to string) error {
	if from != to {
		if _, err := os.Lstat(to); err == nil {
			return &fs.PathError{Op: "rename", Path: to, Err: fs.ErrExist}
		}
	}
	return os.Rename(from, to)
}

// RemoveAll deletes a file, or a folder and everything in it.
func RemoveAll(p string) error {
	return os.RemoveAll(p)
}

// Entry is a file of a folder: its name, and whether it is a folder or a
// link to one.
type Entry struct {
	Name string
	Dir  bool
}

// ReadDir lists a folder.
func ReadDir(dir string) ([]Entry, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := make([]Entry, 0, len(entries))
	for _, e := range entries {
		isDir := e.IsDir()
		if e.Type()&os.ModeSymlink != 0 {
			if info, err := os.Stat(filepath.Join(dir, e.Name())); err == nil && info.IsDir() {
				isDir = true
			}
		}
		out = append(out, Entry{Name: e.Name(), Dir: isDir})
	}
	return out, nil
}

// ReadDirs lists folders: each folder's entries, or why it could not be
// read.
func ReadDirs(dirs []string) (map[string][]Entry, map[string]error, error) {
	lists, errs := map[string][]Entry{}, map[string]error{}
	for _, d := range dirs {
		if es, err := ReadDir(d); err != nil {
			errs[d] = err
		} else {
			lists[d] = es
		}
	}
	return lists, errs, nil
}

// Look lists folders and stats files, as ReadDirs and StatMany do.
func Look(dirs, files []string) (map[string][]Entry, map[string]error, map[string]fs.FileInfo, error) {
	lists, errs, err := ReadDirs(dirs)
	if err != nil {
		return nil, nil, nil, err
	}
	infos, err := StatMany(files)
	return lists, errs, infos, err
}

// Command returns the command that runs a program in dir, with env added to its environment and stdin, nil for none, as
// its input. The caller sets its output.
func Command(dir string, env []string, stdin io.Reader, name string, args ...string) (*exec.Cmd, error) {
	cmd := exec.Command(name, args...)
	HideWindow(cmd)
	cmd.Dir = dir
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	if stdin != nil {
		cmd.Stdin = stdin
	}
	return cmd, nil
}

// Output runs a program as Command has it and returns what it wrote.
func Output(dir string, name string, args ...string) ([]byte, error) {
	cmd, err := Command(dir, nil, nil, name, args...)
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	err = cmd.Run()
	return out.Bytes(), err
}
