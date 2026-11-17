package guestproto

import (
	"bytes"
	"net"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	in := Frame{Type: FrameStdout, ID: 42, Data: []byte("hello world")}
	if err := WriteFrame(&buf, in); err != nil {
		t.Fatal(err)
	}
	out, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if out.Type != in.Type || out.ID != in.ID || !bytes.Equal(out.Data, in.Data) {
		t.Fatalf("got %+v, want %+v", out, in)
	}
}

func TestRequestResponseRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteRequest(&buf, 7, OpStat, StatReq{Path: "/workspace"}); err != nil {
		t.Fatal(err)
	}
	f, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if f.Type != FrameReq || f.ID != 7 {
		t.Fatalf("unexpected req frame: %+v", f)
	}
}

func TestHeadersAndResize(t *testing.T) {
	rows, cols, err := DecodeResize(EncodeResize(48, 132))
	if err != nil || rows != 48 || cols != 132 {
		t.Fatalf("resize: %d,%d %v", rows, cols, err)
	}
	sig, err := DecodeSignal(EncodeSignal(15))
	if err != nil || sig != 15 {
		t.Fatalf("signal: %d %v", sig, err)
	}
	var egress bytes.Buffer
	if err := WriteEgressTCPHeader(&egress, net.ParseIP("198.18.0.5"), 443); err != nil {
		t.Fatal(err)
	}
	ip, port, err := ReadEgressTCPHeader(&egress)
	if err != nil || ip != [4]byte{198, 18, 0, 5} || port != 443 {
		t.Fatalf("egress: %v %d %v", ip, port, err)
	}
	var dns bytes.Buffer
	pkt := []byte{0x12, 0x34, 0x01, 0x00}
	if err := WriteDNSFrame(&dns, pkt); err != nil {
		t.Fatal(err)
	}
	gotDNS, err := ReadDNSFrame(&dns)
	if err != nil || !bytes.Equal(gotDNS, pkt) {
		t.Fatalf("dns: %x %v", gotDNS, err)
	}
	var pg bytes.Buffer
	if err := WritePlaygroundHeader(&pg, 3000); err != nil {
		t.Fatal(err)
	}
	pgPort, err := ReadPlaygroundHeader(&pg)
	if err != nil || pgPort != 3000 {
		t.Fatalf("pg: %d %v", pgPort, err)
	}
}
