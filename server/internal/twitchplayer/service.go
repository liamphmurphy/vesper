package twitchplayer

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	DefaultClientID          = "kimne78kx3ncx6brgo4mv6wki5h1ko"
	DefaultGQLURL            = "https://gql.twitch.tv/gql"
	DefaultUsherBaseURL      = "https://usher.ttvnw.net"
	DefaultPrimaryPlayerType = "site"

	sessionTTL       = 2 * time.Hour
	maxSessions      = 64
	maxBackupTypes   = 8
	maxPlaylistBytes = 2 << 20
	fetchTimeout     = 15 * time.Second
)

var DefaultBackupPlayerTypes = []string{"embed", "popout", "autoplay"}

var (
	channelRE    = regexp.MustCompile(`^[a-z0-9_]{1,25}$`)
	vodIDRE      = regexp.MustCompile(`^[0-9]{1,20}$`)
	playerTypeRE = regexp.MustCompile(`^[a-z0-9_-]{1,32}$`)
)

const playbackAccessTokenQuery = `query PlaybackAccessToken_Template($login: String!, $isLive: Boolean!, $vodID: ID!, $isVod: Boolean!, $playerType: String!) {
  streamPlaybackAccessToken(channelName: $login, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isLive) {
    value
    signature
    __typename
  }
  videoPlaybackAccessToken(id: $vodID, params: {platform: "web", playerBackend: "mediaplayer", playerType: $playerType}) @include(if: $isVod) {
    value
    signature
    __typename
  }
}`

type CreateSessionInput struct {
	Kind          string   `json:"kind"`
	Channel       string   `json:"channel,omitempty"`
	VodID         string   `json:"vod_id,omitempty"`
	PlayerType    string   `json:"player_type,omitempty"`
	BackupTypes   []string `json:"backup_types,omitempty"`
	AdSwapEnabled *bool    `json:"ad_swap_enabled,omitempty"`
}

type UpdateSessionInput struct {
	AdSwapEnabled *bool    `json:"ad_swap_enabled,omitempty"`
	BackupTypes   []string `json:"backup_types,omitempty"`
}

type SessionInfo struct {
	ID             string           `json:"id"`
	Kind           string           `json:"kind"`
	Channel        string           `json:"channel,omitempty"`
	VodID          string           `json:"vod_id,omitempty"`
	PlayerType     string           `json:"player_type"`
	ActiveType     string           `json:"active_type"`
	BackupTypes    []string         `json:"backup_types"`
	AdSwapEnabled  bool             `json:"ad_swap_enabled"`
	AdActive       bool             `json:"ad_active"`
	UsingBackup    bool             `json:"using_backup"`
	AdStatus       string           `json:"ad_status"`
	AdDurationSec  float64          `json:"ad_duration_sec,omitempty"`
	AdSwapsCount   int              `json:"ad_swaps_count"`
	AdBreaksHidden int              `json:"ad_breaks_hidden"`
	MasterURL      string           `json:"master_url"`
	Variants       []QualityVariant `json:"variants"`
	UpdatedAt      time.Time        `json:"updated_at"`
}

type VariantPlaylistResult struct {
	Body          string
	AdActive      bool
	UsingBackup   bool
	ActiveType    string
	AdStatus      string
	AdDurationSec float64
}

type session struct {
	id             string
	userID         uuid.UUID
	kind           string
	channel        string
	vodID          string
	playerType     string
	activeType     string
	backupTypes    []string
	adSwapEnabled  bool
	adActive       bool
	usingBackup    bool
	adStatus       string
	adDurationSec  float64
	adSwapsCount   int
	adBreaksHidden int
	variants       []QualityVariant
	backupVariants map[string][]QualityVariant
	createdAt      time.Time
	updatedAt      time.Time
}

