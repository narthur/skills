package mutate

import (
	"os"
	"path/filepath"
	"strings"
)

// Affected keeps the entries a change could have touched: those whose target, whose own
// .mut file, or a path one of whose verify commands names (`./internal/stats/`, `./t.sh`)
// holds a changed file. changed is absolute paths.
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
		src, _ := filepath.Abs(m.Source)
		ok := hit(filepath.Join(root, m.Target)) || hit(src)
		for _, cmd := range m.Verify {
			for _, tok := range strings.FieldsFunc(cmd, func(r rune) bool {
				return r == ' ' || r == '\t' || r == '\'' || r == '"' || r == ';' || r == '|' || r == '&'
			}) {
				p := filepath.Join(root, tok)
				if p == root || ok {
					continue
				}
				if _, err := os.Stat(p); err == nil && hit(p) {
					ok = true
				}
			}
		}
		if ok {
			keep = append(keep, m)
		}
	}
	return keep
}
