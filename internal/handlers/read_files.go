package handlers

import (
	"context"
	"encoding/json"

	"github.com/undont/differ.nvim/internal/protocol"
)

type getFileVersionsParams struct {
	prParams
	Path string `json:"path"`
	// the file's path at the base sha: a rename's previous_path, else absent
	PreviousPath string `json:"previous_path"`
	// optional pinned refs: when the client already holds the PR's base/head shas
	// (from get_pr), it sends them so the sidecar skips the prRefs round-trip and
	// fetches the exact blobs the session is reviewing. empty falls back to prRefs
	Base string `json:"base"`
	Head string `json:"head"`
}

// getFileVersions returns the full base/head blobs for one PR file.
func (d Deps) getFileVersions(ctx context.Context, params json.RawMessage) (any, error) {
	var p getFileVersionsParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if err := requirePR(p.Owner, p.Repo, p.Number); err != nil {
		return nil, err
	}
	if p.Path == "" {
		return nil, protocol.NewError(protocol.CodeBadRequest, "path is required")
	}
	return d.GH.GetFileVersions(ctx, p.Owner, p.Repo, p.Number, p.Path, p.PreviousPath, p.Base, p.Head)
}
