package main

import (
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

func TestBuildRunRequestExactlyOne(t *testing.T) {
	tests := []struct {
		name      string
		task      string
		resume    bool
		human     bool
		milestone string
		wantMode  string
		wantErr   bool
	}{
		{"task_only", "echo hi", false, false, "", proto.RunModeTask, false},
		{"resume_only", "", true, false, "", proto.RunModeResume, false},
		{"human_only", "", false, true, "", proto.RunModeHuman, false},
		{"milestone_only", "", false, false, "m1", proto.RunModeMilestone, false},
		{"none", "", false, false, "", "", true},
		{"task_and_resume", "x", true, false, "", "", true},
		{"task_and_human", "x", false, true, "", "", true},
		{"milestone_and_human", "", false, true, "m1", "", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req, err := buildRunRequest(
				tc.task, false, tc.resume, tc.human, "",
				tc.milestone, false, 0, false, true,
				t.TempDir(), t.TempDir(),
			)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("want error for %s; got %+v", tc.name, req)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if req.Mode != tc.wantMode {
				t.Fatalf("want mode=%q; got %q", tc.wantMode, req.Mode)
			}
		})
	}
}

func TestBuildRunRequestRequiresTekhtonHome(t *testing.T) {
	t.Setenv("TEKHTON_HOME", "")
	_, err := buildRunRequest(
		"task", false, false, false, "", "", false, 0, false, true,
		t.TempDir(), "",
	)
	if err == nil {
		t.Fatalf("expected error for missing tekhton-home")
	}
	if !strings.Contains(err.Error(), "TEKHTON_HOME") {
		t.Fatalf("error %q missing TEKHTON_HOME hint", err.Error())
	}
}

func TestBuildRunRequestAutoAdvanceWithoutMilestone(t *testing.T) {
	_, err := buildRunRequest(
		"task", false, false, false, "", "", true, 0, false, true,
		t.TempDir(), t.TempDir(),
	)
	if err == nil {
		t.Fatalf("expected validation error: auto-advance requires milestone mode")
	}
}

func TestBuildRunRequestPropagatesFlags(t *testing.T) {
	req, err := buildRunRequest(
		"", true, false, false, "", "m9", true, 7, true, true,
		t.TempDir(), t.TempDir(),
	)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !req.Complete || !req.AutoAdvance || req.AutoAdvanceLimit != 7 || !req.DryRun || !req.NoTUI {
		t.Fatalf("flag propagation: %+v", req)
	}
}

func TestRunCommandHasFlags(t *testing.T) {
	c := newRunCmd()
	for _, name := range []string{"task", "complete", "resume", "human", "human-tag", "milestone", "auto-advance", "auto-advance-limit", "dry-run", "no-tui"} {
		if c.Flags().Lookup(name) == nil {
			t.Fatalf("flag --%s missing", name)
		}
	}
}

func TestSuggestionsFromArgs(t *testing.T) {
	cases := []struct {
		name        string
		args        []string
		autoAdvance bool
		want        []string
	}{
		{
			name:        "v3_auto_advance_syntax",
			args:        []string{"3", "M23"},
			autoAdvance: true,
			want: []string{
				"did you mean `--auto-advance-limit 3`?",
				"did you mean `--milestone M23`?",
			},
		},
		{
			name:        "bare_int_without_auto_advance_is_task",
			args:        []string{"3"},
			autoAdvance: false,
			want:        []string{"did you mean `--task \"3\"`?"},
		},
		{
			name:        "lowercase_milestone_id",
			args:        []string{"m9"},
			autoAdvance: false,
			want:        []string{"did you mean `--milestone m9`?"},
		},
		{
			name:        "free_form_task",
			args:        []string{"Add OAuth login"},
			autoAdvance: false,
			want:        []string{"did you mean `--task \"Add OAuth login\"`?"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := suggestionsFromArgs(tc.args, tc.autoAdvance)
			if len(got) != len(tc.want) {
				t.Fatalf("len got=%d want=%d (%v)", len(got), len(tc.want), got)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("[%d] got=%q want=%q", i, got[i], tc.want[i])
				}
			}
		})
	}
}
