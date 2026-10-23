package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/narthur/skills/packages/looper/internal/mutate"
)

// -since through a symlinked root still selects the entry whose target this branch
// renamed away: both the old path and the merge-base semantics have to hold.
func TestChangedSinceSelectsARenamedTargetThroughASymlink(t *testing.T) {
	dir := fixture(t, map[string]string{"a.go": "package a\n", "b.go": "package a\n"})
	git(t, dir, "branch", "base")
	git(t, dir, "mv", "a.go", "c.go")
	git(t, dir, "commit", "-qm", "rename")
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(dir, link); err != nil {
		t.Fatal(err)
	}
	changed, err := changedSince(link, "base")
	if err != nil {
		t.Fatal(err)
	}
	muts := []mutate.Mutation{
		{Source: filepath.Join(link, "a.mut"), Target: "a.go"},
		{Source: filepath.Join(link, "b.mut"), Target: "b.go"},
	}
	got := mutate.Affected(muts, link, changed)
	if len(got) != 1 || got[0].Target != "a.go" {
		t.Errorf("changed %v selected %v, want only the a.go entry", changed, got)
	}
	if _, err := changedSince(dir, "no-such-ref"); err == nil {
		t.Error("a bad ref returned no error, which reads as nothing to run")
	}
}
