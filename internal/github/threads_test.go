package github

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/undont/differ.nvim/internal/protocol"
)

func TestResolveThread(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		if !strings.Contains(body, "resolveReviewThread") || strings.Contains(body, "unresolveReviewThread") {
			t.Errorf("resolve=true must hit resolveReviewThread: %s", body)
		}
		if !strings.Contains(body, `"threadId":"PRT_1"`) {
			t.Errorf("thread id not threaded: %s", body)
		}
		return resp(200, `{"data":{"result":{"thread":{"isResolved":true}}}}`, nil), nil
	})
	rt, err := c.ResolveThread(context.Background(), "PRT_1", true)
	if err != nil {
		t.Fatal(err)
	}
	if !rt.Resolved {
		t.Errorf("want resolved, got %+v", rt)
	}
}

func TestUnresolveThread(t *testing.T) {
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if !strings.Contains(string(readBody(t, r)), "unresolveReviewThread") {
			t.Error("resolve=false must hit unresolveReviewThread")
		}
		return resp(200, `{"data":{"result":{"thread":{"isResolved":false}}}}`, nil), nil
	})
	rt, err := c.ResolveThread(context.Background(), "PRT_1", false)
	if err != nil {
		t.Fatal(err)
	}
	if rt.Resolved {
		t.Errorf("want unresolved, got %+v", rt)
	}
}

func TestResolveThreadMapsGraphQLError(t *testing.T) {
	c := newClient(func(*http.Request) (*http.Response, error) {
		return resp(200, `{"data":null,"errors":[{"type":"NOT_FOUND","message":"no such thread"}]}`, nil), nil
	})
	_, err := c.ResolveThread(context.Background(), "PRT_x", true)
	if codeOf(t, err) != protocol.CodeNotFound {
		t.Fatalf("want not_found, got %v", err)
	}
}

// a page that claims hasNextPage while handing back a null (or unmoved) endCursor
// drops the cursor from the variables, so the walk refetches page 1 and never ends.
// each loop has to stop on cursor progress, not on hasNextPage alone.
func TestGraphQLPaginationStopsWithoutCursorProgress(t *testing.T) {
	cases := []struct {
		name string
		// a null cursor stops on the first page; a repeated one only reveals itself on
		// the second, where the walk sees the cursor it already used
		wantCalls int
		body      func() string
		call      func(c *Client) error
	}{
		{
			name:      "threads/null cursor",
			wantCalls: 1,
			body: func() string {
				return `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],` +
					`"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}}`
			},
			call: func(c *Client) error {
				_, err := c.GetThreads(context.Background(), "acme", "widget", 7)
				return err
			},
		},
		{
			name:      "threads/stuck cursor",
			wantCalls: 2,
			body: func() string {
				return `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],` +
					`"pageInfo":{"hasNextPage":true,"endCursor":"SAME"}}}}}}`
			},
			call: func(c *Client) error {
				_, err := c.GetThreads(context.Background(), "acme", "widget", 7)
				return err
			},
		},
		{
			name:      "timeline/null cursor",
			wantCalls: 1,
			body: func() string {
				return `{"data":{"repository":{"pullRequest":{"comments":{"nodes":[],` +
					`"pageInfo":{"hasNextPage":true,"endCursor":null}},"reviews":{"nodes":[]}}}}}`
			},
			call: func(c *Client) error {
				_, err := c.GetTimeline(context.Background(), "acme", "widget", 7)
				return err
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			c := newClient(func(r *http.Request) (*http.Response, error) {
				calls++
				if calls > gqlMaxPages+1 {
					t.Fatalf("pagination did not terminate: %d requests", calls)
				}
				return resp(200, tc.body(), nil), nil
			})
			if err := tc.call(c); err != nil {
				t.Fatal(err)
			}
			if calls != tc.wantCalls {
				t.Errorf("want %d requests before the walk stops, got %d", tc.wantCalls, calls)
			}
		})
	}
}

// the cap is a literal in the query text and a const in Go; keep them in step
func TestThreadCommentsPage(t *testing.T) {
	want := fmt.Sprintf("comments(first: %d)", threadCommentsPage)
	if !strings.Contains(getThreadsQuery, want) {
		t.Errorf("getThreadsQuery does not ask for %q; threadCommentsPage has drifted", want)
	}
}

