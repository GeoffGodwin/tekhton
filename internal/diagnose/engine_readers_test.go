// engine_readers_test.go covers the private line-based JSON reader functions
// in engine.go: extractJSONString, extractJSONInt, parseCauseBlock, and
// extractKVLine. These functions are exercised only transitively through
// TestReadContext_FailureContextPopulatesClassification in the existing suite;
// direct table-driven coverage is added here per the m32.1 reviewer gap report.

package diagnose

import "testing"

// --- extractJSONString -------------------------------------------------------

func TestExtractJSONString(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		text string
		key  string
		want string
	}{
		{
			name: "normal key-value",
			text: `{"classification":"BUILD_FAILURE","stage":"coder"}`,
			key:  "classification",
			want: "BUILD_FAILURE",
		},
		{
			name: "whitespace around colon",
			text: `{ "outcome" : "failure" }`,
			key:  "outcome",
			want: "failure",
		},
		{
			name: "key absent",
			text: `{"stage":"coder"}`,
			key:  "classification",
			want: "",
		},
		{
			name: "empty text",
			text: "",
			key:  "classification",
			want: "",
		},
		{
			name: "empty value",
			text: `{"classification":""}`,
			key:  "classification",
			want: "",
		},
		{
			name: "first match wins when key repeated",
			text: `{"classification":"FIRST","other":"x","classification":"SECOND"}`,
			key:  "classification",
			want: "FIRST",
		},
		{
			name: "malformed — no closing quote on value",
			text: `{"classification":"UNCLOSED}`,
			key:  "classification",
			want: "",
		},
		{
			name: "malformed — integer value not matched by string reader",
			text: `{"schema_version":2}`,
			key:  "schema_version",
			want: "",
		},
		{
			name: "nested object — picks sibling key not object brace",
			text: `{
  "primary_cause": {
    "category": "CODE"
  },
  "stage": "coder"
}`,
			key:  "stage",
			want: "coder",
		},
		{
			name: "value with spaces inside quotes",
			text: `{"task":"Port the diagnose engine to Go"}`,
			key:  "task",
			want: "Port the diagnose engine to Go",
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := extractJSONString(tc.text, tc.key)
			if got != tc.want {
				t.Errorf("extractJSONString(%q, %q): want %q got %q", tc.text, tc.key, tc.want, got)
			}
		})
	}
}

// --- extractJSONInt ----------------------------------------------------------

func TestExtractJSONInt(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		text string
		key  string
		want int
	}{
		{
			name: "normal integer",
			text: `{"schema_version":2}`,
			key:  "schema_version",
			want: 2,
		},
		{
			name: "whitespace around colon",
			text: `{ "consecutive_count" : 5 }`,
			key:  "consecutive_count",
			want: 5,
		},
		{
			name: "zero value",
			text: `{"review_cycles":0}`,
			key:  "review_cycles",
			want: 0,
		},
		{
			name: "key absent returns negative one",
			text: `{"stage":"coder"}`,
			key:  "schema_version",
			want: -1,
		},
		{
			name: "empty text returns negative one",
			text: "",
			key:  "schema_version",
			want: -1,
		},
		{
			name: "string value for integer key not matched",
			text: `{"schema_version":"two"}`,
			key:  "schema_version",
			want: -1,
		},
		{
			name: "large integer",
			text: `{"rework_cycles":100}`,
			key:  "rework_cycles",
			want: 100,
		},
		{
			name: "first match wins when key repeated",
			text: `{"consecutive_count":3,"other":"x","consecutive_count":7}`,
			key:  "consecutive_count",
			want: 3,
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := extractJSONInt(tc.text, tc.key)
			if got != tc.want {
				t.Errorf("extractJSONInt(%q, %q): want %d got %d", tc.text, tc.key, tc.want, got)
			}
		})
	}
}

// --- parseCauseBlock ---------------------------------------------------------

