package github

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/undont/differ.nvim/internal/protocol"
)

// rtFunc is a fake http.RoundTripper: every request is answered by f, so tests
// never touch the network.
type rtFunc func(*http.Request) (*http.Response, error)

func (f rtFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func newClient(f rtFunc) *Client {
	return New(&http.Client{Transport: f}, "test-token", nil, nil)
}

// bodies tallies every response body resp() hands out against every Close() on one.
// wrapping bodies in io.NopCloser made a leak structurally invisible: the client
// could return before closing and every test still passed. atomic because the
// concurrent-blob path hands out two bodies from two goroutines
var bodies struct{ opened, closed atomic.Int64 }

type countingBody struct{ io.Reader }

func (countingBody) Close() error { bodies.closed.Add(1); return nil }

// TestMain is the package-wide net: any test that leaves a body open fails the
// package, whether or not it went looking. trackBodies localises it to one test
func TestMain(m *testing.M) {
	code := m.Run()
	if opened, closed := bodies.opened.Load(), bodies.closed.Load(); code == 0 && opened != closed {
		fmt.Fprintf(os.Stderr, "response body leak: %d handed out, %d closed\n", opened, closed)
		code = 1
	}
	os.Exit(code)
}

// trackBodies fails t if any body handed out during it outlives it.
func trackBodies(t *testing.T) {
	t.Helper()
	opened, closed := bodies.opened.Load(), bodies.closed.Load()
	t.Cleanup(func() {
		got, want := bodies.closed.Load()-closed, bodies.opened.Load()-opened
		if got != want {
			t.Errorf("%d of %d response bodies closed", got, want)
		}
	})
}

func resp(status int, body string, headers map[string]string) *http.Response {
	h := http.Header{}
	for k, v := range headers {
		h.Set(k, v)
	}
	bodies.opened.Add(1)
	return &http.Response{
		StatusCode: status,
		Status:     http.StatusText(status),
		Body:       countingBody{strings.NewReader(body)},
		Header:     h,
	}
}

func perrOf(t *testing.T, err error) *protocol.Error {
	t.Helper()
	var pe *protocol.Error
	if !errors.As(err, &pe) {
		t.Fatalf("want *protocol.Error, got %T: %v", err, err)
	}
	return pe
}

func codeOf(t *testing.T, err error) string {
	t.Helper()
	return perrOf(t, err).Code
}

// ── list_prs ────────────────────────────────────────────────────────────────

const pullsPage = `[
  {"number":1,"title":"first","user":{"login":"alice"},"head":{"ref":"feat-a"},"updated_at":"2026-01-01","draft":false,"requested_reviewers":[{"login":"bob"}]},
  {"number":2,"title":"second","user":{"login":"bob"},"head":{"ref":"feat-b"},"updated_at":"2026-01-02","draft":true,"requested_reviewers":[{"login":"alice"}]}
]`

func TestListPRsOpen(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if !strings.HasSuffix(r.URL.Path, "/pulls") {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("missing bearer auth")
		}
		return resp(200, pullsPage, nil), nil
	})
	prs, err := c.ListPRs(context.Background(), "o", "r", "open")
	if err != nil {
		t.Fatal(err)
	}
	if len(prs) != 2 || prs[0].Number != 1 || prs[0].HeadRef != "feat-a" || !prs[1].Draft {
		t.Fatalf("bad result: %+v", prs)
	}
}

func TestListPRsMine(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/user"):
			return resp(200, `{"login":"alice"}`, nil), nil
		case strings.HasSuffix(r.URL.Path, "/pulls"):
			return resp(200, pullsPage, nil), nil
		}
		t.Fatalf("unexpected path %s", r.URL.Path)
		return nil, nil
	})
	prs, err := c.ListPRs(context.Background(), "o", "r", "mine")
	if err != nil {
		t.Fatal(err)
	}
	if len(prs) != 1 || prs[0].Author != "alice" {
		t.Fatalf("mine should keep only alice's PRs, got %+v", prs)
	}
}

func TestListPRsReviewRequested(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/user") {
			return resp(200, `{"login":"alice"}`, nil), nil
		}
		return resp(200, pullsPage, nil), nil
	})
	prs, err := c.ListPRs(context.Background(), "o", "r", "review_requested")
	if err != nil {
		t.Fatal(err)
	}
	// only PR #2 requests review from alice.
	if len(prs) != 1 || prs[0].Number != 2 {
		t.Fatalf("review_requested filter wrong, got %+v", prs)
	}
}

func TestListPRsBadFilter(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		t.Fatal("must not hit the network for a bad filter")
		return nil, nil
	})
	_, err := c.ListPRs(context.Background(), "o", "r", "bogus")
	if codeOf(t, err) != protocol.CodeBadRequest {
		t.Fatalf("want bad_request, got %v", err)
	}
}

