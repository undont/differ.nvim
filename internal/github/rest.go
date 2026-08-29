package github

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"time"

	"github.com/undont/differ.nvim/internal/protocol"
)

const maxResponse = 32 * 1024 * 1024 // bound a single response body

// send performs req and returns the response alongside its already-read, already-
// closed body. the transport error is handled on its own, before anything else, so
// `defer Close` is registered on every path that has a body to close: a non-2xx must
// not leak the connection, which is exactly when the leak compounds (a wall of 403s
// at a rate limit, a 401 on an expired token). the status then maps with the body in
// hand, so GitHub's own message survives instead of a bare status line. resp is
// returned even on a mapped error, for callers that special-case a status; its body
// is spent, so only headers and the status line are readable from it
func (c *Client) send(req *http.Request) (*http.Response, []byte, error) {
	start := time.Now()
	resp, err := c.http.Do(req)
	if err != nil {
		// URL.Redacted, not URL.String: the only secret a URL can carry is userinfo,
		// and the token itself rides in a header that is never logged
		c.log.Debug("github call failed", "verb", req.Method, "url", req.URL.Redacted(),
			"ms", time.Since(start).Milliseconds(), "err", err)
		return nil, nil, protocol.NewError(protocol.CodeNetwork, "network error: "+err.Error())
	}
	defer func() { _ = resp.Body.Close() }()
	// the single choke point for REST and GraphQL alike, so this one line accounts
	// for every call the sidecar makes, and for the budget it spends doing it
	c.log.Debug("github call", "verb", req.Method, "url", req.URL.Redacted(),
		"status", resp.StatusCode, "ms", time.Since(start).Milliseconds(),
		"ratelimit_remaining", resp.Header.Get("X-RateLimit-Remaining"))

	body, rerr := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
	// the status outranks a truncated read: a 403 that also failed to read is still a
	// 403, and its message is the useful half
	if perr := mapHTTP(resp, body); perr != nil {
		return resp, body, perr
	}
	if rerr != nil {
		return resp, body, protocol.NewError(protocol.CodeNetwork, "reading response: "+rerr.Error())
	}
	return resp, body, nil
}

// getJSON does an authenticated REST GET, maps the status to a protocol code, and
// decodes the body into out.
func (c *Client) getJSON(ctx context.Context, rawURL string, out any) error {
	if c.tokenErr != nil {
		return c.tokenErr
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}
	c.setRESTHeaders(req)

	_, body, err := c.send(req)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(body, out); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding response: "+err.Error())
	}
	return nil
}

// getPaged follows the REST Link rel="next" header, decoding each page into a
// []T and appending. it caps pages defensively so a runaway never spins forever.
func getPaged[T any](ctx context.Context, c *Client, rawURL string) ([]T, error) {
	if c.tokenErr != nil {
		return nil, c.tokenErr
	}
	const maxPages = 100
	var all []T
	for page := 0; rawURL != "" && page < maxPages; page++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return nil, protocol.NewError(protocol.CodeInternal, err.Error())
		}
		c.setRESTHeaders(req)

		resp, body, err := c.send(req)
		if err != nil {
			return nil, err
		}
		var pageItems []T
		if err := json.Unmarshal(body, &pageItems); err != nil {
			return nil, protocol.NewError(protocol.CodeInternal, "decoding response: "+err.Error())
		}
		all = append(all, pageItems...)
		rawURL = nextLink(resp.Header.Get("Link"))
	}
	return all, nil
}

func (c *Client) setRESTHeaders(req *http.Request) {
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)
}

var linkNextRe = regexp.MustCompile(`<([^>]+)>\s*;\s*rel="next"`)

// nextLink extracts the rel="next" URL from a REST Link header, "" if absent.
func nextLink(header string) string {
	m := linkNextRe.FindStringSubmatch(header)
	if len(m) == 2 {
		return m[1]
	}
	return ""
}

// query builds an escaped query string.
func query(kv map[string]string) string {
	v := url.Values{}
	for k, val := range kv {
		v.Set(k, val)
	}
	return v.Encode()
}