// Service resolves Twitch Usher HLS playlists via PlaybackAccessToken and serves
// per-session proxied manifests that swap backup player_types during stitched ads.
type Service struct {
	GQLURL       string
	UsherBaseURL string
	ClientID     string
	Transport    http.RoundTripper
	AllowLocal   bool
	Now          func() time.Time

	clientOnce sync.Once
	httpCli    *http.Client

	mu       sync.Mutex
	sessions map[string]*session
}

func ValidateChannel(raw string) (string, error) {
	ch := strings.ToLower(strings.TrimSpace(raw))
	if !channelRE.MatchString(ch) {
		return "", apperr.Invalid("channel", "invalid Twitch channel login")
	}
	return ch, nil
}

func ValidateVodID(raw string) (string, error) {
	id := strings.TrimSpace(raw)
	if !vodIDRE.MatchString(id) {
		return "", apperr.Invalid("vod_id", "invalid Twitch VOD ID")
	}
	return id, nil
}

func SanitizePlayerTypes(types []string) []string {
	out := make([]string, 0, len(types))
	seen := make(map[string]struct{}, len(types))
	for _, raw := range types {
		clean := strings.ToLower(strings.TrimSpace(raw))
		if !playerTypeRE.MatchString(clean) {
			continue
		}
		if _, dup := seen[clean]; dup {
			continue
		}
		seen[clean] = struct{}{}
		out = append(out, clean)
		if len(out) >= maxBackupTypes {
			break
		}
	}
	return out
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now().UTC()
}

func (s *Service) gqlURL() string {
	if strings.TrimSpace(s.GQLURL) != "" {
		return strings.TrimRight(strings.TrimSpace(s.GQLURL), "/")
	}
	return DefaultGQLURL
}

func (s *Service) usherBase() string {
	if strings.TrimSpace(s.UsherBaseURL) != "" {
		return strings.TrimRight(strings.TrimSpace(s.UsherBaseURL), "/")
	}
	return DefaultUsherBaseURL
}

func (s *Service) clientID() string {
	if strings.TrimSpace(s.ClientID) != "" {
		return strings.TrimSpace(s.ClientID)
	}
	return DefaultClientID
}

func (s *Service) client() *http.Client {
	s.clientOnce.Do(func() {
		rt := s.Transport
		if rt == nil {
			rt = usersecrets.SafeTransport(s.AllowLocal, nil)
		}
		allowLocal := s.AllowLocal
		s.httpCli = &http.Client{
			Transport: rt,
			Timeout:   fetchTimeout,
			CheckRedirect: func(next *http.Request, via []*http.Request) error {
				if len(via) >= 5 {
					return errors.New("too many redirects")
				}
				if next.URL == nil || next.URL.User != nil {
					return errors.New("invalid redirect URL")
				}
				if next.URL.Scheme != "https" && !(allowLocal && next.URL.Scheme == "http") {
					return errors.New("redirect to non-https URL rejected")
				}
				return nil
			},
		}
	})
	return s.httpCli
}

func newSessionID() (string, error) {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}

func (sess *session) toInfo() SessionInfo {
	variantsCopy := make([]QualityVariant, len(sess.variants))
	copy(variantsCopy, sess.variants)
	backupsCopy := slices.Clone(sess.backupTypes)
	return SessionInfo{
		ID:             sess.id,
		Kind:           sess.kind,
		Channel:        sess.channel,
		VodID:          sess.vodID,
		PlayerType:     sess.playerType,
		ActiveType:     sess.activeType,
		BackupTypes:    backupsCopy,
		AdSwapEnabled:  sess.adSwapEnabled,
		AdActive:       sess.adActive,
		UsingBackup:    sess.usingBackup,
		AdStatus:       sess.adStatus,
		AdDurationSec:  sess.adDurationSec,
		AdSwapsCount:   sess.adSwapsCount,
		AdBreaksHidden: sess.adBreaksHidden,
		MasterURL:      "/api/v1/twitch/sessions/" + sess.id + "/master.m3u8",
		Variants:       variantsCopy,
		UpdatedAt:      sess.updatedAt,
	}
}

