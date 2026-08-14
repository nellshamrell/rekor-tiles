//
// Copyright 2026 The Sigstore Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Command fscheck reports whether a directory sits on a filesystem that can
// safely host a Tessera POSIX log.
//
// Tessera's POSIX driver is not merely "somewhere I can write files". It relies
// on a specific set of POSIX guarantees to keep the log consistent in the face
// of crashes and concurrent writers (see storage/posix/file_ops.go upstream):
//
//   - hard links, used by createEx to publish a fully written temporary file
//     into its final name, and to fail loudly if that name already exists
//   - rename over an existing file, used by overwrite for the checkpoint
//   - fsync on a directory, so metadata for the operations above is durable
//   - fcntl record locks, used to coordinate multiple frontends
//   - O_SYNC writes
//
// Plenty of network filesystems provide only some of these. Azure Files over
// SMB has no hard links; blobfuse2 has neither hard links nor atomic rename.
// A log hosted on one of those does not fail cleanly at mount time, it fails
// later, during a write, possibly after clients have already seen a checkpoint.
// Hence this preflight: run it against the directory you intend to pass to
// --storage-dir before trusting it.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// result records the outcome of a single capability probe.
type result struct {
	name   string
	detail string
	err    error
}

func main() {
	os.Exit(run())
}

// run holds the body of main so that deferred cleanup, in particular removal of
// the probe directory, still happens on the failure paths.
func run() int {
	dir := flag.String("dir", "", "directory to probe (required); it is created if it does not exist")
	quiet := flag.Bool("quiet", false, "print only failures")
	flag.Parse()

	if *dir == "" {
		fmt.Fprintln(os.Stderr, "fscheck: --dir is required")
		return 2
	}

	abs, err := filepath.Abs(*dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "fscheck: resolving %q: %v\n", *dir, err)
		return 2
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "fscheck: creating %q: %v\n", abs, err)
		return 2
	}

	probeDir, err := os.MkdirTemp(abs, ".fscheck-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "fscheck: creating probe directory under %q: %v\n", abs, err)
		return 2
	}
	defer func() {
		if err := os.RemoveAll(probeDir); err != nil {
			fmt.Fprintf(os.Stderr, "fscheck: cleaning up %q: %v\n", probeDir, err)
		}
	}()

	fsType, fsOpts := mountInfo(abs)
	fmt.Printf("path:       %s\n", abs)
	fmt.Printf("filesystem: %s\n", fsType)
	if fsOpts != "" {
		fmt.Printf("options:    %s\n", fsOpts)
	}
	fmt.Println()

	results := []result{
		checkDirSync(probeDir),
		checkOSync(probeDir),
		checkHardLink(probeDir),
		checkLinkExclusive(probeDir),
		checkRenameOverwrite(probeDir),
		checkFcntlLock(probeDir),
	}

	failed := 0
	for _, r := range results {
		switch {
		case r.err != nil:
			failed++
			fmt.Printf("FAIL  %-22s %v\n", r.name, r.err)
		case !*quiet:
			fmt.Printf("ok    %-22s %s\n", r.name, r.detail)
		}
	}

	fmt.Println()
	if failed > 0 {
		fmt.Printf("%d of %d checks failed: this filesystem is NOT safe for a Tessera POSIX log.\n", failed, len(results))
		return 1
	}
	fmt.Printf("All %d checks passed.\n", len(results))
	fmt.Println("Note that these probes establish that the required operations are supported,")
	fmt.Println("not that they are atomic under concurrent access. For a networked or clustered")
	fmt.Println("filesystem, follow up with a POSIX conformance suite such as pjdfstest.")
	return 0
}

// checkDirSync opens a directory with O_DIRECTORY and fsyncs it, which is how
// syncDir makes file creation and rename metadata durable.
func checkDirSync(dir string) result {
	r := result{name: "directory fsync"}
	fd, err := os.OpenFile(dir, os.O_RDONLY|syscall.O_DIRECTORY, 0)
	if err != nil {
		r.err = fmt.Errorf("open with O_DIRECTORY: %w", err)
		return r
	}
	defer func() {
		if cerr := fd.Close(); cerr != nil && r.err == nil {
			r.err = fmt.Errorf("close: %w", cerr)
		}
	}()

	if err := fd.Sync(); err != nil {
		r.err = fmt.Errorf("fsync: %w", err)
		return r
	}
	r.detail = "fsync on an O_DIRECTORY handle succeeds"
	return r
}

// checkOSync writes a file with O_SYNC, as createTemp does.
func checkOSync(dir string) result {
	r := result{name: "O_SYNC writes"}
	name := filepath.Join(dir, "osync")
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_SYNC, 0o644)
	if err != nil {
		r.err = fmt.Errorf("open with O_SYNC: %w", err)
		return r
	}
	if _, err := f.Write([]byte("tessera")); err != nil {
		_ = f.Close()
		r.err = fmt.Errorf("write: %w", err)
		return r
	}
	if err := f.Close(); err != nil {
		r.err = fmt.Errorf("close: %w", err)
		return r
	}
	r.detail = "synchronous writes accepted"
	return r
}

