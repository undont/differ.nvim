// Package github is the sidecar's I/O boundary: the only package that talks to
// GitHub. it takes an injected *http.Client so tests swap a fake RoundTripper and
// never hit the network. all failures are mapped to the closed protocol code
// set (errors.go); the token never leaves this package.
package github

import (
	"log/slog"
	"net/http"
	"sync"
	"time"
)

const (
	defaultREST = "https://api.github.com"
	defaultGQL  = "https://api.github.com/graphql"
	apiVersion  = "2022-11-28"
)

// Client talks to GitHub over REST and raw GraphQL.
type Client struct {
	http     *http.Client
	token    string
	tokenErr error // resolution failure (gh_missing/auth), surfaced on authed calls
	log      *slog.Logger
	restURL  string
	gqlURL   string

	mu     sync.Mutex
	viewer string // memoised authenticated login, for list_prs filtering

	cache *cache
}

// New builds a client. hc is injectable for tests; nil uses a sane default with a
// timeout. token is the resolved GitHub token (see ResolveToken); tokenErr is the
// resolution failure, if any, returned to the caller on the first authed request
// so the precise gh_missing/auth code reaches the client instead of a bare 401.
// log receives one debug line per GitHub call; nil discards them.
func New(hc *http.Client, token string, tokenErr error, log *slog.Logger) *Client {
	if hc == nil {
		hc = &http.Client{Timeout: 30 * time.Second}
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	return &Client{http: hc, token: token, tokenErr: tokenErr, log: log, restURL: defaultREST, gqlURL: defaultGQL, cache: newCache()}
}

// ClearCache flushes the blob cache, behind :Differ cache clear.
func (c *Client) ClearCache() { c.cache.clearAll() }
