package github

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// blobs are immutable per sha, so a second get_file_versions serves the file bytes
// from cache; only the (uncached) ref lookup re-hits the network.
func TestBlobCacheServesContents(t *testing.T) {
	// atomic: get_file_versions fetches base and head concurrently, so both blob
	// requests land in this closure at once
	var refCalls, contentCalls atomic.Int64
	c := newClient(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.Contains(r.URL.Path, "/contents/"):
			contentCalls.Add(1)
			return resp(200, "file body", nil), nil
		case strings.HasSuffix(r.URL.Path, "/pulls/3"):
			refCalls.Add(1)
			return resp(200, `{"base":{"sha":"BASE"},"head":{"sha":"HEAD"}}`, nil), nil
		}
		t.Fatalf("unexpected path %s", r.URL.Path)
		return nil, nil
	})
	for range 2 {
		if _, err := c.GetFileVersions(context.Background(), "o", "r", 3, "a.go", "", ""); err != nil {
			t.Fatal(err)
		}
	}
	if contentCalls.Load() != 2 {
		t.Errorf("want 2 content fetches (base+head, once), got %d", contentCalls.Load())
	}
	if refCalls.Load() != 2 {
		t.Errorf("refs are not cached, want 2 lookups, got %d", refCalls.Load())
	}
}

func TestThreadCacheAndInvalidation(t *testing.T) {
	threadCalls := 0
	c := newClient(func(r *http.Request) (*http.Response, error) {
		body := string(readBody(t, r))
		switch {
		case strings.Contains(body, "GetThreads"):
			threadCalls++
			return resp(200, `{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":""}}}}}}`, nil), nil
		case strings.Contains(body, "resolveReviewThread"):
			return resp(200, `{"data":{"result":{"thread":{"isResolved":true}}}}`, nil), nil
		}
		t.Fatalf("unexpected op: %s", body)
		return nil, nil
	})
	ctx := context.Background()
	for range 2 {
		if _, err := c.GetThreads(ctx, "o", "r", 3); err != nil {
			t.Fatal(err)
		}
	}
	if threadCalls != 1 {
		t.Fatalf("second get_threads should be cached, got %d fetches", threadCalls)
	}
	if _, err := c.ResolveThread(ctx, "PRT_1", true); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetThreads(ctx, "o", "r", 3); err != nil {
		t.Fatal(err)
	}
	if threadCalls != 2 {
		t.Errorf("resolve must invalidate the thread cache, got %d fetches", threadCalls)
	}
}

func TestClearCacheFlushesBlobs(t *testing.T) {
	var contentCalls atomic.Int64
	c := newClient(func(r *http.Request) (*http.Response, error) {
		if strings.Contains(r.URL.Path, "/contents/") {
			contentCalls.Add(1)
			return resp(200, "body", nil), nil
		}
		return resp(200, `{"base":{"sha":"BASE"},"head":{"sha":"HEAD"}}`, nil), nil
	})
	ctx := context.Background()
	if _, err := c.GetFileVersions(ctx, "o", "r", 3, "a.go", "", ""); err != nil {
		t.Fatal(err)
	}
	c.ClearCache()
	if _, err := c.GetFileVersions(ctx, "o", "r", 3, "a.go", "", ""); err != nil {
		t.Fatal(err)
	}
	if contentCalls.Load() != 4 {
		t.Errorf("clear should force a refetch: want 4 content calls, got %d", contentCalls.Load())
	}
}

// a mutation invalidating the thread cache mid-pagination must win: the walk in flight
// assembled its snapshot before the change, so caching it would resurrect the pre-
// mutation list and hide the new comment for the life of the session.
func TestInvalidateDuringWalkDropsTheStaleSnapshot(t *testing.T) {
	var c *Client
	c = newClient(func(*http.Request) (*http.Response, error) {
		// invalidate while the walk is mid-flight, as a concurrent mutation would
		c.cache.invalidateThreads()
		return resp(200, `{"data":{"repository":{"pullRequest":{"reviewThreads":{`+
			`"nodes":[{"id":"th_1","path":"a.txt","comments":{"nodes":[]}}],`+
			`"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}`, nil), nil
	})

	got, err := c.GetThreads(context.Background(), "acme", "widget", 7)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("the caller still gets the walk's result, got %d", len(got))
	}
	if _, ok := c.cache.thread(threadKey("acme", "widget", 7)); ok {
		t.Error("a snapshot assembled before the invalidation must not be cached")
	}
}

// the ordinary path still caches, so the guard hasn't disabled the memo outright
func TestThreadWalkCachesWhenNothingInvalidates(t *testing.T) {
	calls := 0
	c := newClient(func(*http.Request) (*http.Response, error) {
		calls++
		return resp(200, `{"data":{"repository":{"pullRequest":{"reviewThreads":{`+
			`"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}`, nil), nil
	})
	for range 2 {
		if _, err := c.GetThreads(context.Background(), "acme", "widget", 7); err != nil {
			t.Fatal(err)
		}
	}
	if calls != 1 {
		t.Errorf("want the second call served from cache, got %d requests", calls)
	}
}
