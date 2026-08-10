package github

import (
	"context"
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
