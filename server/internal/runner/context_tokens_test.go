package runner

import (
	"testing"
	"time"
)

func TestContextWriterThrottlesWrites(t *testing.T) {
	var writes []int64
	cw := &contextWriter{write: func(n int64) { writes = append(writes, n) }}
	cw.observe(100)
	cw.observe(200) // within 15s of the first write: held for the turn-end write
	if len(writes) != 1 || writes[0] != 100 {
		t.Fatalf("writes %v, want [100]", writes)
	}
	cw.written = time.Now().Add(-contextWriteEvery)
	cw.observe(300)
	if len(writes) != 2 || writes[1] != 300 {
		t.Fatalf("writes %v, want [100 300]", writes)
	}
}
