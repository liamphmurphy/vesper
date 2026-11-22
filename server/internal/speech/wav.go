package speech

import (
	"bytes"
	"encoding/binary"
)

// DefaultPCMRate is the sample rate of Gemini TTS 16-bit mono PCM when no
// explicit rate parameter is carried in the MIME type or WAV header.
const DefaultPCMRate = 24000

// WAVData returns the data chunk and sample rate of a 16-bit mono WAV, skipping
// every other chunk (such as provenance/C2PA trailers). ok is false when b is
// not such a WAV.
func WAVData(b []byte) (pcm []byte, rate int, ok bool) {
	if len(b) < 12 || string(b[:4]) != "RIFF" || string(b[8:12]) != "WAVE" {
		return nil, 0, false
	}
	rate = DefaultPCMRate
	for off := 12; off+8 <= len(b); {
		id := string(b[off : off+4])
		size := int(binary.LittleEndian.Uint32(b[off+4 : off+8]))
		body := off + 8
		end := body + size
		if size < 0 || end > len(b) {
			end = len(b) // a truncated or streaming-size chunk runs to the end
		}
		switch id {
		case "fmt ":
			if end-body >= 16 {
				channels := binary.LittleEndian.Uint16(b[body+2 : body+4])
				bits := binary.LittleEndian.Uint16(b[body+14 : body+16])
				if channels != 1 || bits != 16 {
					return nil, 0, false
				}
				rate = int(binary.LittleEndian.Uint32(b[body+4 : body+8]))
			}
		case "data":
			return b[body:end], rate, true
		}
		off = end + size%2 // chunks are word-aligned
	}
	return nil, 0, false
}

// WAVFromPCM wraps 16-bit signed little-endian mono PCM in a RIFF/WAVE header.
func WAVFromPCM(pcm []byte, rate int) []byte {
	if rate <= 0 {
		rate = DefaultPCMRate
	}
	var b bytes.Buffer
	b.Grow(44 + len(pcm))
	w := func(v any) { _ = binary.Write(&b, binary.LittleEndian, v) }
	b.WriteString("RIFF")
	w(uint32(36 + len(pcm)))
	b.WriteString("WAVEfmt ")
	w(uint32(16))       // fmt chunk size
	w(uint16(1))        // PCM
	w(uint16(1))        // mono
	w(uint32(rate))     // sample rate
	w(uint32(rate * 2)) // byte rate
	w(uint16(2))        // block align
	w(uint16(16))       // bits per sample
	b.WriteString("data")
	w(uint32(len(pcm)))
	b.Write(pcm)
	return b.Bytes()
}
