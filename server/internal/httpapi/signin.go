package httpapi

import (
	_ "embed"
	"errors"
	"net/http"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/companion"
)

//go:embed signin_page.html
var signInPageHTML []byte

// SignInPath is where a sign-in link points: GET with ?code=.
const SignInPath = "/api/v1/sign-in"

// SignInPage is the web page that explains how to sign in, and why a link failed.
const SignInPage = "/sign-in"

const signInMessage = "Sign in with the link from `make signin`."

// signedIn refuses person-facing requests from anything but a signed-in
// browser. Agent containers can reach the API (over the stack's network and
// through host.docker.internal), so arriving isn't proof of being the person.
func (s *Server) signedIn(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !personFacing(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		if crossOriginWrite(r) {
			writeError(w, http.StatusForbidden, api.Forbidden, "cross-origin writes are refused", "")
			return
		}
		if s.AnonymousAPI {
			next.ServeHTTP(w, r)
			return
		}
		if bearer := companionBearerToken(r); bearer != "" {
			ok, err := companion.ValidDeviceToken(r.Context(), s.Q, bearer)
			if err != nil {
				s.Log.Error("companion device token lookup", "err", err)
				writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
				return
			}
			if !ok {
				writeError(w, http.StatusUnauthorized, api.Unauthenticated, "paired device token is invalid or revoked", "")
				return
			}
			next.ServeHTTP(w, r)
			return
		}
		var token string
		if c, err := r.Cookie(auth.SessionCookie); err == nil {
			token = c.Value
		}
		ok, err := auth.ValidSession(r.Context(), s.Q, token)
		if err != nil {
			s.Log.Error("browser session lookup", "err", err)
			writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
			return
		}
		if !ok {
			writeError(w, http.StatusUnauthorized, api.Unauthenticated, signInMessage, "")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// crossOriginWrite reports a state-changing request a browser made for
// another origin. SameSite=Strict stops other sites, but not other origins on
// the same site: a playground is served from this host on another port, runs
// code an agent wrote, and the browser sends it the session cookie. Browsers
// mark the request's origin in Sec-Fetch-Site; callers that don't send it
// (curl, the CLI, agents) aren't browsers being driven by a page.
func crossOriginWrite(r *http.Request) bool {
	switch r.Method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	}
	site := r.Header.Get("Sec-Fetch-Site")
	return site != "" && site != "same-origin" && site != "none"
}

// signIn spends a sign-in link's code on a session cookie and sends the
// browser into the app. A bad link lands on the sign-in page instead.
func (s *Server) signIn(w http.ResponseWriter, r *http.Request) {
	token, err := auth.RedeemSignInCode(r.Context(), s.Q, r.URL.Query().Get("code"))
	if errors.Is(err, auth.ErrBadSignInCode) {
		http.Redirect(w, r, SignInPage+"?error=invalid", http.StatusSeeOther)
		return
	}
	if err != nil {
		s.Log.Error("sign in", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}
	setSessionCookie(w, r, token)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// signInPage serves the embedded static HTML page at GET /sign-in so headless
// and browser sign-in flows work without a separate web SPA bundle.
func (s *Server) signInPage(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(signInPageHTML)
}

func setSessionCookie(w http.ResponseWriter, r *http.Request, token string) {
	http.SetCookie(w, &http.Cookie{
		Name:     auth.SessionCookie,
		Value:    token,
		Path:     "/",
		Expires:  time.Now().Add(auth.SessionTTL),
		HttpOnly: true,
		// Strict: every API call is a same-origin fetch, and no other site
		// should be able to make the browser send it.
		SameSite: http.SameSiteStrictMode,
		Secure:   r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https",
	})
}