func (s *Service) evictExpiredLocked(now time.Time) {
	if s.sessions == nil {
		s.sessions = map[string]*session{}
		return
	}
	for id, sess := range s.sessions {
		if now.Sub(sess.updatedAt) > sessionTTL {
			delete(s.sessions, id)
		}
	}
	for len(s.sessions) >= maxSessions {
		var oldestID string
		var oldestTime time.Time
		for id, sess := range s.sessions {
			if oldestID == "" || sess.updatedAt.Before(oldestTime) {
				oldestID = id
				oldestTime = sess.updatedAt
			}
		}
		if oldestID == "" {
			break
		}
		delete(s.sessions, oldestID)
	}
}

func (s *Service) lookupLocked(userID uuid.UUID, id string, now time.Time) (*session, error) {
	s.evictExpiredLocked(now)
	sess, ok := s.sessions[id]
	if !ok || sess.userID != userID {
		return nil, apperr.ErrNotFound
	}
	return sess, nil
}

// CreateSession authenticates against Twitch GQL, fetches Usher master variants, and stores a session.
func (s *Service) CreateSession(ctx context.Context, userID uuid.UUID, in CreateSessionInput) (SessionInfo, error) {
	kind := strings.ToLower(strings.TrimSpace(in.Kind))
	var channel, vodID string
	var err error
	switch kind {
	case "live":
		channel, err = ValidateChannel(in.Channel)
		if err != nil {
			return SessionInfo{}, err
		}
	case "vod":
		vodID, err = ValidateVodID(in.VodID)
		if err != nil {
			return SessionInfo{}, err
		}
	default:
		return SessionInfo{}, apperr.Invalid("kind", "kind must be live or vod")
	}

	primaryType := strings.ToLower(strings.TrimSpace(in.PlayerType))
	if primaryType == "" {
		primaryType = DefaultPrimaryPlayerType
	} else if !playerTypeRE.MatchString(primaryType) {
		return SessionInfo{}, apperr.Invalid("player_type", "invalid player_type")
	}

	backupTypes := SanitizePlayerTypes(in.BackupTypes)
	if len(in.BackupTypes) == 0 {
		backupTypes = slices.Clone(DefaultBackupPlayerTypes)
	}
	backupTypes = slices.DeleteFunc(backupTypes, func(t string) bool { return t == primaryType })

	adSwapEnabled := true
	if in.AdSwapEnabled != nil {
		adSwapEnabled = *in.AdSwapEnabled
	}

	resolvedType := primaryType
	variants, resolveErr := s.resolveMaster(ctx, kind, channel, vodID, primaryType)
	if resolveErr != nil {
		if errors.Is(resolveErr, apperr.ErrNotFound) || kind != "live" || len(backupTypes) == 0 {
			return SessionInfo{}, resolveErr
		}
		var fallbackErr error
		for _, bt := range backupTypes {
			variants, fallbackErr = s.resolveMaster(ctx, kind, channel, vodID, bt)
			if fallbackErr == nil {
				resolvedType = bt
				resolveErr = nil
				break
			}
			if errors.Is(fallbackErr, apperr.ErrNotFound) {
				return SessionInfo{}, fallbackErr
			}
		}
		if resolveErr != nil {
			return SessionInfo{}, resolveErr
		}
	}

	id, err := newSessionID()
	if err != nil {
		return SessionInfo{}, err
	}
	now := s.now()
	sess := &session{
		id:             id,
		userID:         userID,
		kind:           kind,
		channel:        channel,
		vodID:          vodID,
		playerType:     resolvedType,
		activeType:     resolvedType,
		backupTypes:    backupTypes,
		adSwapEnabled:  adSwapEnabled,
		adStatus:       "none",
		variants:       variants,
		backupVariants: map[string][]QualityVariant{},
		createdAt:      now,
		updatedAt:      now,
	}

	s.mu.Lock()
	s.evictExpiredLocked(now)
	s.sessions[id] = sess
	info := sess.toInfo()
	s.mu.Unlock()

	return info, nil
}

