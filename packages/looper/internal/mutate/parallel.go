package mutate

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

// runParallel works through muts with `jobs` workers, each in its own detached git
// worktree of HEAD, so no mutation is ever written into r.Root. Run has already checked
// the tree is clean and run the baseline there, so a worktree of HEAD holds exactly the
// tracked bytes the baseline ran on.
//
// Serial mode mutates the real tree in place, one entry after another, and took 27 minutes
// for 476 entries (2026-10-23). Each entry is a recompile plus one test, so they are
// independent, and serial mode left the other cores idle.
func (r *Runner) runParallel(muts []Mutation, alreadyBad map[string]string, jobs int) ([]Result, error) {
	prefix, err := r.git("rev-parse", "--show-prefix")
	if err != nil {
		return nil, err
	}
	scratch, err := os.MkdirTemp("", "looper-mutate-")
	if err != nil {
		return nil, err
	}
	var dirs []string
	cleanup := func() {
		for _, d := range dirs {
			_ = exec.Command("git", "-C", r.Root, "worktree", "remove", "--force", d).Run()
		}
		_ = os.RemoveAll(scratch)
		_ = exec.Command("git", "-C", r.Root, "worktree", "prune").Run()
	}
	defer cleanup()
	// Workers skip their own restore-on-signal (their trees are scratch), so this is the
	// one handler: it removes the worktrees rather than leaving them registered in .git.
	stop := onSignal(func() { cleanup(); os.Exit(130) })
	defer stop()

	log := &lockedWriter{w: r.Log}
	workers := make([]*Runner, min(jobs, len(muts)))
	for i := range workers {
		d := filepath.Join(scratch, fmt.Sprint(i))
		if _, err := r.git("worktree", "add", "--detach", "-q", d, "HEAD"); err != nil {
			return nil, err
		}
		dirs = append(dirs, d)
		workers[i] = &Runner{Root: filepath.Join(d, prefix), scratch: true}
		if r.Log != nil {
			workers[i].Log = log
		}
	}

	results := make([]Result, len(muts))
	done := make([]bool, len(muts))
	next := make(chan int)
	quit := make(chan struct{})
	var mu sync.Mutex
	var firstErr error
	go func() {
		defer close(next)
		for i := range muts {
			select {
			case next <- i:
			case <-quit:
				return
			}
		}
	}()
	var wg sync.WaitGroup
	for _, w := range workers {
		wg.Add(1)
		go func(w *Runner) {
			defer wg.Done()
			for i := range next {
				m := muts[i]
				res := Result{Mutation: m, Outcome: Broken, Detail: firstBad(m, alreadyBad)}
				if res.Detail == "" {
					var err error
					if res, err = w.one(m); err != nil {
						mu.Lock()
						if firstErr == nil {
							firstErr = err
							close(quit)
						}
						mu.Unlock()
						return
					}
				}
				mu.Lock()
				results[i], done[i] = res, true
				mu.Unlock()
				w.logf("  %-8s %-34s %s\n", res.Outcome, m.Name(), res.Detail)
			}
		}(w)
	}
	wg.Wait()

	// Catalog order, as serial mode returns them; the log above is in finishing order.
	out := make([]Result, 0, len(muts))
	for i, ok := range done {
		if ok {
			out = append(out, results[i])
		}
	}
	return out, firstErr
}

func (r *Runner) git(args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", r.Root}, args...)...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s in %s: %w: %s", strings.Join(args, " "), r.Root, err, out)
	}
	return strings.TrimSpace(string(out)), nil
}

// lockedWriter keeps each worker's progress line whole.
type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}
