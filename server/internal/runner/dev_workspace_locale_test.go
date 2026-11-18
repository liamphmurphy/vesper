package runner

import (
	"testing"
)

// tmux draws every non-ASCII character as "_" when the client's locale isn't
// UTF-8, which mangled Claude Code's logo and the shell prompt in the Dev
// workspace terminal. These pin the terminal to a UTF-8 locale on both
// backends.

func TestMicroVMDevShellEnvUsesUTF8Locale(t *testing.T) {
	env := (&MicroVM{}).devShellEnv()
	if env["LANG"] != "C.UTF-8" {
		t.Fatalf("devShellEnv LANG = %q, want C.UTF-8", env["LANG"])
	}
}
