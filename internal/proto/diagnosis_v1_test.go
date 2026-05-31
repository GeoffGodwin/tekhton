package proto

import (
	stderrs "errors"
	"strings"
	"testing"
)

func TestDiagnosisV1_AvailableFalse_MarshalsCanonical(t *testing.T) {
	t.Parallel()
	p := DiagnosisV1{Available: false}
	b, err := p.MarshalJSON()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := string(b)
	// available=false canonical shape: no classification, no confidence,
	// no cause_chain, no suggestions; recurring_count and schema_version
	// always emit.
	for _, want := range []string{`"available":false`, `"recurring_count":0`, `"schema_version":1`} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %s in: %s", want, got)
		}
	}
	for _, banned := range []string{`"classification"`, `"confidence"`, `"cause_chain"`, `"suggestions"`} {
		if strings.Contains(got, banned) {
			t.Errorf("unexpected field %s in: %s", banned, got)
		}
	}
}

func TestDiagnosisV1_AvailableTrue_RoundTripsPopulatedFields(t *testing.T) {
	t.Parallel()
	in := DiagnosisV1{
		Available:      true,
		Classification: "BUILD_FAILURE",
		Confidence:     "high",
		Stage:          "coder",
		CauseChain:     "stage_start -> 3x error -> build_fix",
		Suggestions:    []string{"Build failed.", "Options:", "  1. Fix and retry"},
		RecurringCount: 2,
		SchemaVersion:  DiagnosisV1SchemaVersion,
	}
	b, err := in.MarshalJSON()
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Round-trip through the default unmarshaller (bypasses MarshalJSON).
	var out DiagnosisV1
	if err := unmarshalDiagnosisV1(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Classification != in.Classification {
		t.Errorf("classification: want %q got %q", in.Classification, out.Classification)
	}
	if out.Confidence != in.Confidence {
		t.Errorf("confidence: want %q got %q", in.Confidence, out.Confidence)
	}
	if out.Stage != in.Stage {
		t.Errorf("stage: want %q got %q", in.Stage, out.Stage)
	}
	if out.RecurringCount != in.RecurringCount {
		t.Errorf("recurring_count: want %d got %d", in.RecurringCount, out.RecurringCount)
	}
	if out.SchemaVersion != in.SchemaVersion {
		t.Errorf("schema_version: want %d got %d", in.SchemaVersion, out.SchemaVersion)
	}
	if got, want := strings.Join(out.Suggestions, "|"), strings.Join(in.Suggestions, "|"); got != want {
		t.Errorf("suggestions: want %q got %q", want, got)
	}
}

func TestDiagnosisV1_MarshalStampsSchemaVersionWhenZero(t *testing.T) {
	t.Parallel()
	p := DiagnosisV1{Available: true, Classification: "X", Confidence: "high"}
	b, _ := p.MarshalJSON()
	if !strings.Contains(string(b), `"schema_version":1`) {
		t.Fatalf("schema_version must default to 1 when zero, got: %s", b)
	}
}

func TestDiagnosisV1_Validate(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		in   DiagnosisV1
		want error
	}{
		{
			name: "available false ok",
			in:   DiagnosisV1{Available: false},
			want: nil,
		},
		{
			name: "available true with required fields",
			in:   DiagnosisV1{Available: true, Classification: "BUILD_FAILURE", Confidence: "high"},
			want: nil,
		},
		{
			name: "available true missing classification",
			in:   DiagnosisV1{Available: true, Confidence: "high"},
			want: ErrDiagnosisInvalid,
		},
		{
			name: "available true missing confidence",
			in:   DiagnosisV1{Available: true, Classification: "BUILD_FAILURE"},
			want: ErrDiagnosisInvalid,
		},
		{
			name: "invalid confidence vocabulary",
			in:   DiagnosisV1{Available: true, Classification: "X", Confidence: "extreme"},
			want: ErrDiagnosisInvalid,
		},
		{
			name: "negative recurring count",
			in:   DiagnosisV1{RecurringCount: -1},
			want: ErrDiagnosisInvalid,
		},
		{
			name: "negative schema version",
			in:   DiagnosisV1{SchemaVersion: -1},
			want: ErrDiagnosisInvalid,
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := tc.in.Validate()
			if tc.want == nil {
				if got != nil {
					t.Fatalf("want nil, got %v", got)
				}
				return
			}
			if !stderrs.Is(got, tc.want) {
				t.Fatalf("want %v, got %v", tc.want, got)
			}
		})
	}
}

func TestDiagnosisV1Proto_Constant(t *testing.T) {
	t.Parallel()
	if DiagnosisV1Proto != "tekhton.diagnosis.v1" {
		t.Fatalf("proto tag drifted: %q", DiagnosisV1Proto)
	}
	if DiagnosisV1SchemaVersion != 1 {
		t.Fatalf("schema version drifted: %d", DiagnosisV1SchemaVersion)
	}
}
