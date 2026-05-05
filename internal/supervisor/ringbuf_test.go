package supervisor

import (
	"reflect"
	"strconv"
	"sync"
	"testing"
)

func TestRingBuf_NewClampsZeroToOne(t *testing.T) {
	r := newRingBuf(0)
	if r.size != 1 {
		t.Errorf("size: got %d, want 1 (zero must clamp)", r.size)
	}
	r.add("a")
	r.add("b")
	if got := r.snapshot(); !reflect.DeepEqual(got, []string{"b"}) {
		t.Errorf("snapshot after wrap: got %v, want [b]", got)
	}
}

func TestRingBuf_AddBelowCapacity_PreservesOrder(t *testing.T) {
	r := newRingBuf(5)
	r.add("a")
	r.add("b")
	r.add("c")
	got := r.snapshot()
	want := []string{"a", "b", "c"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("snapshot: got %v, want %v", got, want)
	}
	if r.len() != 3 {
		t.Errorf("len: got %d, want 3", r.len())
	}
}

func TestRingBuf_OverflowKeepsLastN(t *testing.T) {
	const cap = 50
	r := newRingBuf(cap)
	for i := 1; i <= 100; i++ {
		r.add(strconv.Itoa(i))
	}
	got := r.snapshot()
	if len(got) != cap {
		t.Fatalf("snapshot length: got %d, want %d", len(got), cap)
	}
	if got[0] != "51" {
		t.Errorf("oldest entry: got %q, want \"51\" (lines 1–50 must be evicted)", got[0])
	}
	if got[cap-1] != "100" {
		t.Errorf("newest entry: got %q, want \"100\"", got[cap-1])
	}
	for i, line := range got {
		want := strconv.Itoa(i + 51)
		if line != want {
			t.Errorf("snapshot[%d]: got %q, want %q", i, line, want)
			break
		}
	}
}

func TestRingBuf_SnapshotIsCopy(t *testing.T) {
	r := newRingBuf(3)
	r.add("a")
	r.add("b")
	snap := r.snapshot()
	snap[0] = "MUTATED"
	got := r.snapshot()
	if got[0] != "a" {
		t.Errorf("snapshot must return a copy: ringbuf[0] = %q after mutation, want \"a\"", got[0])
	}
}

func TestRingBuf_ConcurrentAddDoesNotDeadlock(t *testing.T) {
	r := newRingBuf(64)
	var wg sync.WaitGroup
	const writers = 8
	const perWriter = 200
	wg.Add(writers)
	for w := 0; w < writers; w++ {
		go func(wi int) {
			defer wg.Done()
			for i := 0; i < perWriter; i++ {
				r.add("w" + strconv.Itoa(wi) + "-" + strconv.Itoa(i))
			}
		}(w)
	}
	wg.Wait()
	if got := r.len(); got != 64 {
		t.Errorf("len after %d concurrent adds: got %d, want 64", writers*perWriter, got)
	}
}
