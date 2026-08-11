package github

import (
	"regexp"
	"strings"
	"testing"
)

// a connection taking first:/last: with no pageInfo beside it truncates silently, and
// nothing downstream can tell a full page from a capped one. valid graphql, so no schema
// check sees it. the two lists below are the only exemptions, and each entry carries why

var queryConstants = []struct {
	name string
	body string
}{
	{"getPRQuery", getPRQuery},
	{"getThreadsQuery", getThreadsQuery},
	{"getPendingReviewQuery", getPendingReviewQuery},
	{"getTimelineQuery", getTimelineQuery},
	{"getChecksQuery", getChecksQuery},
}

// bounded to one node by their own arguments, so there is no page to miss
var singularSelections = map[string]string{
	"getThreadsQuery.newestComment": "last: 1; the thread's newest comment, which the capped comments field beside it may exclude",
	"getPendingReviewQuery.reviews": "first: 1; a viewer has at most one pending review per pr",
	"getChecksQuery.commits":        "last: 1; the head commit only",
}

// known to truncate, with nowhere on the wire to say so: the dtos carry only Nodes, so
// asking for pageInfo would change nothing until they grow a carrier. this list only
// shrinks — an entry earns its place by naming what the overflow costs
var truncatingSelections = map[string]string{
	"getThreadsQuery.comments":       "100 of a thread's comments render in order with no marker, and the collapsed line reports 100",
	"getPendingReviewQuery.comments": "read by nothing today; traced from the dto through to both lua callers, which take review_id only",
	"getTimelineQuery.reviews":       "the oldest 100 verdicts render on the overview timeline; nothing derives state from them",
	"getChecksQuery.contexts":        "100 checks under a server-computed rollup, so the badge stays correct while the rows are short",
}

// alias, field name, and the argument list of a field that takes arguments
var argumentedField = regexp.MustCompile(`(?:(\w+)\s*:\s*)?(\w+)\s*\(([^)]*)\)`)

var paginationArg = regexp.MustCompile(`\b(?:first|last)\s*:`)

func TestPaginatedSelectionsCarryPageInfo(t *testing.T) {
	seen := map[string]bool{}
	for _, q := range queryConstants {
		for _, m := range argumentedField.FindAllStringSubmatchIndex(q.body, -1) {
			if !paginationArg.MatchString(q.body[m[6]:m[7]]) {
				continue
			}
			key := q.name + "." + fieldLabel(q.body, m)
			seen[key] = true
			if _, ok := singularSelections[key]; ok {
				continue
			}
			set, ok := selectionSet(q.body[m[1]:])
			if !ok {
				continue
			}
			checkPageInfo(t, key, hasTopLevelField(set, "pageInfo"))
		}
	}
	checkStale(t, seen)
}

func checkPageInfo(t *testing.T, key string, present bool) {
	t.Helper()
	_, filed := truncatingSelections[key]
	switch {
	case present && filed:
		t.Errorf("%s now asks for pageInfo; drop it from truncatingSelections", key)
	case !present && !filed:
		t.Errorf("%s takes first:/last: with no pageInfo in its selection set.\n"+
			"add pageInfo, or list it in singularSelections/truncatingSelections with a reason", key)
	}
}

func checkStale(t *testing.T, seen map[string]bool) {
	t.Helper()
	for _, list := range []map[string]string{singularSelections, truncatingSelections} {
		for key := range list {
			if !seen[key] {
				t.Errorf("%s is listed but no longer exists in the queries; drop it", key)
			}
		}
	}
}

// the alias when there is one, since it is what tells two selections of the same field apart
func fieldLabel(body string, m []int) string {
	if m[2] >= 0 {
		return body[m[2]:m[3]]
	}
	return body[m[4]:m[5]]
}

// the body of the block opening after a field's arguments, or false when it selects nothing
func selectionSet(after string) (string, bool) {
	open := strings.Index(after, "{")
	if open < 0 || strings.TrimSpace(after[:open]) != "" {
		return "", false
	}
	depth := 0
	for i, r := range after[open:] {
		switch r {
		case '{':
			depth++
		case '}':
			if depth--; depth == 0 {
				return after[open+1 : open+i], true
			}
		}
	}
	return "", false
}

func hasTopLevelField(set, name string) bool {
	for _, field := range identifiers.FindAllStringIndex(set, -1) {
		prefix := set[:field[0]]
		depth := strings.Count(prefix, "{") - strings.Count(prefix, "}")
		if depth == 0 && set[field[0]:field[1]] == name {
			return true
		}
	}
	return false
}

var identifiers = regexp.MustCompile(`\w+`)
