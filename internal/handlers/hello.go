package handlers

import (
	"context"
	"encoding/json"
	"strconv"

	"github.com/undont/differ.nvim/internal/protocol"
)

type helloParams struct {
	Client   string `json:"client"`
	Protocol int    `json:"protocol"`
}

// Auth is "ok" or the closed-set code token resolution failed with; AuthMessage
// carries what to do about it. both are absent when there is no github surface to
// ask (and from a sidecar predating them), which the client reads as unknown rather
// than as trouble. added after protocol 1 froze, so it needs no version bump: an
// older client decodes the frame and ignores the fields.
type helloResult struct {
	Protocol    int    `json:"protocol"`
	Binary      string `json:"binary"`
	Auth        string `json:"auth,omitempty"`
	AuthMessage string `json:"auth_message,omitempty"`
}

// hello is the handshake. a client protocol newer than ours is a hard
// mismatch surfaced as bad_request so the client tells the user to rebuild; an
// older or unset client protocol still gets our versions back.
func (d Deps) hello(_ context.Context, params json.RawMessage) (any, error) {
	var p helloParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	if p.Protocol > protocol.Version {
		return nil, protocol.NewError(protocol.CodeBadRequest,
			"protocol mismatch: client speaks "+strconv.Itoa(p.Protocol)+
				", sidecar speaks "+strconv.Itoa(protocol.Version)+", rebuild your sidecar; run `make go-build`")
	}
	res := helloResult{Protocol: protocol.Version, Binary: protocol.Binary}
	if d.GH != nil {
		res.Auth, res.AuthMessage = d.GH.TokenStatus()
	}
	return res, nil
}
