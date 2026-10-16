//go:build windows

package main

import "testing"

func TestMsysPath(t *testing.T) {
	for in, want := range map[string]string{
		`C:\Users\DELL\AppData\Local\Programs\MyCode\MyCode.exe`: "/c/Users/DELL/AppData/Local/Programs/MyCode/MyCode.exe",
		`D:\a b\x.exe`: "/d/a b/x.exe",
	} {
		if got := msysPath(in); got != want {
			t.Errorf("msysPath(%q) = %q, want %q", in, got, want)
		}
	}
	if !samePath(`C:\A\bin\`, `c:\a\BIN`) || samePath(`C:\a`, `C:\b`) {
		t.Error("samePath")
	}
}
