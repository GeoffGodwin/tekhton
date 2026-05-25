package tui

import "testing"

func TestCheckSidecarLivenessSampling(t *testing.T) {
	st := NewState()
	probes := 0
	probe := func(_ int) bool {
		probes++
		return true
	}

	// 19 writes should not fire the probe.
	for i := 0; i < 19; i++ {
		res := st.CheckSidecarLiveness(1234, DefaultLivenessInterval, probe)
		if res.Probed {
			t.Fatalf("write %d should not have probed (sampling interval = %d)", i, DefaultLivenessInterval)
		}
	}
	// 20th write should fire exactly one probe and reset the counter.
	res := st.CheckSidecarLiveness(1234, DefaultLivenessInterval, probe)
	if !res.Probed || !res.Alive {
		t.Fatalf("write 20 should have probed alive, got %+v", res)
	}
	if probes != 1 {
		t.Errorf("expected 1 probe invocation, got %d", probes)
	}
	if st.LivenessCount != 0 {
		t.Errorf("liveness count should reset after probe, got %d", st.LivenessCount)
	}
}

func TestCheckSidecarLivenessDeadEmitsWarn(t *testing.T) {
	st := NewState()
	probe := func(_ int) bool { return false }

	// Fast-forward to the probe boundary by setting the counter directly.
	st.LivenessCount = DefaultLivenessInterval - 1
	res := st.CheckSidecarLiveness(1234, DefaultLivenessInterval, probe)
	if !res.Probed || res.Alive {
		t.Fatalf("expected probed=true, alive=false, got %+v", res)
	}
	if res.WarnEvent == "" {
		t.Errorf("expected non-empty warn event on dead sidecar")
	}
}

func TestCheckSidecarLivenessSkipsWhenPIDInvalid(t *testing.T) {
	st := NewState()
	probed := false
	probe := func(_ int) bool {
		probed = true
		return true
	}
	res := st.CheckSidecarLiveness(0, DefaultLivenessInterval, probe)
	if res.Probed || probed {
		t.Errorf("probe should not fire when pid <= 0")
	}
}
