package errors

import (
	"io/fs"
	"os"
	"path/filepath"
)

// scanFilesImpl is split from ScanFiles in evidence.go so the filesystem
// dependency lives in its own file; evidence.go stays a regex-only module
// for grep-ability.
func scanFilesImpl(root string, accept func(name string) bool, match func(body string) bool) bool {
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return false
	}
	matched := false
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			return nil
		}
		if accept != nil && !accept(d.Name()) {
			return nil
		}
		body, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		if match(string(body)) {
			matched = true
			return fs.SkipAll
		}
		return nil
	})
	return matched
}
