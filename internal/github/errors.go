package github

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/undont/differ.nvim/internal/protocol"
)

// the github package is the single producer of mapped I/O codes (auth, not_found,
// rate_limited, network). everything funnels through mapHTTP / mapGraphQL so the
// closed set is enforced in one place.

// restErrorBody is GitHub's REST error envelope; its message is safe to surface
// (it never contains the token, which lives only in request headers).
type restErrorBody struct {
	Message string `json:"message"`
}

// mapHTTP turns a REST response into a protocol.Error, or nil when the status is 2xx.
// a transport error never reaches here, it's handled by the caller
func mapHTTP(resp *http.Response, body []byte) *protocol.Error {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}

	msg := githubMessage(body, resp.Status)
	switch resp.StatusCode {
	case http.StatusUnauthorized:
		return protocol.NewError(protocol.CodeAuth, msg)
	case http.StatusForbidden:
		if ra, ok := rateLimited(resp); ok {
			return protocol.RateLimited(msg, ra)
		}
		if secondaryLimit(msg) {
			return protocol.RateLimited(msg, 0)
		}
		return protocol.NewError(protocol.CodeAuth, msg)
	case http.StatusTooManyRequests:
		// a 429 is a rate limit by definition, so only the hint is of interest
		ra, _ := rateLimited(resp)
		return protocol.RateLimited(msg, ra)
	case http.StatusNotFound:
		return protocol.NewError(protocol.CodeNotFound, msg)
	// every write goes through graphql, so REST is GETs only
	// kept here defensively in case any writes via REST get added in the future
	case http.StatusConflict:
		return protocol.NewError(protocol.CodeConflict, msg)
	case http.StatusUnprocessableEntity:
		return protocol.NewError(protocol.CodeBadRequest, msg)
	default:
		// 5xx and any other unexpected status: internal, real status in the message.
		return protocol.NewError(protocol.CodeInternal, msg)
	}
}

// rateLimited returns the retry-after hint in seconds (0 when there is none) and
// whether the response is a rate limit or permissions denial.
func rateLimited(resp *http.Response) (int, bool) {
	if v := resp.Header.Get("Retry-After"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n, true
		}
	}
	if resp.Header.Get("X-RateLimit-Remaining") == "0" {
		if reset := resp.Header.Get("X-RateLimit-Reset"); reset != "" {
			if epoch, err := strconv.ParseInt(reset, 10, 64); err == nil {
				if secs := int(epoch - time.Now().Unix()); secs > 0 {
					return secs, true
				}
			}
		}
		return 0, true
	}
	return 0, false
}

// a secondary rate limit arrives as a 403 carrying only a message: no X-RateLimit
// headers and usually no Retry-After, so rateLimited can't see it. left as an auth
// error it sends the user hunting for a scope they already have, when the answer is
// to wait. github has used both wordings; match either
func secondaryLimit(msg string) bool {
	l := strings.ToLower(msg)
	return strings.Contains(l, "secondary rate limit") || strings.Contains(l, "abuse detection")
}

func githubMessage(body []byte, fallback string) string {
	var b restErrorBody
	if err := json.Unmarshal(body, &b); err == nil && b.Message != "" {
		return b.Message
	}
	return fallback
}

// gqlError is one entry in a GraphQL {data, errors} response.
type gqlError struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

// mapGraphQL turns GraphQL top-level errors into a protocol.Error (nil if none).
// a 200 can still carry errors, so this runs even on HTTP success.
func mapGraphQL(errs []gqlError) *protocol.Error {
	if len(errs) == 0 {
		return nil
	}
	msg := errs[0].Message
	if msg == "" {
		msg = "graphql error"
	}
	switch errs[0].Type {
	case "NOT_FOUND":
		return protocol.NewError(protocol.CodeNotFound, msg)
	case "FORBIDDEN", "INSUFFICIENT_SCOPES":
		return protocol.NewError(protocol.CodeAuth, msg)
	case "RATE_LIMITED":
		return protocol.RateLimited(msg, 0)
	case "UNPROCESSABLE": // rejected input == BadRequest
		return protocol.NewError(protocol.CodeBadRequest, msg)
	default:
		return protocol.NewError(protocol.CodeInternal, msg)
	}
}
