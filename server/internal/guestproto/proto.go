// Package guestproto defines the vsock wire protocol between the Vesper host
// microVM driver and vesper-guest-agent (guest PID 1).
package guestproto

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
)

// Well-known AF_VSOCK ports between host (CID 2) and guest (CID >= 3).
const (
	PortRPC        uint32 = 1024 // host -> guest control/exec RPC
	PortEgressTCP  uint32 = 1025 // guest -> host proxied TCP stream
	PortEgressDNS  uint32 = 1026 // guest -> host synthetic DNS over length-framed stream
	PortReady      uint32 = 1027 // guest -> host boot readiness ping
	PortPlayground uint32 = 2000 // host -> guest localhost port forwarder
)

const MaxFrameSize = 16 << 20 // 16 MiB

// Frame types on PortRPC connections.
const (
	FrameReq       uint8 = 1  // JSON Request envelope
	FrameResp      uint8 = 2  // JSON Response envelope
	FrameStdin     uint8 = 10 // raw stdin bytes (host -> guest)
	FrameStdinEOF  uint8 = 11 // close child stdin (host -> guest)
	FrameStdout    uint8 = 12 // raw stdout bytes (guest -> host)
	FrameStderr    uint8 = 13 // raw stderr bytes (guest -> host)
	FrameResize    uint8 = 14 // [rows(2)][cols(2)] uint16 BE (host -> guest)
	FrameSignal    uint8 = 15 // [sig(4)] uint32 BE (host -> guest)
	FrameExecExit  uint8 = 16 // JSON ExecExit (guest -> host)
	FrameFileChunk uint8 = 17 // raw file chunk for ReadFile (guest -> host)
	FrameFileEOF   uint8 = 18 // empty end-of-file marker (guest -> host)
	FrameFileError uint8 = 19 // UTF-8 error string for ReadFile (guest -> host)
)

// RPC operations.
const (
	OpPing                = "ping"
	OpExecStart           = "exec_start"
	OpWriteFiles          = "write_files"
	OpStat                = "stat"
	OpReadFile            = "read_file"
	OpWalkDir             = "walk_dir"
	OpUnlinkPaths         = "unlink_paths"
	OpSyncAndDropCaches   = "sync_drop_caches"
	OpStartDockerd        = "start_dockerd"
	OpEnsureBridgeAliases = "ensure_bridge_aliases"
	OpShutdown            = "shutdown"
)

// Request is sent inside FrameReq.
type Request struct {
	Op string          `json:"op"`
	ID uint32          `json:"id,omitempty"`
	V  json.RawMessage `json:"v,omitempty"`
}

// Response is returned inside FrameResp for unary RPCs.
type Response struct {
	ID  uint32          `json:"id,omitempty"`
	Err string          `json:"err,omitempty"`
	V   json.RawMessage `json:"v,omitempty"`
}

type PingResp struct {
	Version    string `json:"version"`
	BootTimeNS int64  `json:"boot_time_ns"`
}

type FileWrite struct {
	Path string `json:"path"`
	Data []byte `json:"data"`
	Mode uint32 `json:"mode,omitempty"`
	UID  int    `json:"uid,omitempty"`
	GID  int    `json:"gid,omitempty"`
}

type ExecReq struct {
	Argv             []string          `json:"argv"`
	Env              map[string]string `json:"env,omitempty"`
	Dir              string            `json:"dir,omitempty"`
	UID              int               `json:"uid"`
	GID              int               `json:"gid"`
	Files            []FileWrite       `json:"files,omitempty"`
	TTY              bool              `json:"tty,omitempty"`
	Rows             uint16            `json:"rows,omitempty"`
	Cols             uint16            `json:"cols,omitempty"`
	MemoryLimitBytes int64             `json:"memory_limit_bytes,omitempty"`
	PidsLimit        int64             `json:"pids_limit,omitempty"`
	CgroupName       string            `json:"cgroup_name,omitempty"`
}

type ExecExit struct {
	Code      int    `json:"code"`
	OOMKilled bool   `json:"oom_killed,omitempty"`
	Error     string `json:"error,omitempty"`
}

type WriteFilesReq struct {
	Files []FileWrite `json:"files"`
}

type StatReq struct {
	Path string `json:"path"`
}

type StatResp struct {
	Exists        bool   `json:"exists"`
	IsDir         bool   `json:"is_dir"`
	IsRegular     bool   `json:"is_regular"`
	Size          int64  `json:"size"`
	Mode          uint32 `json:"mode"`
	ModTimeUnixNS int64  `json:"mod_time_unix_ns"`
}

type ReadFileReq struct {
	Path   string `json:"path"`
	Offset int64  `json:"offset,omitempty"`
	Limit  int64  `json:"limit,omitempty"`
}

type WalkDirReq struct {
	Root     string `json:"root"`
	MaxDepth int    `json:"max_depth,omitempty"` // 0 = unlimited
}

type DirEntry struct {
	Rel           string `json:"rel"`
	IsDir         bool   `json:"is_dir"`
	Size          int64  `json:"size"`
	Mode          uint32 `json:"mode"`
	ModTimeUnixNS int64  `json:"mod_time_unix_ns"`
}

type WalkDirResp struct {
	Entries []DirEntry `json:"entries"`
}

type UnlinkPathsReq struct {
	Paths     []string `json:"paths"`
	Recursive bool     `json:"recursive,omitempty"`
}

type StartDockerdReq struct {
	RegistryMirror string `json:"registry_mirror,omitempty"`
}

type EnsureBridgeAliasesReq struct {
	Aliases map[string]string `json:"aliases"` // hostname -> container IPv4
}

// Frame header layout: [type(1)][id(4)][len(4)] = 9 bytes.
const frameHeaderSize = 9

