package mutate

import (
	"path/filepath"
	"strings"
)

// Affected keeps the entries a change could have touched: those whose target, whose own
// .mut file, or a path one of whose verify commands names (`./internal/stats/`, `./t.sh`)
// holds a changed file. changed is absolute paths spelled from root as given, symlinks
// and all, since that is how targets are joined here.
//
// ponytail: a change in a package the target only imports selects nothing, so a test that
// stopped catching through a dependency is missed here; CI runs the whole catalog for that.
func Affected(muts []Mutation, root string, changed []string) []Mutation {
	root, _ = filepath.Abs(root)
	hit := func(p string) bool {
		for _, c := range changed {
			if c == p || strings.HasPrefix(c, p+string(filepath.Separator)) {
				return true
			}
		}
		return false
	}
	var keep []Mutation
	for _, m := range muts {
		touched := hit(filepath.Join(root, m.Target)) || hit(abs(m.Source))
		for _, cmd := range m.Verify {
			for _, tok := range strings.FieldsFunc(cmd, func(r rune) bool {
				return r == ' ' || r == '\t' || r == '\'' || r == '"' || r == ';' || r == '|' || r == '&'
			}) {
				// No stat of p: a deleted script, or a path beyond a symlinked root, is
				// absent on disk and must still select. A token that is not a path
				// (`go`, `-run`) only ever over-selects, the safe direction.
				if p := filepath.Join(root, tok); p != root && hit(p) {
					touched = true
				}
			}
		}
		if touched {
			keep = append(keep, m)
		}
	}
	return keep
}

func abs(p string) string {
	a, _ := filepath.Abs(p)
	return a
}
