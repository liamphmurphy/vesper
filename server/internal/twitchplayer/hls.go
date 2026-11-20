package twitchplayer

import (
	"fmt"
	"net/url"
	"strconv"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// QualityVariant describes one video or audio-only rendition from an Usher master playlist.
type QualityVariant struct {
	Index      int     `json:"index"`
	Name       string  `json:"name"`
	GroupID    string  `json:"group_id"`
	Resolution string  `json:"resolution,omitempty"`
	Bandwidth  int     `json:"bandwidth"`
	FrameRate  float64 `json:"frame_rate,omitempty"`
	Codecs     string  `json:"codecs,omitempty"`
	AudioOnly  bool    `json:"audio_only"`
	URL        string  `json:"-"`
}

// PlaylistAdInfo summarizes Twitch SSAI ad tags and segments inside a media playlist.
type PlaylistAdInfo struct {
	AdActive      bool     `json:"ad_active"`
	DurationSec   float64  `json:"duration_sec"`
	AdSegments    int      `json:"ad_segments"`
	TotalSegments int      `json:"total_segments"`
	Markers       []string `json:"markers,omitempty"`
}

// parseHLSAttributes parses KEY=VALUE or KEY="VALUE" comma-separated HLS tag attributes.
func parseHLSAttributes(raw string) map[string]string {
	attrs := map[string]string{}
	i := 0
	n := len(raw)
	for i < n {
		for i < n && (raw[i] == ',' || raw[i] == ' ' || raw[i] == '\t') {
			i++
		}
		if i >= n {
			break
		}
		eq := strings.IndexByte(raw[i:], '=')
		if eq < 0 {
			break
		}
		key := strings.TrimSpace(raw[i : i+eq])
		i += eq + 1
		if i >= n {
			break
		}
		var val string
		if raw[i] == '"' {
			i++
			var sb strings.Builder
			for i < n {
				if raw[i] == '\\' && i+1 < n {
					sb.WriteByte(raw[i+1])
					i += 2
					continue
				}
				if raw[i] == '"' {
					i++
					break
				}
				sb.WriteByte(raw[i])
				i++
			}
			val = sb.String()
			for i < n && raw[i] != ',' {
				i++
			}
		} else {
			comma := strings.IndexByte(raw[i:], ',')
			if comma < 0 {
				val = strings.TrimSpace(raw[i:])
				i = n
			} else {
				val = strings.TrimSpace(raw[i : i+comma])
				i += comma + 1
			}
		}
		if key != "" {
			attrs[strings.ToUpper(key)] = val
		}
	}
	return attrs
}

func resolvePlaylistURI(rawURI, baseURL string, allowLocal bool) (string, error) {
	u, err := url.Parse(strings.TrimSpace(rawURI))
	if err != nil {
		return "", fmt.Errorf("invalid playlist URI %q: %w", rawURI, err)
	}
	if baseURL != "" {
		base, berr := url.Parse(baseURL)
		if berr == nil {
			u = base.ResolveReference(u)
		}
	}
	if u.User != nil || u.Host == "" {
		return "", fmt.Errorf("playlist URI %q missing valid host", rawURI)
	}
	if u.Scheme != "https" && !(allowLocal && u.Scheme == "http") {
		return "", fmt.Errorf("playlist URI %q must use https", rawURI)
	}
	return u.String(), nil
}

func formatVariantName(groupID, mediaName, resolution string, fps float64, bw int, audioOnly bool) string {
	if mediaName != "" {
		return mediaName
	}
	if audioOnly {
		return "Audio Only"
	}
	if _, h, ok := strings.Cut(strings.ToLower(resolution), "x"); ok && h != "" {
		if fps >= 45 {
			return fmt.Sprintf("%sp%.0f", h, fps)
		}
		return fmt.Sprintf("%sp", h)
	}
	if groupID != "" {
		return groupID
	}
	if bw > 0 {
		return fmt.Sprintf("%d kbps", bw/1000)
	}
	return "Stream"
}

// ParseMasterPlaylist extracts quality variants from an Usher master M3U8 playlist.
func ParseMasterPlaylist(raw, baseURL string, allowLocal bool) ([]QualityVariant, error) {
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	groupNames := map[string]string{}
	var variants []QualityVariant

	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if strings.HasPrefix(line, "#EXT-X-MEDIA:") {
			attrs := parseHLSAttributes(strings.TrimPrefix(line, "#EXT-X-MEDIA:"))
			if strings.EqualFold(attrs["TYPE"], "VIDEO") && attrs["GROUP-ID"] != "" && attrs["NAME"] != "" {
				groupNames[attrs["GROUP-ID"]] = attrs["NAME"]
			}
			continue
		}
		if !strings.HasPrefix(line, "#EXT-X-STREAM-INF:") {
			continue
		}
		attrs := parseHLSAttributes(strings.TrimPrefix(line, "#EXT-X-STREAM-INF:"))
		var uriLine string
		for j := i + 1; j < len(lines); j++ {
			cand := strings.TrimSpace(lines[j])
			if cand == "" {
				continue
			}
			if strings.HasPrefix(cand, "#") {
				if strings.HasPrefix(cand, "#EXT-X-STREAM-INF:") {
					break
				}
				continue
			}
			uriLine = cand
			i = j
			break
		}
		if uriLine == "" {
			continue
		}
		resolved, err := resolvePlaylistURI(uriLine, baseURL, allowLocal)
		if err != nil {
			continue
		}
		bw, _ := strconv.Atoi(attrs["BANDWIDTH"])
		fps, _ := strconv.ParseFloat(attrs["FRAME-RATE"], 64)
		groupID := attrs["VIDEO"]
		resolution := attrs["RESOLUTION"]
		audioOnly := strings.EqualFold(groupID, "audio_only") || resolution == ""
		if groupID == "" && audioOnly {
			groupID = "audio_only"
		}
		name := formatVariantName(groupID, groupNames[groupID], resolution, fps, bw, audioOnly)
		variants = append(variants, QualityVariant{
			Index:      len(variants),
			Name:       name,
			GroupID:    groupID,
			Resolution: resolution,
			Bandwidth:  bw,
			FrameRate:  fps,
			Codecs:     attrs["CODECS"],
			AudioOnly:  audioOnly,
			URL:        resolved,
		})
	}

	if len(variants) == 0 {
		return nil, apperr.Conflict("no playable HLS variants in master playlist")
	}
	return variants, nil
}

