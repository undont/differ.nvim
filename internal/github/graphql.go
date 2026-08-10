package github

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"

	"github.com/undont/differ.nvim/internal/protocol"
)

// gqlMaxPages bounds every cursor walk, mirroring getPaged's REST cap.
const gqlMaxPages = 100

// nextCursor reports the cursor to fetch next and whether the walk continues. it stops
// on the last page, on a null endCursor, and on a cursor that hasn't moved: an empty
// cursor is omitted from the query variables, so either of those refetches page 1.
func nextCursor(prev string, info pageInfoGQL) (string, bool) {
	if !info.HasNextPage || info.EndCursor == "" || info.EndCursor == prev {
		return "", false
	}
	return info.EndCursor, true
}

// graphql posts a raw GraphQL query (no go-gh, no typed dep) and decodes
// the data field into out. top-level GraphQL errors map via mapGraphQL even on a
// 200; HTTP-level failures map via mapHTTP.
func (c *Client) graphql(ctx context.Context, query string, vars map[string]any, out any) error {
	if c.tokenErr != nil {
		return c.tokenErr
	}
	payload, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.gqlURL, bytes.NewReader(payload))
	if err != nil {
		return protocol.NewError(protocol.CodeInternal, err.Error())
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Api-Version", apiVersion)

	_, body, err := c.send(req)
	if err != nil {
		return err
	}

	var envelope struct {
		Data   json.RawMessage `json:"data"`
		Errors []gqlError      `json:"errors"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding graphql response: "+err.Error())
	}
	if perr := mapGraphQL(envelope.Errors); perr != nil {
		return perr
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(envelope.Data, out); err != nil {
		return protocol.NewError(protocol.CodeInternal, "decoding graphql data: "+err.Error())
	}
	return nil
}
