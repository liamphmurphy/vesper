package runner

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The setup snippet runs in the checkout and reports the files inference
// reads, which the runner strips from the log.
func TestTestFilesScriptReportsCandidates(t *testing.T) {
	dir := t.TempDir()
	write := func(p, body string) {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, p), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".github/workflows/ci.yml", "jobs: {}\n")
	write("docker-compose.yml", "services: {}\n")
	write("README.md", "not read")
	cmd := exec.Command("sh", "-c", "echo before; "+testFilesScript()+"echo after")
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	log, files := takeTestFiles(string(out))
	if strings.Contains(log, testFilesPrefix) || !strings.Contains(log, "before") || !strings.Contains(log, "after") {
		t.Fatalf("log = %q", log)
	}
	if len(files) != 2 || string(files[".github/workflows/ci.yml"]) != "jobs: {}\n" || files["docker-compose.yml"] == nil {
		t.Fatalf("files = %v", files)
	}
}
