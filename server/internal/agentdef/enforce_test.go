package agentdef

import (
	"slices"
	"testing"
)

func TestCapsOfInvariants(t *testing.T) {
	for _, h := range Harnesses {
		c := CapsOf(h)
		if !c.ToolGating || !c.Resume {
			t.Errorf("%s must support ToolGating and Resume, got %+v", h, c)
		}
		if c.ChatInlineImageGen && !c.WorkflowImageGen {
			t.Errorf("%s has ChatInlineImageGen without WorkflowImageGen", h)
		}
		if c.CollectsGeneratedImages && !c.WorkflowImageGen {
			t.Errorf("%s has CollectsGeneratedImages without WorkflowImageGen", h)
		}
		if c.ChatInlineImageGen && c.CollectsGeneratedImages {
			t.Errorf("%s cannot have both ChatInlineImageGen and CollectsGeneratedImages", h)
		}
		if CanMakeImages(h) != c.WorkflowImageGen {
			t.Errorf("CanMakeImages(%s) = %v, want WorkflowImageGen=%v", h, CanMakeImages(h), c.WorkflowImageGen)
		}
		if slices.Contains(ImageHarnesses, h) != c.WorkflowImageGen {
			t.Errorf("ImageHarnesses contains %s != WorkflowImageGen (%v)", h, c.WorkflowImageGen)
		}
	}
	if unknown := CapsOf("nonexistent"); unknown != (Caps{}) {
		t.Errorf("CapsOf(nonexistent) = %+v, want zero Caps", unknown)
	}
}
