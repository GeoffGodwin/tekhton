package dag

import "os"

func writeOSFile(path string, body []byte, perm os.FileMode) error {
	return os.WriteFile(path, body, perm)
}
