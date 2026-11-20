package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestUsageErrorsExitBeforeReachingTheVM(t *testing.T) {
	for _, tt := range []struct {
		name string
		args []string
		code int
		want string
	}{
		{"no command", nil, 2, "usage: mac"},
		{"help", []string{"-h"}, 0, "usage: mac"},
		{"bad env", []string{"-e", "NOEQUALS", "swift", "build"}, 2, "-e wants KEY=VALUE"},
		{"agent log with a command", []string{"--agent-log", "swift", "build"}, 2, "--agent-log takes no command"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var out, errOut bytes.Buffer
			if code := run(tt.args, &out, &errOut); code != tt.code {
				t.Fatalf("exit %d, want %d (stderr %q)", code, tt.code, errOut.String())
			}
			if !strings.Contains(errOut.String(), tt.want) {
				t.Fatalf("stderr %q lacks %q", errOut.String(), tt.want)
			}
		})
	}
}
