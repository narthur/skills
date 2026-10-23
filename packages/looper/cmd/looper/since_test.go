package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/narthur/skills/packages/looper/internal/mutate"
)

// -since through a symlinked root, to the toplevel or to a subdirectory, still selects the
// entry whose target this branch renamed away.
func TestChangedSinceSelectsARenamedTargetThroughASymlink(t *testing.T) {
	dir := fixture(t, map[string]string{"sub/a.go": "package a\n", "sub/b.go": "package a\n"})
	git(t, dir, "branch", "base")
	git(t, dir, "mv", "sub/a.go", "sub/c.go")
	git(t, dir, "commit", "-qm", "rename")
	for _, c := range []struct{ to, target string }{{dir, "sub/a.go"}, {filepath.Join(dir, "sub"), "a.go"}} {
		link := filepath.Join(t.TempDir(), "link")
		if err := os.Symlink(c.to, link); err != nil {
			t.Fatal(err)
		}
		changed, err := changedSince(link, "base")
		if err != nil {
			t.Fatal(err)
		}
		muts := []mutate.Mutation{
			{Source: filepath.Join(link, "a.mut"), Target: c.target},
			{Source: filepath.Join(link, "b.mut"), Target: filepath.Join(filepath.Dir(c.target), "b.go")},
		}
		got := mutate.Affected(muts, link, changed)
		if len(got) != 1 || got[0].Target != c.target {
			t.Errorf("link to %s: changed %v selected %v, want only the %s entry", c.to, changed, got, c.target)
		}
	}
	if _, err := changedSince(dir, "no-such-ref"); err == nil {
		t.Error("a bad ref returned no error, which reads as nothing to run")
	}
}
