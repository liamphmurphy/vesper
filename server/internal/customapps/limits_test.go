package customapps

import (
	"errors"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func TestNormalizeFilesAllowsLargeAppsUpToCap(t *testing.T) {
	// A real app (Watch Feed) outgrew the old 256 KB total; 1 MB of source must fit.
	big := strings.Repeat("// padding\n", (1<<20)/11)
	if _, err := NormalizeFiles(map[string]string{"app.tsx": big}); err != nil {
		t.Fatalf("1 MB app rejected: %v", err)
	}

	half := strings.Repeat("x", MaxTotalFileBytes/2)
	_, err := NormalizeFiles(map[string]string{"a.ts": half, "b.ts": half, "c.ts": "y"})
	if !errors.As(err, new(*apperr.ValidationError)) || !strings.Contains(err.Error(), "10 MB") {
		t.Fatalf("over-cap app error = %v, want a validation error naming the 10 MB cap", err)
	}
}