func (s *Service) GetSession(userID uuid.UUID, id string) (SessionInfo, error) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, err := s.lookupLocked(userID, id, now)
	if err != nil {
		return SessionInfo{}, err
	}
	return sess.toInfo(), nil
}

func (s *Service) UpdateSession(userID uuid.UUID, id string, in UpdateSessionInput) (SessionInfo, error) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, err := s.lookupLocked(userID, id, now)
	if err != nil {
		return SessionInfo{}, err
	}
	if in.AdSwapEnabled != nil {
		sess.adSwapEnabled = *in.AdSwapEnabled
	}
	if in.BackupTypes != nil {
		cleaned := SanitizePlayerTypes(in.BackupTypes)
		sess.backupTypes = slices.DeleteFunc(cleaned, func(t string) bool { return t == sess.playerType })
	}
	sess.updatedAt = now
	return sess.toInfo(), nil
}

func (s *Service) DeleteSession(userID uuid.UUID, id string) error {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.lookupLocked(userID, id, now); err != nil {
		return err
	}
	delete(s.sessions, id)
	return nil
}

func (s *Service) MasterPlaylist(userID uuid.UUID, id string) (string, error) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, err := s.lookupLocked(userID, id, now)
	if err != nil {
		return "", err
	}
	sess.updatedAt = now
	return RenderProxiedMaster(sess.variants), nil
}

// VariantPlaylist fetches a quality variant's media playlist, detects SSAI stitched
// ads, swaps to a clean backup player_type when possible, and rewrites URIs to edge CDN URLs.
func (s *Service) VariantPlaylist(ctx context.Context, userID uuid.UUID, id string, variantIdx int) (VariantPlaylistResult, error) {
	now := s.now()
	s.mu.Lock()
	sess, err := s.lookupLocked(userID, id, now)
	if err != nil {
		s.mu.Unlock()
		return VariantPlaylistResult{}, err
	}
	if variantIdx < 0 || variantIdx >= len(sess.variants) {
		s.mu.Unlock()
		return VariantPlaylistResult{}, apperr.ErrNotFound
	}
	targetVariant := sess.variants[variantIdx]
	kind := sess.kind
	channel := sess.channel
	vodID := sess.vodID
	primaryType := sess.playerType
	adSwapEnabled := sess.adSwapEnabled
	backupTypes := slices.Clone(sess.backupTypes)
	cachedBackups := make(map[string][]QualityVariant, len(sess.backupVariants))
	for k, v := range sess.backupVariants {
		cachedBackups[k] = slices.Clone(v)
	}
	s.mu.Unlock()

	primaryRaw, err := s.fetchText(ctx, targetVariant.URL, "edge playlist")
	if err != nil {
		return VariantPlaylistResult{}, err
	}
	info := InspectMediaPlaylist(primaryRaw)

	chosenBody := ""
	adActive := info.AdActive
	usingBackup := false
	activeType := primaryType
	adStatus := "none"
	adDuration := info.DurationSec

	if info.AdActive {
		adStatus = "active"
	}

	if kind == "live" && adSwapEnabled && info.AdActive {
		for _, bt := range backupTypes {
			if bt == "" || bt == primaryType {
				continue
			}
			bVars, ok := cachedBackups[bt]
			if !ok {
				fetched, berr := s.resolveMaster(ctx, kind, channel, vodID, bt)
				if berr != nil {
					continue
				}
				bVars = fetched
				s.mu.Lock()
				if liveSess, exists := s.sessions[id]; exists && liveSess.userID == userID {
					liveSess.backupVariants[bt] = slices.Clone(fetched)
				}
				s.mu.Unlock()
			}
			bTarget, ok := selectMatchingVariant(bVars, targetVariant)
			if !ok {
				continue
			}
			bRaw, berr := s.fetchText(ctx, bTarget.URL, "backup playlist")
			if berr != nil {
				continue
			}
			bInfo := InspectMediaPlaylist(bRaw)
			if !bInfo.AdActive {
				chosenBody = RewriteMediaPlaylist(bRaw, bTarget.URL, false)
				adActive = false
				usingBackup = true
				activeType = bt
				adStatus = "swapped"
				adDuration = 0
				break
			}
		}
	}

	if chosenBody == "" {
		chosenBody = RewriteMediaPlaylist(primaryRaw, targetVariant.URL, adActive)
	}

	now = s.now()
	s.mu.Lock()
	if liveSess, exists := s.sessions[id]; exists && liveSess.userID == userID {
		if usingBackup && !liveSess.usingBackup {
			liveSess.adSwapsCount++
		}
		if adActive && !liveSess.adActive {
			liveSess.adBreaksHidden++
		}
		liveSess.adActive = adActive
		liveSess.usingBackup = usingBackup
		liveSess.activeType = activeType
		liveSess.adStatus = adStatus
		liveSess.adDurationSec = adDuration
		liveSess.updatedAt = now
	}
	s.mu.Unlock()

	return VariantPlaylistResult{
		Body:          chosenBody,
		AdActive:      adActive,
		UsingBackup:   usingBackup,
		ActiveType:    activeType,
		AdStatus:      adStatus,
		AdDurationSec: adDuration,
	}, nil
}

