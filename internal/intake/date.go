package intake

import "time"

func defaultDateProvider() string {
	return time.Now().UTC().Format("2006-01-02")
}
