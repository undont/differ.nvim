package github

// posts every graphql document to github's live schema with no variables at all. github
// validates the document before it coerces variables, so a field or argument the schema
// lacks comes back on its own, and a document it accepts comes back carrying nothing but
// coercion complaints. sending no variables is also what makes this safe to run: every
// document declares at least one required variable, asserted below, so coercion fails
// before a resolver is ever reached and no mutation can execute.

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"testing"
)

// the mutations, which queryConstants does not carry: the pageInfo lint has no interest in
// documents that hold no connections
var mutationConstants = []struct {
	name string
	body string
}{
	{"startReviewLookupQuery", startReviewLookupQuery},
	{"addReviewMutation", addReviewMutation},
	{"publishCommentMutation", publishCommentMutation},
	{"submitReviewMutation", submitReviewMutation},
	{"deleteReviewMutation", deleteReviewMutation},
	{"prNodeIDQuery", prNodeIDQuery},
	{"addThreadMutation", addThreadMutation},
	{"deleteCommentMutation", deleteCommentMutation},
	{"addThreadReplyMutation", addThreadReplyMutation},
	{"resolveThreadMutation", resolveThreadMutation},
	{"unresolveThreadMutation", unresolveThreadMutation},
	{"markFileViewedMutation", markFileViewedMutation},
	{"unmarkFileViewedMutation", unmarkFileViewedMutation},
	{"mergeLookupQuery", mergeLookupQuery},
	{"mergePRMutation", mergePRMutation},
	{"deleteRefMutation", deleteRefMutation},
}

// the one message class a valid document produces here, since no variables are sent. every
// other error names something the schema does not have
var coercionError = regexp.MustCompile(`^Variable \$\w+ of type .+ was provided invalid value`)

var varDecl = regexp.MustCompile(`\$(\w+):\s*([\w!\[\]]+)`)

func hasRequiredVariable(doc string) bool {
	for _, m := range varDecl.FindAllStringSubmatch(doc, -1) {
		if strings.HasSuffix(m[2], "!") {
			return true
		}
	}
	return false
}

// gh exits non-zero whenever the response carries errors, which is every response here, so
// the body is read rather than the status
func documentErrors(t *testing.T, doc string) []string {
	t.Helper()
	payload, err := json.Marshal(map[string]string{"query": doc})
	if err != nil {
		t.Fatalf("marshalling the request: %v", err)
	}
	cmd := exec.Command("gh", "api", "graphql", "--input", "-")
	cmd.Stdin = bytes.NewReader(payload)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	_ = cmd.Run()

	var res struct {
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &res); err != nil {
		t.Fatalf("gh returned no json (installed and authenticated?): %s", strings.TrimSpace(stderr.String()))
	}
	var msgs []string
	for _, e := range res.Errors {
		if !coercionError.MatchString(e.Message) {
			msgs = append(msgs, e.Message)
		}
	}
	return msgs
}

func TestDocumentsValidateAgainstLiveSchema(t *testing.T) {
	if os.Getenv("DIFFER_GRAPHQL_VALIDATE") == "" {
		t.Skip("posts to github's live schema; run `make gql-validate`")
	}
	for _, d := range append(append([]struct {
		name string
		body string
	}{}, queryConstants...), mutationConstants...) {
		t.Run(d.name, func(t *testing.T) {
			if !hasRequiredVariable(d.body) {
				t.Fatalf("declares no required variable, so sending none would execute it for real")
			}
			for _, msg := range documentErrors(t, d.body) {
				t.Errorf("%s", msg)
			}
		})
	}
}
