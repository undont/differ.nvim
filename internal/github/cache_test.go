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
		if _, err := c.GetFileVersions(context.Background(), "o", "r", 3, "a.go", "", "", ""); err != nil {
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
	if _, err := c.GetFileVersions(ctx, "o", "r", 3, "a.go", "", "", ""); err != nil {
		t.Fatal(err)
	}
	c.ClearCache()
	if _, err := c.GetFileVersions(ctx, "o", "r", 3, "a.go", "", "", ""); err != nil {
		t.Fatal(err)
	}
	if contentCalls.Load() != 4 {
		t.Errorf("clear should force a refetch: want 4 content calls, got %d", contentCalls.Load())
	}
}

// threads are the client's to keep fresh, so every walk reads through to GitHub.
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

// the real cache with a smaller cap, so eviction trips without allocating 64MB
func smallCache(limit int) *cache {
	c := newCache()
	c.limit = limit
	return c
}

func put(c *cache, key string, n int) {
	c.putBlob(key, FileBlob{Content: strings.Repeat("x", n)})
}

// blobs never expire (immutable per sha), so the cap is the only thing bounding them.
func TestBlobCacheEvictsLeastRecentlyUsed(t *testing.T) {
	c := smallCache(350) // three 100-byte entries fit (keys are charged too), four don't
	put(c, "a", 100)
	put(c, "b", 100)
	put(c, "c", 100)

	// read a, so b is now the coldest entry rather than a
	if _, ok := c.blob("a"); !ok {
		t.Fatal("a should still be cached")
	}
	put(c, "d", 100) // pushes past the cap: the coldest entry goes

	if _, ok := c.blob("b"); ok {
		t.Error("b was least-recently-used and should have been evicted")
	}
	for _, key := range []string{"a", "c", "d"} {
		if _, ok := c.blob(key); !ok {
			t.Errorf("%s should have survived eviction", key)
		}
	}
	if c.bytes > c.limit {
		t.Errorf("cache holds %d bytes, over its %d cap", c.bytes, c.limit)
	}
}

// the charge must follow the entry, or a re-put leaks the accounting.
func TestBlobCacheAccountsForReplacedEntries(t *testing.T) {
	c := smallCache(1000)
	put(c, "a", 100)
	put(c, "a", 400)
	if want := blobSize("a", FileBlob{Content: strings.Repeat("x", 400)}); c.bytes != want {
		t.Errorf("want %d bytes charged after the replace, got %d", want, c.bytes)
	}
	if c.lru.Len() != 1 {
		t.Errorf("a replace should reuse the entry, got %d", c.lru.Len())
	}
}

// an entry larger than the whole cap must not wedge the eviction loop.
func TestBlobCacheSurvivesAnOversizedEntry(t *testing.T) {
	c := smallCache(50)
	put(c, "big", 500)
	if c.lru.Len() != 0 || c.bytes != 0 {
		t.Errorf("an entry over the cap should not be retained, got %d entries / %d bytes", c.lru.Len(), c.bytes)
	}
	put(c, "small", 10) // the cache still works afterwards
	if _, ok := c.blob("small"); !ok {
		t.Error("the cache should still hold a fitting entry")
	}
}

func TestClearCacheResetsTheCharge(t *testing.T) {
	c := smallCache(1000)
	put(c, "a", 100)
	c.clearAll()
	if c.bytes != 0 || c.lru.Len() != 0 || len(c.blobs) != 0 {
		t.Errorf("clear should empty the cache, got %d bytes / %d entries / %d keys", c.bytes, c.lru.Len(), len(c.blobs))
	}
}
