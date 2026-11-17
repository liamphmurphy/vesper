//go:build linux

package main

import "testing"

func TestHasPersistentNix(t *testing.T) {
	cases := []struct {
		name string
		in   []volumeInfo
		want bool
	}{
		{"none", nil, false},
		{"erofs only", []volumeInfo{{"erofs", "cache-nix"}}, false},
		{"wrong fs", []volumeInfo{{"erofs", nixDiskLabel}}, false},
		{"present", []volumeInfo{{"ext4", "vesper-ws"}, {"ext4", nixDiskLabel}, {"erofs", "cache-nix"}}, true},
	}
	for _, c := range cases {
		if got := hasPersistentNix(c.in); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}
