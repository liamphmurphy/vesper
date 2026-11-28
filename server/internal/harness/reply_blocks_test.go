package harness

import "testing"

func TestReplyScannerRecognizesRicherVisualizationBlocks(t *testing.T) {
	tags := []string{
		"gallery", "product",
		"diff", "compare", "timeline", "stats", "tree",
		"compare-images", "graph", "plot", "datatable",
		"code-group", "kv", "json-tree", "http", "tabs", "details", "map",
	}
	for _, tag := range tags {
		var s replyScanner
		evs := s.feed("Intro\n```" + tag + "\n{}\n```\n")
		if len(evs) != 1 || evs[0].Payload["state"] != "reply_block" || evs[0].Payload["kind"] != tag {
			t.Errorf("tag %q: expected single reply_block event, got %+v", tag, evs)
		}
	}
}
