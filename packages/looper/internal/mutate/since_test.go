package mutate

import (
	"path/filepath"
	"testing"
)

func TestAffectedKeepsWhatAChangeCouldTouch(t *testing.T) {
	root := t.TempDir() // nothing on disk: a changed path may be deleted
	muts := []Mutation{
		{Source: filepath.Join(root, "x.mut"), Target: "internal/a/a.go", Verify: []string{"go test ./internal/b/ -run 'TestB'"}},
		{Source: filepath.Join(root, "y.mut"), Target: "internal/b/b.go", Verify: []string{"go test ./internal/a/ -count=1"}},
		{Source: filepath.Join(root, "mutations/m.mut"), Target: "internal/b/b.go", Verify: []string{"bash -c './t.sh || exit 1'"}},
		{Source: filepath.Join(root, "z.mut"), Target: "internal/b/b.go", Verify: []string{"go test ./... -run X", "./t.sh"}},
		{Source: filepath.Join(root, "w.mut"), Target: "internal/b/b.go", Verify: []string{"./gone.sh"}},
	}
	names := func(ms []Mutation) (s []string) {
		for _, m := range ms {
			s = append(s, filepath.Base(m.Source))
		}
		return
	}
	for _, c := range []struct {
		changed string
		want    []string
	}{
		{"internal/a/a.go", []string{"x.mut", "y.mut"}}, // target; a verify's package
		{"internal/a/a_test.go", []string{"y.mut"}},     // only the verify's package
		{"mutations/m.mut", []string{"m.mut"}},          // the entry itself
		{"t.sh", []string{"m.mut", "z.mut"}},            // a script a verify names, quoted or not
		{"gone.sh", []string{"w.mut"}},                  // a deleted script
		{"README.md", nil},                              // `./...` selects nothing
	} {
		got := names(Affected(muts, root, []string{filepath.Join(root, c.changed)}))
		if len(got) != len(c.want) {
			t.Errorf("%s changed: kept %v, want %v", c.changed, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("%s changed: kept %v, want %v", c.changed, got, c.want)
				break
			}
		}
	}
}