// checkHardLink verifies os.Link, which createEx uses to publish a temporary
// file into its final name.
func checkHardLink(dir string) result {
	r := result{name: "hard links"}
	src := filepath.Join(dir, "link-src")
	dst := filepath.Join(dir, "link-dst")
	if err := os.WriteFile(src, []byte("tessera"), 0o600); err != nil {
		r.err = fmt.Errorf("writing source: %w", err)
		return r
	}
	if err := os.Link(src, dst); err != nil {
		r.err = fmt.Errorf("link: %w (Azure Files/SMB and blobfuse2 fail here)", err)
		return r
	}

	fi, err := os.Stat(dst)
	if err != nil {
		r.err = fmt.Errorf("stat: %w", err)
		return r
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		r.detail = "link created (link count unavailable on this platform)"
		return r
	}
	if st.Nlink != 2 {
		r.err = fmt.Errorf("link created but link count is %d, want 2", st.Nlink)
		return r
	}
	r.detail = "os.Link creates a second name for one inode"
	return r
}

// checkLinkExclusive verifies that linking onto an existing name fails with
// EEXIST. createEx depends on this to detect a name it must not clobber.
func checkLinkExclusive(dir string) result {
	r := result{name: "link is exclusive"}
	src := filepath.Join(dir, "excl-src")
	dst := filepath.Join(dir, "excl-dst")
	for _, p := range []string{src, dst} {
		if err := os.WriteFile(p, []byte("tessera"), 0o600); err != nil {
			r.err = fmt.Errorf("writing %s: %w", filepath.Base(p), err)
			return r
		}
	}
	err := os.Link(src, dst)
	if err == nil {
		r.err = errors.New("link onto an existing name succeeded, but it must fail with EEXIST")
		return r
	}
	if !errors.Is(err, os.ErrExist) {
		r.err = fmt.Errorf("link onto an existing name failed with %w, want EEXIST", err)
		return r
	}
	r.detail = "linking onto an existing name returns EEXIST"
	return r
}

// checkRenameOverwrite verifies rename over an existing file, which overwrite
// uses to replace the checkpoint in a single step.
func checkRenameOverwrite(dir string) result {
	r := result{name: "rename over existing"}
	src := filepath.Join(dir, "rename-src")
	dst := filepath.Join(dir, "rename-dst")
	if err := os.WriteFile(src, []byte("new"), 0o600); err != nil {
		r.err = fmt.Errorf("writing source: %w", err)
		return r
	}
	if err := os.WriteFile(dst, []byte("old"), 0o600); err != nil {
		r.err = fmt.Errorf("writing target: %w", err)
		return r
	}
	if err := os.Rename(src, dst); err != nil {
		r.err = fmt.Errorf("rename: %w", err)
		return r
	}

	got, err := os.ReadFile(dst)
	if err != nil {
		r.err = fmt.Errorf("reading target: %w", err)
		return r
	}
	if string(got) != "new" {
		r.err = fmt.Errorf("target holds %q after rename, want %q", got, "new")
		return r
	}
	r.detail = "rename replaces an existing file in one step"
	return r
}

// checkFcntlLock takes and releases an exclusive fcntl record lock, the
// mechanism behind .state/treeState.lock and .state/publish.lock.
//
// This probes support, not contention: POSIX record locks are owned by the
// process, so a second lock taken here would succeed regardless. Filesystems
// without locking support (NFS with no lock manager, for example) report
// ENOLCK or EOPNOTSUPP from the call below.
func checkFcntlLock(dir string) result {
	r := result{name: "fcntl record locks"}
	name := filepath.Join(dir, "lock")
	f, err := os.OpenFile(name, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC, 0o644)
	if err != nil {
		r.err = fmt.Errorf("open: %w", err)
		return r
	}
	defer func() {
		if cerr := f.Close(); cerr != nil && r.err == nil {
			r.err = fmt.Errorf("close: %w", cerr)
		}
	}()

	lock := syscall.Flock_t{
		Type:   syscall.F_WRLCK,
		Whence: 0,
		Start:  0,
		Len:    0,
	}
	if err := syscall.FcntlFlock(f.Fd(), syscall.F_SETLK, &lock); err != nil {
		r.err = fmt.Errorf("F_SETLK: %w", err)
		return r
	}

	lock.Type = syscall.F_UNLCK
	if err := syscall.FcntlFlock(f.Fd(), syscall.F_SETLK, &lock); err != nil {
		r.err = fmt.Errorf("F_UNLCK: %w", err)
		return r
	}
	r.detail = "exclusive record lock taken and released"
	return r
}

// mountInfo returns the filesystem type and mount options for the mount point
// containing path, by longest-prefix match against /proc/self/mounts.
func mountInfo(path string) (fsType, opts string) {
	f, err := os.Open("/proc/self/mounts")
	if err != nil {
		return "unknown", ""
	}
	defer func() { _ = f.Close() }()

	best := ""
	fsType = "unknown"
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 {
			continue
		}
		mountPoint := fields[1]
		if !underMount(path, mountPoint) {
			continue
		}
		if len(mountPoint) >= len(best) {
			best, fsType, opts = mountPoint, fields[2], fields[3]
		}
	}
	return fsType, opts
}

// underMount reports whether path lies within the given mount point.
func underMount(path, mountPoint string) bool {
	if mountPoint == "/" {
		return true
	}
	return path == mountPoint || strings.HasPrefix(path, mountPoint+string(filepath.Separator))
}
