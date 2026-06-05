package intake

import "time"

func defaultTimestamp() string {
	return time.Now().UTC().Format("2006-01-02 15:04:05")
}