func selectMatchingVariant(variants []QualityVariant, target QualityVariant) (QualityVariant, bool) {
	if len(variants) == 0 {
		return QualityVariant{}, false
	}
	if target.GroupID != "" {
		for _, v := range variants {
			if strings.EqualFold(v.GroupID, target.GroupID) {
				return v, true
			}
		}
	}
	if target.Resolution != "" {
		for _, v := range variants {
			if strings.EqualFold(v.Resolution, target.Resolution) {
				return v, true
			}
		}
	}
	if target.AudioOnly {
		for _, v := range variants {
			if v.AudioOnly {
				return v, true
			}
		}
		return variants[len(variants)-1], true
	}

	bestIdx := -1
	bestDiff := 0
	for i, v := range variants {
		if v.AudioOnly {
			continue
		}
		diff := v.Bandwidth - target.Bandwidth
		if diff < 0 {
			diff = -diff
		}
		if bestIdx < 0 || diff < bestDiff || (diff == bestDiff && v.Bandwidth > variants[bestIdx].Bandwidth) {
			bestIdx = i
			bestDiff = diff
		}
	}
	if bestIdx >= 0 {
		return variants[bestIdx], true
	}
	return variants[0], true
}

func (s *Service) resolveMaster(ctx context.Context, kind, channel, vodID, playerType string) ([]QualityVariant, error) {
	tok, sig, err := s.fetchPlaybackAccessToken(ctx, kind, channel, vodID, playerType)
	if err != nil {
		return nil, err
	}
	usherURL, err := s.buildUsherURL(kind, channel, vodID, tok, sig)
	if err != nil {
		return nil, err
	}
	raw, err := s.fetchText(ctx, usherURL, "Usher master playlist")
	if err != nil {
		return nil, err
	}
	return ParseMasterPlaylist(raw, usherURL, s.AllowLocal)
}

