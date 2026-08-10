package github

import (
	"context"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/undont/differ.nvim/internal/protocol"
)

// GetFileVersions returns the full base and head blobs for one path in a PR. the
// caller passes the pinned base/head shas (from get_pr) so the prRefs round-trip is
// skipped and the exact session blobs are fetched; an empty sha falls back to
// resolving it. the two sides are fetched concurrently (independent immutable blobs,
// cache is mutex-guarded for fan-out). a 404 on a side marks it missing (an added
// file has no base, a deleted file has no head) rather than failing the call.
func (c *Client) GetFileVersions(ctx context.Context, owner, repo string, number int, path, base, head string) (*FileVersions, error) {
	if base == "" || head == "" {
		rbase, rhead, err := c.prRefs(ctx, owner, repo, number)
		if err != nil {
			return nil, err
		}
		base, head = rbase, rhead
	}

	type blobResult struct {
		blob FileBlob
		err  error
	}
	baseCh := make(chan blobResult, 1)
	go func() {
		b, err := c.rawBlob(ctx, owner, repo, path, base)
		baseCh <- blobResult{b, err}
	}()
	headBlob, headErr := c.rawBlob(ctx, owner, repo, path, head)
	baseRes := <-baseCh
	if baseRes.err != nil {
		return nil, baseRes.err
	}
	if headErr != nil {
		return nil, headErr
	}
	return &FileVersions{Base: baseRes.blob, Head: headBlob}, nil
}

// HeadSHA resolves a PR's current head commit sha (via prRefs), for the TOCTOU
// guard: the mutate handlers compare it against the client's pinned expected_head and
// reject with conflict if the head moved since the review was anchored.
func (c *Client) HeadSHA(ctx context.Context, owner, repo string, number int) (string, error) {
	_, head, err := c.prRefs(ctx, owner, repo, number)
	return head, err
}

// prRefs resolves a PR's base and head commit SHAs via REST (lighter than the
// get_pr GraphQL meta, which fetches the whole file list).
func (c *Client) prRefs(ctx context.Context, owner, repo string, number int) (base, head string, err error) {
	var p prRefsDTO
	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/pulls/" + strconv.Itoa(number)
	if err := c.getJSON(ctx, rawURL, &p); err != nil {
		return "", "", err
	}
	return p.Base.SHA, p.Head.SHA, nil
}

// rawBlob fetches a path's bytes at ref via the Contents API raw media type. a 404
// means the path is absent at that ref, reported as Missing rather than an error.
// ref is a commit sha, so the result is immutable and cached forever.
func (c *Client) rawBlob(ctx context.Context, owner, repo, path, ref string) (FileBlob, error) {
	if c.tokenErr != nil {
		return FileBlob{}, c.tokenErr
	}
	key := blobKey(owner, repo, ref, path)
	if b, ok := c.cache.blob(key); ok {
		return b, nil
	}
	rawURL := c.restURL + "/repos/" + owner + "/" + repo + "/contents/" + escapePath(path) + "?ref=" + url.QueryEscape(ref)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return FileBlob{}, protocol.NewError(protocol.CodeInternal, err.Error())
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/vnd.github.raw+json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)

	resp, body, err := c.send(req)
	if resp != nil && resp.StatusCode == http.StatusNotFound {
		// a missing path at a sha is itself immutable, so cache it too.
		blob := FileBlob{Missing: true}
		c.cache.putBlob(key, blob)
		return blob, nil
	}
	if err != nil {
		return FileBlob{}, err
	}
	blob := FileBlob{Content: string(body)}
	c.cache.putBlob(key, blob)
	return blob, nil
}

// escapePath percent-escapes each segment of a repo-relative path, keeping the
// slashes the Contents API uses as path separators.
func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i, s := range parts {
		parts[i] = url.PathEscape(s)
	}
	return strings.Join(parts, "/")
}