// RenderProxiedMaster builds an HLS master playlist whose variant URIs point back
// to Vesper's session variant proxy endpoints (variant/<idx>.m3u8).
func RenderProxiedMaster(variants []QualityVariant) string {
	var sb strings.Builder
	sb.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n")
	for i, v := range variants {
		groupID := v.GroupID
		if groupID == "" {
			groupID = fmt.Sprintf("q_%d", i)
		}
		defVal := "NO"
		if i == 0 {
			defVal = "YES"
		}
		fmt.Fprintf(&sb, "#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=%q,NAME=%q,AUTOSELECT=YES,DEFAULT=%s\n",
			groupID, v.Name, defVal)

		var fields []string
		bw := v.Bandwidth
		if bw <= 0 {
			bw = 100000
		}
		fields = append(fields, fmt.Sprintf("BANDWIDTH=%d", bw))
		if v.Codecs != "" {
			fields = append(fields, fmt.Sprintf("CODECS=%q", v.Codecs))
		}
		if v.Resolution != "" {
			fields = append(fields, "RESOLUTION="+v.Resolution)
		}
		if v.FrameRate > 0 {
			fields = append(fields, fmt.Sprintf("FRAME-RATE=%.3f", v.FrameRate))
		}
		fields = append(fields, fmt.Sprintf("VIDEO=%q", groupID))
		fmt.Fprintf(&sb, "#EXT-X-STREAM-INF:%s\n", strings.Join(fields, ","))
		fmt.Fprintf(&sb, "variant/%d.m3u8\n", v.Index)
	}
	return sb.String()
}

