package wiki

import "testing"

func TestDetectAssetContentTypeMediaFormats(t *testing.T) {
	cases := []struct {
		name     string
		filename string
		head     []byte
		want     string
	}{
		{
			name:     "heic ftyp",
			filename: "photo.HEIC",
			head:     []byte{0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c'},
			want:     "image/heic",
		},
		{
			name:     "heif ftyp",
			filename: "photo.heif",
			head:     []byte{0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'm', 'i', 'f', '1'},
			want:     "image/heif",
		},
		{
			name:     "quicktime mov",
			filename: "clip.mov",
			head:     []byte{0x00, 0x00, 0x00, 0x14, 'f', 't', 'y', 'p', 'q', 't', ' ', ' '},
			want:     "video/quicktime",
		},
		{
			name:     "m4a audio",
			filename: "voice.m4a",
			head:     []byte{0x00, 0x00, 0x00, 0x20, 'f', 't', 'y', 'p', 'M', '4', 'A', ' '},
			want:     "audio/mp4",
		},
		{
			name:     "mp4 video",
			filename: "demo.mp4",
			head:     []byte{0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm'},
			want:     "video/mp4",
		},
		{
			name:     "flac audio",
			filename: "track.flac",
			head:     []byte{'f', 'L', 'a', 'C', 0x00, 0x00, 0x00, 0x22},
			want:     "audio/flac",
		},
		{
			name:     "mp3 id3",
			filename: "song.mp3",
			head:     []byte{'I', 'D', '3', 0x03, 0x00, 0x00, 0x00, 0x00},
			want:     "audio/mpeg",
		},
		{
			name:     "webm ebml",
			filename: "clip.webm",
			head:     []byte{0x1a, 0x45, 0xdf, 0xa3, 0x01, 0x00, 0x00, 0x00},
			want:     "video/webm",
		},
		{
			name:     "mkv ebml",
			filename: "clip.mkv",
			head:     []byte{0x1a, 0x45, 0xdf, 0xa3, 0x01, 0x00, 0x00, 0x00},
			want:     "video/x-matroska",
		},
		{
			name:     "disguised pdf keeps pdf mime",
			filename: "fake.png",
			head:     []byte("%PDF-1.7\n"),
			want:     "application/pdf",
		},
		{
			name:     "svg xml",
			filename: "diagram.svg",
			head:     []byte(`<svg xmlns="http://www.w3.org/2000/svg"></svg>`),
			want:     "image/svg+xml",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := DetectAssetContentType(tc.filename, tc.head); got != tc.want {
				t.Fatalf("DetectAssetContentType(%q) = %q, want %q", tc.filename, got, tc.want)
			}
		})
	}
}

func TestAttachmentFolderPath(t *testing.T) {
	if got := AttachmentFolderPath("photo.png"); got != "attachments/photo.png" {
		t.Fatalf("got %q", got)
	}
	if got := AttachmentFolderPath("../nested\\clip.mov"); got != "attachments/clip.mov" {
		t.Fatalf("got %q", got)
	}
	if got := AttachmentFolderPath("   "); got != "attachments/attachment" {
		t.Fatalf("got %q", got)
	}
}

func TestSanitizeAndTargetAttachmentFilename(t *testing.T) {
	if got := SanitizeAttachmentFilename("  diagram.png "); got != "diagram.png" {
		t.Fatalf("got %q, want diagram.png", got)
	}
	for _, bad := range []string{"", "   ", ".", "..", "a/b.png", `a\b.png`, "foo\nbar.png"} {
		if got := SanitizeAttachmentFilename(bad); got != "" {
			t.Fatalf("SanitizeAttachmentFilename(%q) = %q, want empty", bad, got)
		}
	}
	if got := AttachmentFilenameTarget("img.png"); got != "img.png" {
		t.Fatalf("got %q", got)
	}
	if got := AttachmentFilenameTarget("attachments/img.png"); got != "img.png" {
		t.Fatalf("got %q", got)
	}
	if got := AttachmentFilenameTarget("Attachments/photo.heic"); got != "photo.heic" {
		t.Fatalf("got %q", got)
	}
	for _, nonFile := range []string{"", "Plain Note", "Folder/Note.md", "attachments/sub/a.png", "NoExtension"} {
		if got := AttachmentFilenameTarget(nonFile); got != "" {
			t.Fatalf("AttachmentFilenameTarget(%q) = %q, want empty", nonFile, got)
		}
	}
}