// a full page is the only overflow signal the connection gives
func TestGetThreadsReportsClippedComments(t *testing.T) {
	trackBodies(t)
	threadWith := func(n int) string {
		nodes := make([]string, 0, n)
		for i := 1; i <= n; i++ {
			nodes = append(nodes, fmt.Sprintf(
				`{"id":"NODE_%d","fullDatabaseId":"%d","author":{"login":"u"},"body":"c%d",`+
					`"createdAt":"t","state":"SUBMITTED","diffHunk":""}`, i, 1000+i, i))
		}
		return `{"id":"T","isResolved":false,"isOutdated":false,"path":"a.go","line":1,` +
			`"startLine":null,"originalLine":1,"diffSide":"RIGHT","startDiffSide":"RIGHT",` +
			`"comments":{"nodes":[` + strings.Join(nodes, ",") + `]}}`
	}

	cases := []struct {
		name  string
		count int
		want  bool
	}{
		{"short list is complete", 3, false},
		{"one short of the cap is complete", threadCommentsPage - 1, false},
		{"a full page is clipped", threadCommentsPage, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[` +
				threadWith(tc.count) + `],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`
			c := newClient(func(*http.Request) (*http.Response, error) {
				return resp(200, body, nil), nil
			})
			threads, err := c.GetThreads(context.Background(), "o", "r", 3)
			if err != nil {
				t.Fatal(err)
			}
			if len(threads) != 1 || len(threads[0].Comments) != tc.count {
				t.Fatalf("fixture wrong: %d threads, %d comments", len(threads), len(threads[0].Comments))
			}
			if threads[0].CommentsTruncated != tc.want {
				t.Errorf("comments_truncated = %v, want %v for %d comments",
					threads[0].CommentsTruncated, tc.want, tc.count)
			}
		})
	}
}

// the delete target has to be the thread's last comment even when the capped list stops
// short of it, which is the whole reason newestComment is selected separately
func TestGetThreadsNewestCommentPastTheCap(t *testing.T) {
	trackBodies(t)
	nodes := make([]string, 0, threadCommentsPage)
	for i := 1; i <= threadCommentsPage; i++ {
		nodes = append(nodes, fmt.Sprintf(
			`{"id":"NODE_%d","fullDatabaseId":"%d","author":{"login":"u"},"body":"c%d",`+
				`"createdAt":"t","state":"SUBMITTED","diffHunk":""}`, i, 1000+i, i))
	}
	body := `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
      {"id":"T","isResolved":false,"isOutdated":false,"path":"a.go","line":1,
       "startLine":null,"originalLine":1,"diffSide":"RIGHT","startDiffSide":"RIGHT",
       "comments":{"nodes":[` + strings.Join(nodes, ",") + `]},
       "newestComment":{"nodes":[{"id":"NODE_101","body":"the newest one"}]}}
    ],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`
	c := newClient(func(*http.Request) (*http.Response, error) { return resp(200, body, nil), nil })
	threads, err := c.GetThreads(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	got := threads[0]
	if !got.CommentsTruncated || len(got.Comments) != threadCommentsPage {
		t.Fatalf("fixture wrong: truncated=%v comments=%d", got.CommentsTruncated, len(got.Comments))
	}
	if got.Comments[len(got.Comments)-1].NodeID != "NODE_100" {
		t.Fatalf("the capped list should still end at the cap: %s", got.Comments[len(got.Comments)-1].NodeID)
	}
	if got.NewestComment == nil || got.NewestComment.NodeID != "NODE_101" {
		t.Errorf("newest comment = %+v, want NODE_101", got.NewestComment)
	}
	if got.NewestComment.Body != "the newest one" {
		t.Errorf("newest comment body = %q", got.NewestComment.Body)
	}
}

// a thread always has a root comment, but a malformed page must not panic
func TestGetThreadsNewestCommentAbsent(t *testing.T) {
	trackBodies(t)
	body := `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
      {"id":"T","isResolved":false,"isOutdated":false,"path":"a.go","line":1,
       "startLine":null,"originalLine":1,"diffSide":"RIGHT","startDiffSide":"RIGHT",
       "comments":{"nodes":[]},"newestComment":{"nodes":[]}}
    ],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`
	c := newClient(func(*http.Request) (*http.Response, error) { return resp(200, body, nil), nil })
	threads, err := c.GetThreads(context.Background(), "o", "r", 3)
	if err != nil {
		t.Fatal(err)
	}
	if threads[0].NewestComment != nil {
		t.Errorf("want nil newest comment, got %+v", threads[0].NewestComment)
	}
}
