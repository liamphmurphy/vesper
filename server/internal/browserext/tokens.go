package browserext

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ErrBadToken covers a missing, malformed or replaced extension token.
var ErrBadToken = errors.New("browserext: invalid extension token")

// tokenPrefix marks the extension's tokens so one pasted somewhere is
// recognisable (and a session token is never mistaken for one).
const tokenPrefix = "vbx_"

func hashToken(t string) []byte {
	h := sha256.Sum256([]byte(t))
	return h[:]
}

// MintToken makes the person's extension token, replacing the last one. The
// plaintext is returned once; only its hash is stored.
func MintToken(ctx context.Context, q *store.Queries, userID uuid.UUID) (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := tokenPrefix + base64.RawURLEncoding.EncodeToString(buf)
	return token, q.SetBrowserExtensionToken(ctx, store.SetBrowserExtensionTokenParams{UserID: userID, TokenHash: hashToken(token)})
}

// TokenUser returns the person an Authorization header's token belongs to.
func TokenUser(ctx context.Context, q *store.Queries, header string) (uuid.UUID, error) {
	token, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || !strings.HasPrefix(token, tokenPrefix) || len(token) > 128 {
		return uuid.Nil, ErrBadToken
	}
	id, err := q.BrowserExtensionTokenUser(ctx, hashToken(token))
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrBadToken
	}
	return id, err
}
