package mutate

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Parallel mode gives serial mode's answers, in catalog order, without ever running a
// mutation in the real tree, and leaves no worktree registered behind it. The package
// sits in a subdirectory so the worker's root has to carry the repo prefix.
func TestParallelMatchesSerialOutsideTheRealTree(t *testing.T) {
	const src = "def f(x):\n    return x > 0\n"
	where := filepath.Join(t.TempDir(), "cwds")
	dir := repo(t, map[string]string{
		"pkg/app.py": src,
		"pkg/t.sh": "#!/bin/sh\npwd -P >> '" + where + "'\n" +
			"python3 -c 'import app; assert app.f(1) and not app.f(0)'\n",
		"pkg/hollow.sh": "#!/bin/sh\npython3 -c 'import app'\n",
		"pkg/red.sh":    "#!/bin/sh\nexit 1\n",
		// CI has no global gitignore, so the bytecode t.sh leaves would read as a dirty tree.
		".gitignore": "__pycache__/\n",
	})
	root := filepath.Join(dir, "pkg")
	muts := []Mutation{
		{Source: "a.mut", Target: "app.py", Verify: []string{"./t.sh"}, Old: "x > 0", New: "x < 0"},
		{Source: "b.mut", Target: "app.py", Verify: []string{"./hollow.sh"}, Old: "x > 0", New: "x >= 0"},
		{Source: "c.mut", Target: "app.py", Verify: []string{"./t.sh"}, Old: "no such anchor", New: "x"},
		{Source: "d.mut", Target: "app.py", Verify: []string{"./t.sh"}, Old: "return x", New: "return not x"},
		{Source: "e.mut", Target: "app.py", Verify: []string{"./red.sh"}, Old: "x > 0", New: "x != 0"},
	}
	serial, err := (&Runner{Root: root}).Run(muts)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(where); err != nil {
		t.Fatal(err)
	}
	par, err := (&Runner{Root: root, Jobs: 3}).Run(muts)
	if err != nil {
		t.Fatal(err)
	}
	if len(par) != len(serial) {
		t.Fatalf("parallel returned %d results, serial %d", len(par), len(serial))
	}
	for i := range serial {
		if par[i].Mutation.Source != serial[i].Mutation.Source || par[i].Outcome != serial[i].Outcome {
			t.Errorf("result %d: parallel %s %s, serial %s %s", i,
				par[i].Mutation.Source, par[i].Outcome, serial[i].Mutation.Source, serial[i].Outcome)
		}
	}
	if serial[0].Outcome != Caught || serial[1].Outcome != Survived || serial[2].Outcome != Stale ||
		serial[4].Outcome != Broken {
		t.Errorf("fixture no longer covers caught, survived, stale and broken: %v %v %v %v",
			serial[0].Outcome, serial[1].Outcome, serial[2].Outcome, serial[4].Outcome)
	}

	// The baseline runs t.sh once in the real tree; every other line must be a worker's.
	cwds, err := os.ReadFile(where)
	if err != nil {
		t.Fatal(err)
	}
	realRoot, _ := filepath.EvalSymlinks(root)
	inReal := 0
	for _, l := range strings.Split(strings.TrimSpace(string(cwds)), "\n") {
		if l == realRoot {
			inReal++
		} else if !strings.HasSuffix(l, string(filepath.Separator)+"pkg") {
			t.Errorf("a verify ran at %s, not at the package inside a worktree", l)
		}
	}
	if inReal != 1 {
		t.Errorf("%d verify run(s) in the real tree, want 1 (the baseline)", inReal)
	}
	if got, _ := os.ReadFile(filepath.Join(root, "app.py")); string(got) != src {
		t.Errorf("real target changed: %q", got)
	}
	out, err := exec.Command("git", "-C", dir, "worktree", "list", "--porcelain").Output()
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(out), "worktree "); n != 1 {
		t.Errorf("%d worktrees registered after the run, want 1:\n%s", n, out)
	}
}
