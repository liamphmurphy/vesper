// Package media defines provider-agnostic interfaces, registries, and services
// for external and local media generation backends (music today; TTS and
// script generation later) without leaking vendor SDK types into Vesper.
package media

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// ErrorKind categorizes provider failures so the API and UI can render
// actionable guidance across all adapters without vendor-specific branching.
type ErrorKind string

const (
	ErrKindAuth        ErrorKind = "auth"
	ErrKindQuota       ErrorKind = "quota"
	ErrKindRateLimit   ErrorKind = "rate_limit"
	ErrKindFiltered    ErrorKind = "filtered"
	ErrKindUnavailable ErrorKind = "unavailable"
	ErrKindUnknown     ErrorKind = "error"
)

// ProviderError is a normalized error returned by media provider adapters.
type ProviderError struct {
	Provider   string
	Kind       ErrorKind
	HTTPStatus int
	RetryAfter time.Duration
	Message    string
	Err        error
}

func (e *ProviderError) Error() string {
	if e == nil {
		return ""
	}
	if e.Message != "" {
		return e.Message
	}
	if e.Err != nil {
		return fmt.Sprintf("%s: %v", e.Provider, e.Err)
	}
	return fmt.Sprintf("%s: %s", e.Provider, e.Kind)
}

func (e *ProviderError) Unwrap() error { return e.Err }

// ClassifyError extracts a normalized ErrorKind and safe user-facing message
// from err.
func ClassifyError(err error) (ErrorKind, string) {
	if err == nil {
		return "", ""
	}
	var pe *ProviderError
	if errors.As(err, &pe) {
		kind := pe.Kind
		if kind == "" {
			kind = ErrKindUnknown
		}
		msg := strings.TrimSpace(pe.Error())
		if msg == "" {
			msg = "Music generation failed."
		}
		return kind, msg
	}
	msg := strings.TrimSpace(err.Error())
	if msg == "" {
		msg = "Music generation failed."
	}
	return ErrKindUnknown, msg
}
