package github

import "sync"

// cache is the sidecar's in-process memo, and it holds blobs only. a path's bytes at a
// sha are immutable, so an entry never goes stale (prRefs always resolves a fresh sha,
// so a moved head simply misses). threads are deliberately not cached here: the client
// memoises them per session behind its own freshness clock, and a second copy down here
// would only add a window where a colleague's comment is already fetched but not yet
// visible. one mutex guards the map, since the server fans requests across goroutines.
type cache struct {
	mu    sync.Mutex
	blobs map[string]FileBlob
}

func newCache() *cache {
	return &cache{blobs: map[string]FileBlob{}}
}

func blobKey(owner, repo, ref, path string) string {
	return owner + "/" + repo + "/" + ref + "/" + path
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

func (c *cache) clearAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.blobs)
}