func TestParseCauseBlock(t *testing.T) {
	t.Parallel()

	// helper captures parseCauseBlock output into a struct for readability.
	type causeResult struct {
		cat, sub, sig, src string
	}
	parse := func(text, blockKey string) causeResult {
		var cat, sub, sig, src string
		parseCauseBlock(text, blockKey, &cat, &sub, &sig, &src)
		return causeResult{cat, sub, sig, src}
	}

	cases := []struct {
		name string
		text string
		key  string
		want causeResult
	}{
		{
			name: "all four fields present",
			text: `{
  "primary_cause": {
    "category": "CODE",
    "subcategory": "compile",
    "signal": "ts2304",
    "source": "compile_phase"
  }
}`,
			key:  "primary_cause",
			want: causeResult{"CODE", "compile", "ts2304", "compile_phase"},
		},
		{
			name: "secondary_cause in same document",
			text: `{
  "primary_cause": {
    "category": "CODE",
    "subcategory": "compile",
    "signal": "ts2304",
    "source": "compile_phase"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "turn_limit_hit",
    "source": "agent_monitor"
  }
}`,
			key:  "secondary_cause",
			want: causeResult{"AGENT_SCOPE", "max_turns", "turn_limit_hit", "agent_monitor"},
		},
		{
			name: "block key absent",
			text: `{"outcome":"failure"}`,
			key:  "primary_cause",
			want: causeResult{},
		},
		{
			name: "block with no opening brace",
			text: `"primary_cause": "invalid"`,
			key:  "primary_cause",
			want: causeResult{},
		},
		{
			name: "block with no closing brace",
			text: `{"primary_cause": {"category": "CODE"`,
			key:  "primary_cause",
			want: causeResult{},
		},
		{
			name: "only category field present",
			text: `{
  "primary_cause": {
    "category": "UPSTREAM"
  }
}`,
			key:  "primary_cause",
			want: causeResult{cat: "UPSTREAM"},
		},
		{
			name: "category and signal but not subcategory or source",
			text: `{
  "primary_cause": {
    "category": "ENVIRONMENT",
    "signal": "oom_kill"
  }
}`,
			key:  "primary_cause",
			want: causeResult{cat: "ENVIRONMENT", sig: "oom_kill"},
		},
		{
			name: "multi-value nested — second cause block does not pollute first",
			text: `{
  "primary_cause": {
    "category": "CODE",
    "subcategory": "compile",
    "signal": "ts2304",
    "source": "compiler"
  },
  "secondary_cause": {
    "category": "UPSTREAM",
    "subcategory": "api_rate_limit",
    "signal": "rate_limited",
    "source": "api_proxy"
  }
}`,
			key:  "primary_cause",
			want: causeResult{"CODE", "compile", "ts2304", "compiler"},
		},
		{
			name: "empty block body",
			text: `{"primary_cause":{}}`,
			key:  "primary_cause",
			want: causeResult{},
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := parse(tc.text, tc.key)
			if got != tc.want {
				t.Errorf("parseCauseBlock(key=%q):\nwant %+v\n got %+v", tc.key, tc.want, got)
			}
		})
	}
}

// --- extractKVLine -----------------------------------------------------------

func TestExtractKVLine(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		line     string
		wantKey  string
		wantVal  string
		wantOK   bool
	}{
		{
			name:    "empty line",
			line:    "",
			wantOK:  false,
		},
		{
			name:    "line with no quotes",
			line:    "category: CODE",
			wantOK:  false,
		},
		{
			name:    "key with string value",
			line:    `    "category": "CODE"`,
			wantKey: "category",
			wantVal: "CODE",
			wantOK:  true,
		},
		{
			name:    "key with integer value — key extracted, value empty",
			line:    `    "schema_version": 2`,
			wantKey: "schema_version",
			wantVal: "",
			wantOK:  true,
		},
		{
			name:    "key with empty string value",
			line:    `    "signal": ""`,
			wantKey: "signal",
			wantVal: "",
			wantOK:  true,
		},
		{
			name:    "key with underscore in name",
			line:    `    "sub_category": "compile"`,
			wantKey: "sub_category",
			wantVal: "compile",
			wantOK:  true,
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			gotKey, gotVal, gotOK := extractKVLine(tc.line)
			if gotOK != tc.wantOK {
				t.Fatalf("extractKVLine(%q): ok: want %v got %v", tc.line, tc.wantOK, gotOK)
			}
			if !tc.wantOK {
				return
			}
			if gotKey != tc.wantKey {
				t.Errorf("key: want %q got %q", tc.wantKey, gotKey)
			}
			if gotVal != tc.wantVal {
				t.Errorf("val: want %q got %q", tc.wantVal, gotVal)
			}
		})
	}
}