// InspectMediaPlaylist inspects an HLS media playlist for Twitch SSAI ad indicators.
func InspectMediaPlaylist(raw string) PlaylistAdInfo {
	var info PlaylistAdInfo
	seenMarkers := map[string]struct{}{}
	addMarker := func(m string) {
		if m == "" {
			return
		}
		if _, ok := seenMarkers[m]; !ok {
			seenMarkers[m] = struct{}{}
			info.Markers = append(info.Markers, m)
		}
	}

	hasActiveDateRangeAd := false
	inCueAd := false
	tagDuration := 0.0
	cueDuration := 0.0
	adSegmentDuration := 0.0
	hasTrailingCleanAfterCue := false

	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	for _, rawLine := range lines {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "#EXT-X-DATERANGE:") {
			attrs := parseHLSAttributes(strings.TrimPrefix(line, "#EXT-X-DATERANGE:"))
			cls := attrs["CLASS"]
			id := strings.ToLower(attrs["ID"])
			upperLine := strings.ToUpper(line)
			if strings.EqualFold(cls, "twitch-stitched-ad") ||
				strings.Contains(id, "stitched-ad") ||
				strings.Contains(id, "amazon-ad") ||
				strings.Contains(upperLine, "X-TV-TWITCH-AD-") ||
				strings.Contains(upperLine, "SCTE35-OUT") {
				hasActiveDateRangeAd = true
				if cls != "" {
					addMarker(cls)
				} else {
					addMarker("daterange")
				}
				for _, k := range []string{"DURATION", "PLANNED-DURATION"} {
					if d, err := strconv.ParseFloat(attrs[k], 64); err == nil && d > tagDuration {
						tagDuration = d
					}
				}
			}
			continue
		}

		if strings.HasPrefix(line, "#EXT-X-CUE-OUT") || strings.HasPrefix(line, "#EXT-X-SCTE35-OUT") {
			inCueAd = true
			hasTrailingCleanAfterCue = false
			addMarker("cue-out")
			if _, durStr, ok := strings.Cut(line, ":"); ok {
				if eqIdx := strings.Index(durStr, "DURATION="); eqIdx >= 0 {
					durStr = durStr[eqIdx+len("DURATION="):]
					if comma := strings.IndexByte(durStr, ','); comma >= 0 {
						durStr = durStr[:comma]
					}
				}
				if d, err := strconv.ParseFloat(strings.TrimSpace(durStr), 64); err == nil && d > cueDuration {
					cueDuration = d
				}
			}
			continue
		}

		if strings.HasPrefix(line, "#EXT-X-CUE-IN") || strings.HasPrefix(line, "#EXT-X-SCTE35-IN") {
			inCueAd = false
			cueDuration = 0
			continue
		}

		if strings.HasPrefix(line, "#EXTINF:") {
			info.TotalSegments++
			rest := strings.TrimPrefix(line, "#EXTINF:")
			durPart, titlePart, _ := strings.Cut(rest, ",")
			segDur, _ := strconv.ParseFloat(strings.TrimSpace(durPart), 64)
			title := strings.TrimSpace(titlePart)

			isTitledAd := title != "" && !strings.EqualFold(title, "live")
			if isTitledAd {
				info.AdSegments++
				adSegmentDuration += segDur
				addMarker(title)
				hasTrailingCleanAfterCue = false
			} else if !inCueAd {
				hasTrailingCleanAfterCue = true
			}
			continue
		}
	}

	info.DurationSec = max(tagDuration, cueDuration, adSegmentDuration)
	hasActiveCue := inCueAd && !hasTrailingCleanAfterCue
	info.AdActive = info.AdSegments > 0 || hasActiveDateRangeAd || hasActiveCue
	return info
}

// RewriteMediaPlaylist resolves relative segment/map/prefetch URIs against baseURL
// so browsers fetch heavy media chunks directly from Twitch edge CDNs. During active
// ads, prefetch hints are stripped so players don't warm up stitched ad segments.
func RewriteMediaPlaylist(raw, baseURL string, adActive bool) string {
	base, baseErr := url.Parse(baseURL)
	resolve := func(ref string) string {
		trimmed := strings.TrimSpace(ref)
		if trimmed == "" || baseErr != nil {
			return trimmed
		}
		u, err := url.Parse(trimmed)
		if err != nil {
			return trimmed
		}
		return base.ResolveReference(u).String()
	}

	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	out := make([]string, 0, len(lines))
	for _, rawLine := range lines {
		line := strings.TrimRight(rawLine, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			out = append(out, line)
			continue
		}
		if strings.HasPrefix(trimmed, "#EXT-X-TWITCH-PREFETCH:") {
			if adActive {
				continue
			}
			ref := strings.TrimPrefix(trimmed, "#EXT-X-TWITCH-PREFETCH:")
			out = append(out, "#EXT-X-TWITCH-PREFETCH:"+resolve(ref))
			continue
		}
		if strings.HasPrefix(trimmed, "#EXT-X-MAP:") {
			attrs := parseHLSAttributes(strings.TrimPrefix(trimmed, "#EXT-X-MAP:"))
			if rawURI, ok := attrs["URI"]; ok && rawURI != "" {
				absURI := resolve(rawURI)
				replaced := replaceAttributeURI(trimmed, rawURI, absURI)
				out = append(out, replaced)
				continue
			}
			out = append(out, line)
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			out = append(out, line)
			continue
		}
		out = append(out, resolve(trimmed))
	}
	return strings.Join(out, "\n")
}

func replaceAttributeURI(line, oldURI, newURI string) string {
	oldQuoted := fmt.Sprintf(`URI="%s"`, oldURI)
	newQuoted := fmt.Sprintf(`URI="%s"`, newURI)
	if strings.Contains(line, oldQuoted) {
		return strings.Replace(line, oldQuoted, newQuoted, 1)
	}
	return strings.Replace(line, oldURI, newURI, 1)
}