func (s *Service) fetchPlaybackAccessToken(ctx context.Context, kind, channel, vodID, playerType string) (string, string, error) {
	payload := map[string]any{
		"operationName": "PlaybackAccessToken_Template",
		"query":         playbackAccessTokenQuery,
		"variables": map[string]any{
			"isLive":     kind == "live",
			"login":      channel,
			"isVod":      kind == "vod",
			"vodID":      vodID,
			"playerType": playerType,
		},
	}
	bodyBytes, err := json.Marshal(payload)
	if err != nil {
		return "", "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.gqlURL(), bytes.NewReader(bodyBytes))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Client-ID", s.clientID())
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	res, err := s.client().Do(req)
	if err != nil {
		var b *usersecrets.Blocked
		if errors.As(err, &b) {
			return "", "", apperr.Invalid("url", "%s", b.Reason)
		}
		return "", "", apperr.Conflict("Twitch playback token request failed: %v", err)
	}
	defer res.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(res.Body, maxPlaylistBytes))
	if err != nil {
		return "", "", apperr.Conflict("reading Twitch GQL response: %v", err)
	}
	if res.StatusCode >= 400 {
		return "", "", apperr.Conflict("Twitch GQL returned HTTP %d", res.StatusCode)
	}

	var gqlResp struct {
		Data struct {
			Stream *struct {
				Value     string `json:"value"`
				Signature string `json:"signature"`
			} `json:"streamPlaybackAccessToken"`
			Video *struct {
				Value     string `json:"value"`
				Signature string `json:"signature"`
			} `json:"videoPlaybackAccessToken"`
		} `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(raw, &gqlResp); err != nil {
		return "", "", apperr.Conflict("invalid Twitch GQL token response")
	}

	tokObj := gqlResp.Data.Stream
	if kind == "vod" {
		tokObj = gqlResp.Data.Video
	}
	if tokObj == nil || tokObj.Value == "" || tokObj.Signature == "" {
		if len(gqlResp.Errors) > 0 && gqlResp.Errors[0].Message != "" {
			return "", "", apperr.Conflict("Twitch token error: %s", gqlResp.Errors[0].Message)
		}
		return "", "", apperr.ErrNotFound
	}
	return tokObj.Value, tokObj.Signature, nil
}

func (s *Service) buildUsherURL(kind, channel, vodID, token, sig string) (string, error) {
	base := s.usherBase()
	var b [4]byte
	_, _ = rand.Read(b[:])
	randInt := uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
	pVal := strconv.FormatUint(uint64(randInt%9_000_000+1_000_000), 10)

	q := url.Values{}
	q.Set("allow_source", "true")
	q.Set("allow_audio_only", "true")
	q.Set("p", pVal)
	q.Set("player_backend", "mediaplayer")
	q.Set("playlist_include_framerate", "true")
	q.Set("supported_codecs", "av1,h265,h264")

	if kind == "live" {
		q.Set("fast_bread", "true")
		q.Set("token", token)
		q.Set("sig", sig)
		return fmt.Sprintf("%s/api/channel/hls/%s.m3u8?%s", base, url.PathEscape(channel), q.Encode()), nil
	}
	q.Set("nauth", token)
	q.Set("nauthsig", sig)
	return fmt.Sprintf("%s/vod/%s.m3u8?%s", base, url.PathEscape(vodID), q.Encode()), nil
}

func (s *Service) fetchText(ctx context.Context, targetURL, what string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
	if err != nil {
		return "", apperr.Invalid("url", "invalid %s URL: %v", what, err)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	req.Header.Set("Accept", "application/vnd.apple.mpegurl, application/x-mpegurl, text/plain, */*")

	res, err := s.client().Do(req)
	if err != nil {
		var b *usersecrets.Blocked
		if errors.As(err, &b) {
			return "", apperr.Invalid("url", "%s", b.Reason)
		}
		return "", apperr.Conflict("fetching %s: %v", what, err)
	}
	defer res.Body.Close()

	if res.StatusCode == http.StatusNotFound {
		return "", apperr.ErrNotFound
	}
	if res.StatusCode >= 400 {
		return "", apperr.Conflict("%s returned HTTP %d", what, res.StatusCode)
	}

	raw, err := io.ReadAll(io.LimitReader(res.Body, maxPlaylistBytes+1))
	if err != nil {
		return "", apperr.Conflict("reading %s: %v", what, err)
	}
	if len(raw) > maxPlaylistBytes {
		return "", apperr.Conflict("%s exceeds 2 MB limit", what)
	}
	return string(raw), nil
}