func TestListPRsPagination(t *testing.T) {
	page1 := `[{"number":1,"title":"a","user":{"login":"x"},"head":{"ref":"r1"},"updated_at":"d","draft":false}]`
	page2 := `[{"number":2,"title":"b","user":{"login":"y"},"head":{"ref":"r2"},"updated_at":"d","draft":false}]`
	calls := 0
	c := newClient(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			return resp(200, page1, map[string]string{
				"Link": `<https://api.github.com/repos/o/r/pulls?page=2>; rel="next"`,
			}), nil
		}
		return resp(200, page2, nil), nil
	})
	prs, err := c.ListPRs(context.Background(), "o", "r", "open")
	if err != nil {
		t.Fatal(err)
	}
	if calls != 2 || len(prs) != 2 {
		t.Fatalf("want 2 pages / 2 PRs, got calls=%d prs=%d", calls, len(prs))
	}
}

// ── get_pr ──────────────────────────────────────────────────────────────────

const getPRGraphQL = `{"data":{"repository":{"pullRequest":{
  "title":"T","body":"B","url":"https://github.com/o/r/pull/3","state":"OPEN","isDraft":false,
  "mergeable":"MERGEABLE","baseRefOid":"basesha","headRefOid":"headsha","headRefName":"feature",
  "author":{"login":"alice"},
  "files":{"nodes":[
    {"path":"a.go","viewerViewedState":"VIEWED"},
    {"path":"b.go","viewerViewedState":"UNVIEWED"}
  ],"pageInfo":{"hasNextPage":false,"endCursor":""}}
}}}}`

const getPRFilesREST = `[
  {"filename":"a.go","status":"modified","additions":3,"deletions":1,"previous_filename":""},
  {"filename":"b.go","status":"renamed","additions":0,"deletions":0,"previous_filename":"old_b.go"},
  {"filename":"c.go","status":"added","additions":10,"deletions":0,"previous_filename":""}
]`

func TestGetPR(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/graphql"):
			return resp(200, getPRGraphQL, nil), nil
		case strings.Contains(r.URL.Path, "/pulls/3/files"):
			return resp(200, getPRFilesREST, nil), nil
		}
		t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		return nil, nil
	})
	pr, err := c.GetPR(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if pr.BaseSHA != "basesha" || pr.HeadSHA != "headsha" || pr.HeadRef != "feature" {
		t.Errorf("bad meta: %+v", pr)
	}
	if pr.Author != "alice" || pr.Mergeable != "MERGEABLE" || pr.State != "OPEN" {
		t.Errorf("bad meta fields: %+v", pr)
	}
	if len(pr.Files) != 3 {
		t.Fatalf("want 3 files, got %d", len(pr.Files))
	}
	// REST is authoritative for the list + rename info; GraphQL supplies viewed state.
	byPath := map[string]PRFile{}
	for _, f := range pr.Files {
		byPath[f.Path] = f
	}
	if byPath["a.go"].ViewedState != "VIEWED" {
		t.Errorf("a.go viewed = %q", byPath["a.go"].ViewedState)
	}
	if byPath["b.go"].PreviousPath != "old_b.go" || byPath["b.go"].Status != "renamed" {
		t.Errorf("b.go rename info wrong: %+v", byPath["b.go"])
	}
	// c.go has no GraphQL viewed node → defaults to UNVIEWED.
	if byPath["c.go"].ViewedState != "UNVIEWED" {
		t.Errorf("c.go viewed default = %q, want UNVIEWED", byPath["c.go"].ViewedState)
	}
}

func TestGetPRGraphQLFilesPagination(t *testing.T) {
	page1 := `{"data":{"repository":{"pullRequest":{
      "title":"T","author":{"login":"a"},"baseRefOid":"b","headRefOid":"h","headRefName":"f","state":"OPEN","mergeable":"MERGEABLE",
      "files":{"nodes":[{"path":"a.go","viewerViewedState":"VIEWED"}],"pageInfo":{"hasNextPage":true,"endCursor":"CUR"}}}}}}`
	page2 := `{"data":{"repository":{"pullRequest":{
      "files":{"nodes":[{"path":"b.go","viewerViewedState":"DISMISSED"}],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`
	gqlCalls := 0
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if r.Method == http.MethodPost {
			gqlCalls++
			if gqlCalls == 1 {
				return resp(200, page1, nil), nil
			}
			return resp(200, page2, nil), nil
		}
		return resp(200, `[{"filename":"a.go","status":"modified"},{"filename":"b.go","status":"modified"}]`, nil), nil
	})
	pr, err := c.GetPR(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if gqlCalls != 2 {
		t.Fatalf("want 2 graphql calls for paged files, got %d", gqlCalls)
	}
	byPath := map[string]PRFile{}
	for _, f := range pr.Files {
		byPath[f.Path] = f
	}
	if byPath["b.go"].ViewedState != "DISMISSED" {
		t.Errorf("second-page viewed state lost: %+v", byPath["b.go"])
	}
}

