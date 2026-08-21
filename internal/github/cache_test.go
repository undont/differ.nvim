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

// threads are not memoised in the sidecar: freshness is the client's clock, so every
// get_threads reads through to GitHub rather than serving a list of unbounded age.
func TestThreadsAreNotCached(t *testing.T) {
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
	if calls != 2 {
		t.Errorf("want both walks to reach github, got %d requests", calls)
	}
}