// Frame is a single length-prefixed protocol message.
type Frame struct {
	Type uint8
	ID   uint32
	Data []byte
}

// WriteFrame writes a length-prefixed frame atomically if guarded by a mutex.
func WriteFrame(w io.Writer, f Frame) error {
	if len(f.Data) > MaxFrameSize {
		return fmt.Errorf("guestproto: frame too large (%d > %d)", len(f.Data), MaxFrameSize)
	}
	var hdr [frameHeaderSize]byte
	hdr[0] = f.Type
	binary.BigEndian.PutUint32(hdr[1:5], f.ID)
	binary.BigEndian.PutUint32(hdr[5:9], uint32(len(f.Data)))
	if err := writeFull(w, hdr[:]); err != nil {
		return err
	}
	if len(f.Data) == 0 {
		return nil
	}
	return writeFull(w, f.Data)
}

// ReadFrame reads a length-prefixed frame.
func ReadFrame(r io.Reader) (Frame, error) {
	var hdr [frameHeaderSize]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return Frame{}, err
	}
	length := binary.BigEndian.Uint32(hdr[5:9])
	if length > MaxFrameSize {
		return Frame{}, fmt.Errorf("guestproto: frame too large (%d > %d)", length, MaxFrameSize)
	}
	var data []byte
	if length > 0 {
		data = make([]byte, length)
		if _, err := io.ReadFull(r, data); err != nil {
			return Frame{}, err
		}
	}
	return Frame{
		Type: hdr[0],
		ID:   binary.BigEndian.Uint32(hdr[1:5]),
		Data: data,
	}, nil
}

// SyncWriter serialises WriteFrame calls onto one stream connection.
type SyncWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func NewSyncWriter(w io.Writer) *SyncWriter { return &SyncWriter{w: w} }

func (s *SyncWriter) WriteFrame(f Frame) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return WriteFrame(s.w, f)
}

func WriteJSONFrame(w interface{ WriteFrame(Frame) error }, typ uint8, id uint32, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return w.WriteFrame(Frame{Type: typ, ID: id, Data: b})
}

func WriteRequest(w io.Writer, id uint32, op string, payload any) error {
	var raw json.RawMessage
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		raw = b
	}
	b, err := json.Marshal(Request{Op: op, ID: id, V: raw})
	if err != nil {
		return err
	}
	return WriteFrame(w, Frame{Type: FrameReq, ID: id, Data: b})
}

func ReadResponse(r io.Reader, out any) error {
	f, err := ReadFrame(r)
	if err != nil {
		return err
	}
	if f.Type != FrameResp {
		return fmt.Errorf("guestproto: unexpected frame type %d", f.Type)
	}
	var resp Response
	if err := json.Unmarshal(f.Data, &resp); err != nil {
		return err
	}
	if resp.Err != "" {
		return errors.New(resp.Err)
	}
	if out != nil && len(resp.V) > 0 {
		return json.Unmarshal(resp.V, out)
	}
	return nil
}

func EncodeResize(rows, cols uint16) []byte {
	var b [4]byte
	binary.BigEndian.PutUint16(b[0:2], rows)
	binary.BigEndian.PutUint16(b[2:4], cols)
	return b[:]
}

func DecodeResize(b []byte) (rows, cols uint16, err error) {
	if len(b) != 4 {
		return 0, 0, fmt.Errorf("guestproto: invalid resize len %d", len(b))
	}
	return binary.BigEndian.Uint16(b[0:2]), binary.BigEndian.Uint16(b[2:4]), nil
}

func EncodeSignal(sig uint32) []byte {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], sig)
	return b[:]
}

func DecodeSignal(b []byte) (uint32, error) {
	if len(b) != 4 {
		return 0, fmt.Errorf("guestproto: invalid signal len %d", len(b))
	}
	return binary.BigEndian.Uint32(b), nil
}

// Egress TCP header: [dstIPv4(4)][dstPort(2) BE].
func WriteEgressTCPHeader(w io.Writer, dstIP net.IP, dstPort uint16) error {
	ip4 := dstIP.To4()
	if ip4 == nil {
		return fmt.Errorf("guestproto: egress target must be IPv4, got %v", dstIP)
	}
	var hdr [6]byte
	copy(hdr[0:4], ip4)
	binary.BigEndian.PutUint16(hdr[4:6], dstPort)
	return writeFull(w, hdr[:])
}

func ReadEgressTCPHeader(r io.Reader) ([4]byte, uint16, error) {
	var hdr [6]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return [4]byte{}, 0, err
	}
	var ip [4]byte
	copy(ip[:], hdr[0:4])
	return ip, binary.BigEndian.Uint16(hdr[4:6]), nil
}

// Length-prefixed DNS packet framing on PortEgressDNS (RFC 1035 TCP framing).
func WriteDNSFrame(w io.Writer, pkt []byte) error {
	if len(pkt) > 65535 {
		return fmt.Errorf("guestproto: DNS packet too large (%d)", len(pkt))
	}
	var hdr [2]byte
	binary.BigEndian.PutUint16(hdr[:], uint16(len(pkt)))
	if err := writeFull(w, hdr[:]); err != nil {
		return err
	}
	return writeFull(w, pkt)
}

func ReadDNSFrame(r io.Reader) ([]byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint16(hdr[:])
	if n == 0 {
		return nil, nil
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

// Playground forwarder header on PortPlayground: [targetPort(2) BE].
func WritePlaygroundHeader(w io.Writer, port uint16) error {
	var hdr [2]byte
	binary.BigEndian.PutUint16(hdr[:], port)
	return writeFull(w, hdr[:])
}

func ReadPlaygroundHeader(r io.Reader) (uint16, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint16(hdr[:]), nil
}

func writeFull(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		b = b[n:]
	}
	return nil
}
