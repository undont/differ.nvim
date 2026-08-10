package github

import (
	"strconv"
	"sync"
)

// cache is the sidecar's in-process memo. blobs are keyed by commit sha and
// live forever (a path's bytes at a sha are immutable, and prRefs always resolves a
// fresh sha so a moved head simply misses); threads are keyed per PR and flushed
// wholesale by the review mutations. one mutex guards all of it, since the server
// fans requests across goroutines.
type cache struct {
	mu      sync.Mutex
	blobs   map[string]FileBlob
	threads map[string][]Thread
	// bumped on every thread invalidation. a paginating walk captures it up front and
	// hands it back, so a snapshot assembled before a mutation can't re-seed the cache
	// after it.
	threadGen uint64
}

func newCache() *cache {
	return &cache{blobs: map[string]FileBlob{}, threads: map[string][]Thread{}}
}

func blobKey(owner, repo, ref, path string) string {
	return owner + "/" + repo + "/" + ref + "/" + path
}

func threadKey(owner, repo string, number int) string {
	return owner + "/" + repo + "/" + strconv.Itoa(number)
}

func (c *cache) blob(key string) (FileBlob, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	b, ok := c.blobs[key]
	return b, ok
}

func (c *cache) putBlob(key string, b FileBlob) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.blobs[key] = b
}

func (c *cache) thread(key string) ([]Thread, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	t, ok := c.threads[key]
	return t, ok
}

// threadGeneration is captured before a thread walk starts and passed to putThreads.
func (c *cache) threadGeneration() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.threadGen
}

// putThreads stores a walk's result unless the cache was invalidated while it ran, in
// which case the snapshot predates the mutation and is dropped rather than cached.
func (c *cache) putThreads(key string, t []Thread, gen uint64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.threadGen {
		return
	}
	c.threads[key] = t
}

// invalidateThreads flushes every PR's thread cache. the review mutations carry only
// a thread or review node id, not the PR coords, so the whole map is cleared rather
// than one key; the cache is small and these mutations are infrequent.
func (c *cache) invalidateThreads() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.threads)
	c.threadGen++
}

func (c *cache) clearAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.blobs)
	clear(c.threads)
	c.threadGen++
}