// ── error mapping ───────────────────────────────────────────────────────────

// the message half matters as much as the code: "403 Forbidden" sends the user
// looking for a missing scope, where GitHub's own body says which secondary limit
// they hit or which line of the diff a 422 rejected
func TestErrorMappingTable(t *testing.T) {
	cases := []struct {
		name    string
		status  int
		body    string
		headers map[string]string
		want    string
		wantMsg string
	}{
		{"unauthorized", 401, `{"message":"Bad credentials"}`, nil, protocol.CodeAuth, "Bad credentials"},
		{"forbidden_perms", 403, `{"message":"Resource not accessible by integration"}`, nil, protocol.CodeAuth, "Resource not accessible by integration"},
		{"forbidden_ratelimit", 403, `{"message":"API rate limit exceeded"}`, map[string]string{"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "9999999999"}, protocol.CodeRateLimited, "API rate limit exceeded"},
		{"forbidden_secondary", 403, `{"message":"You have exceeded a secondary rate limit"}`, nil, protocol.CodeRateLimited, "You have exceeded a secondary rate limit"},
		{"forbidden_abuse", 403, `{"message":"You have triggered an abuse detection mechanism"}`, nil, protocol.CodeRateLimited, "You have triggered an abuse detection mechanism"},
		{"too_many", 429, `{"message":"slow down"}`, map[string]string{"Retry-After": "30"}, protocol.CodeRateLimited, "slow down"},
		{"not_found", 404, `{"message":"Not Found"}`, nil, protocol.CodeNotFound, "Not Found"},
		{"conflict", 409, `{"message":"conflict"}`, nil, protocol.CodeConflict, "conflict"},
		{"unprocessable", 422, `{"message":"Validation Failed: line must be part of the diff"}`, nil, protocol.CodeBadRequest, "Validation Failed: line must be part of the diff"},
		{"server", 500, `{"message":"boom"}`, nil, protocol.CodeInternal, "boom"},
		// no envelope to read: the status line is all there is to say
		{"empty_body", 404, ``, nil, protocol.CodeNotFound, http.StatusText(http.StatusNotFound)},
		{"non_json_body", 502, `<html>bad gateway</html>`, nil, protocol.CodeInternal, http.StatusText(http.StatusBadGateway)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			trackBodies(t)
			c := newClient(func(*http.Request) (*http.Response, error) {
				return resp(tc.status, tc.body, tc.headers), nil
			})
			pe := perrOf(t, c.getJSON(context.Background(), c.restURL+"/x", nil))
			if pe.Code != tc.want {
				t.Fatalf("status %d → %q, want %q", tc.status, pe.Code, tc.want)
			}
			if pe.Message != tc.wantMsg {
				t.Fatalf("status %d message = %q, want %q", tc.status, pe.Message, tc.wantMsg)
			}
		})
	}
}

// a permissions 403 and a secondary-limit 403 are the same status with the same
// (absent) headers; only the message tells them apart, so this is the case that
// dies first if the body ever stops reaching mapHTTP again
func TestSecondaryRateLimitIsNotAnAuthError(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(403, `{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}`, nil), nil
	})
	err := c.getJSON(context.Background(), c.restURL+"/x", nil)
	if got := codeOf(t, err); got != protocol.CodeRateLimited {
		t.Fatalf("secondary rate limit → %q, want rate_limited", got)
	}
}

// a mapped status must not skip the body's Close: every path through send has one
// registered, and each caller below reaches it differently (paged, graphql, the
// blob path with its own 404 special case)
func TestErrorPathsCloseTheBody(t *testing.T) {
	paths := map[string]func(*Client) error{
		"getJSON": func(c *Client) error {
			return c.getJSON(context.Background(), c.restURL+"/x", nil)
		},
		"getPaged": func(c *Client) error {
			_, err := getPaged[PRFile](context.Background(), c, c.restURL+"/x")
			return err
		},
		"graphql": func(c *Client) error {
			return c.graphql(context.Background(), "query{}", nil, nil)
		},
		"rawBlob": func(c *Client) error {
			_, err := c.rawBlob(context.Background(), "o", "r", "a.go", "sha")
			return err
		},
	}
	for name, call := range paths {
		t.Run(name, func(t *testing.T) {
			trackBodies(t)
			c := newClient(func(*http.Request) (*http.Response, error) {
				return resp(403, `{"message":"nope"}`, nil), nil
			})
			if err := call(c); err == nil {
				t.Fatal("want an error from a 403")
			}
		})
	}
}

