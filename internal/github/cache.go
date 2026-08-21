package github

import (
	"container/list"
	"sync"
)

// maxBlobBytes caps the blob cache's total content. twice maxResponse, so the cap
// always fits at least one entry however large.
const maxBlobBytes = 64 * 1024 * 1024

// cache is the sidecar's blob memo. a path's bytes at a sha are immutable, so entries
// never go stale, only accumulate: hence the byte cap and LRU eviction. threads are not
// cached here, the client owns their freshness. one mutex, since the server fans
// requests across goroutines.
type cache struct {
	mu    sync.Mutex
	blobs map[string]*list.Element
	lru   *list.List // *blobEntry, most-recently-used at the front; eviction pops the back
	bytes int
	limit int // maxBlobBytes; smaller in the eviction tests
}

// blobEntry is one cached blob and its charge against the cap; key lets eviction drop
// the map entry from the list node alone.
type blobEntry struct {
	key  string
	blob FileBlob
	size int
}

// blobSize charges the key too, so empty blobs (a path missing at a sha) still count.
func blobSize(key string, b FileBlob) int {
	return len(key) + len(b.Content)
}

func newCache() *cache {
	return &cache{blobs: map[string]*list.Element{}, lru: list.New(), limit: maxBlobBytes}
}

func blobKey(owner, repo, ref, path string) string {
	return owner + "/" + repo + "/" + ref + "/" + path
}

// blob returns the cached bytes, marking the entry most-recently-used.
func (c *cache) blob(key string) (FileBlob, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.blobs[key]
	if !ok {
		return FileBlob{}, false
	}
	c.lru.MoveToFront(el)
	return el.Value.(*blobEntry).blob, true
}

func (c *cache) putBlob(key string, b FileBlob) {
	c.mu.Lock()
	defer c.mu.Unlock()
	size := blobSize(key, b)
	if el, ok := c.blobs[key]; ok {
		e := el.Value.(*blobEntry)
		c.bytes += size - e.size
		e.blob, e.size = b, size
		c.lru.MoveToFront(el)
	} else {
		c.blobs[key] = c.lru.PushFront(&blobEntry{key: key, blob: b, size: size})
		c.bytes += size
	}
	c.evict()
}

// evict drops the coldest entries until the cache is under the cap. the length guard
// terminates the loop even for an entry bigger than the cap itself.
func (c *cache) evict() {
	for c.bytes > c.limit && c.lru.Len() > 0 {
		el := c.lru.Back()
		e := el.Value.(*blobEntry)
		c.lru.Remove(el)
		delete(c.blobs, e.key)
		c.bytes -= e.size
	}
}

func (c *cache) clearAll() {
	c.mu.Lock()
	defer c.mu.Unlock()
	clear(c.blobs)
	c.lru.Init()
	c.bytes = 0
}