// the connection is only reusable if the body was drained and closed; a real
// transport is the only thing that can prove it, so this one skips the fake
func TestRepeatedFailuresReuseTheConnection(t *testing.T) {
	var conns atomic.Int64
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"message":"nope"}`))
	}))
	srv.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			conns.Add(1)
		}
	}
	srv.Start()
	defer srv.Close()

	c := New(srv.Client(), "test-token", nil, nil)
	c.restURL = srv.URL
	for range 10 {
		if err := c.getJSON(context.Background(), c.restURL+"/x", nil); err == nil {
			t.Fatal("want an error from a 403")
		}
	}
	if n := conns.Load(); n != 1 {
		t.Fatalf("10 failing requests opened %d connections, want 1 (bodies unclosed)", n)
	}
}

func TestRetryAfterPropagates(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(429, `{"message":"slow"}`, map[string]string{"Retry-After": "30"}), nil
	})
	pe := perrOf(t, c.getJSON(context.Background(), c.restURL+"/x", nil))
	if pe.RetryAfter != 30 {
		t.Fatalf("want retry_after=30, got %+v", pe)
	}
}

func TestTransportErrorIsNetwork(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("dial tcp: connection refused")
	})
	err := c.getJSON(context.Background(), c.restURL+"/x", nil)
	if codeOf(t, err) != protocol.CodeNetwork {
		t.Fatalf("want network, got %v", err)
	}
}

func TestGraphQLErrorMapping(t *testing.T) {
	cases := []struct{ gqlType, want string }{
		{"NOT_FOUND", protocol.CodeNotFound},
		{"FORBIDDEN", protocol.CodeAuth},
		{"INSUFFICIENT_SCOPES", protocol.CodeAuth},
		{"RATE_LIMITED", protocol.CodeRateLimited},
		{"SOMETHING_ELSE", protocol.CodeInternal},
	}
	for _, tc := range cases {
		t.Run(tc.gqlType, func(t *testing.T) {
			body := `{"data":null,"errors":[{"type":"` + tc.gqlType + `","message":"x"}]}`
			c := newClient(func(*http.Request) (*http.Response, error) {
				return resp(200, body, nil), nil
			})
			_, err := c.GetPR(context.Background(), "o", "r", 3)
			if got := codeOf(t, err); got != tc.want {
				t.Fatalf("graphql %s → %q, want %q", tc.gqlType, got, tc.want)
			}
		})
	}
}

func TestTokenErrShortCircuits(t *testing.T) {
	want := protocol.NewError(protocol.CodeGHMissing, "no gh")
	c := New(&http.Client{Transport: rtFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("must not hit the network when token resolution failed")
		return nil, nil
	})}, "", want, nil)
	if _, err := c.ListPRs(context.Background(), "o", "r", "open"); codeOf(t, err) != protocol.CodeGHMissing {
		t.Fatalf("want gh_missing, got %v", err)
	}
	if _, err := c.GetPR(context.Background(), "o", "r", 1); codeOf(t, err) != protocol.CodeGHMissing {
		t.Fatalf("get_pr want gh_missing, got %v", err)
	}
}

func TestDebugTracesEveryCallWithoutLeakingTheToken(t *testing.T) {
	trackBodies(t)
	var buf bytes.Buffer
	log := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	c := New(&http.Client{Transport: rtFunc(func(*http.Request) (*http.Response, error) {
		return resp(200, `[]`, map[string]string{"X-RateLimit-Remaining": "4832"}), nil
	})}, "super-secret-token", nil, log)

	if _, err := c.ListPRs(context.Background(), "o", "r", "open"); err != nil {
		t.Fatalf("ListPRs: %v", err)
	}

	got := buf.String()
	if !strings.Contains(got, `msg="github call"`) || !strings.Contains(got, "status=200") {
		t.Errorf("the call was not traced:\n%s", got)
	}
	// the budget is half the reason for the line: a run of 403s is only legible
	// alongside what was left
	if !strings.Contains(got, "ratelimit_remaining=4832") {
		t.Errorf("rate limit was not traced:\n%s", got)
	}
	// logx's contract, and the whole reason send logs URL.Redacted rather than headers
	if strings.Contains(got, "super-secret-token") {
		t.Errorf("the token reached the log:\n%s", got)
	}
}

func TestNilLoggerDiscards(t *testing.T) {
	trackBodies(t)
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, `[]`, nil), nil
	})
	if _, err := c.ListPRs(context.Background(), "o", "r", "open"); err != nil {
		t.Fatalf("a nil logger must not panic: %v", err)
	}
}
