package provider

import (
	"bufio"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Profile captures per-provider request adaptation (m22). The zero value means
// no adaptation — Claude and Codex use it. Only smaller local models
// (qwen-local) carry a non-zero built-in profile.
type Profile struct {
	MaxTurnsFactor      float64 // scales req.MaxTurns; 0 or 1 means no change
	ContextBudgetPct    int     // overrides CONTEXT_BUDGET_PCT; 0 = inherit
	MaxPromptChars      int     // hard clamp on the request prompt; 0 = none
	FormatReinforcement string  // prepended to request prompt content; "" = none
}

// defaultPromptTokenCap is the conservative usable-context target for a
// 32B-class local model at Q4 on 24GB-VRAM-class hardware (~24k tokens).
// Converted to chars via CHARS_PER_TOKEN at lookup time.
const defaultPromptTokenCap = 24000

// ProfileFor returns the resolved profile for a provider name: the built-in
// default merged with any .claude/provider_profiles/<name>.conf overrides
// (flat KEY=value). Unknown or malformed lines warn to stderr and are skipped
// — an override file never fails the run.
func ProfileFor(name string) Profile {
	p := builtinProfile(name)
	mergeProfileOverrides(&p, name)
	return p
}

// builtinProfile is the hardcoded conservative default per provider.
func builtinProfile(name string) Profile {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "qwen-local":
		return Profile{
			MaxTurnsFactor:   1.5,
			ContextBudgetPct: 25,
			MaxPromptChars:   defaultPromptTokenCap * charsPerToken(),
			FormatReinforcement: "IMPORTANT: Respond only with valid tool calls or strictly valid JSON. " +
				"Do not wrap tool calls in prose or markdown fences.",
		}
	default:
		return Profile{}
	}
}

// charsPerToken reads CHARS_PER_TOKEN (default 4) — the same conservative ratio
// the bash context layer uses.
func charsPerToken() int {
	if v := os.Getenv("CHARS_PER_TOKEN"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return 4
}

// mergeProfileOverrides applies .claude/provider_profiles/<name>.conf on top of
// p. Missing file is a no-op. PROJECT_DIR anchors the lookup.
func mergeProfileOverrides(p *Profile, name string) {
	dir := os.Getenv("PROJECT_DIR")
	if dir == "" {
		dir = "."
	}
	path := filepath.Join(dir, ".claude", "provider_profiles", strings.ToLower(strings.TrimSpace(name))+".conf")
	f, err := os.Open(path) // #nosec G304 -- operator-owned project config
	if err != nil {
		return // no override file
	}
	defer func() { _ = f.Close() }()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			fmt.Fprintf(os.Stderr, "[provider-profile] %s: skipping malformed line (no '='): %q\n", name, line)
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(strings.Trim(strings.TrimSpace(v), `"'`))
		switch k {
		case "MAX_TURNS_FACTOR":
			if n, err := strconv.ParseFloat(v, 64); err == nil && n > 0 {
				p.MaxTurnsFactor = n
			} else {
				fmt.Fprintf(os.Stderr, "[provider-profile] %s: bad MAX_TURNS_FACTOR %q — keeping %.2f\n", name, v, p.MaxTurnsFactor)
			}
		case "CONTEXT_BUDGET_PCT":
			if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 100 {
				p.ContextBudgetPct = n
			} else {
				fmt.Fprintf(os.Stderr, "[provider-profile] %s: bad CONTEXT_BUDGET_PCT %q — keeping %d\n", name, v, p.ContextBudgetPct)
			}
		case "MAX_PROMPT_CHARS":
			if n, err := strconv.Atoi(v); err == nil && n >= 0 {
				p.MaxPromptChars = n
			} else {
				fmt.Fprintf(os.Stderr, "[provider-profile] %s: bad MAX_PROMPT_CHARS %q — keeping %d\n", name, v, p.MaxPromptChars)
			}
		case "FORMAT_REINFORCEMENT":
			p.FormatReinforcement = v
		default:
			fmt.Fprintf(os.Stderr, "[provider-profile] %s: ignoring unknown key %q\n", name, k)
		}
	}
}

// Apply returns a copy of req with the profile applied: MaxTurns scaled
// (rounded up), FormatReinforcement prepended to the prompt, then the prompt
// clamped to MaxPromptChars. The second return is a non-empty clamp note when
// truncation occurred (for the caller to log); the request prompt FILE on disk
// is never touched — adaptation is request-level only (parity rule 6).
func (p Profile) Apply(req *Request) (*Request, string) {
	if req == nil {
		return req, ""
	}
	out := *req // shallow copy; we only mutate scalar/string fields

	if p.MaxTurnsFactor > 0 && p.MaxTurnsFactor != 1.0 && out.MaxTurns > 0 {
		out.MaxTurns = int(math.Ceil(float64(out.MaxTurns) * p.MaxTurnsFactor))
	}
	if p.FormatReinforcement != "" {
		out.Prompt = p.FormatReinforcement + "\n\n" + out.Prompt
	}
	note := ""
	if p.MaxPromptChars > 0 && len(out.Prompt) > p.MaxPromptChars {
		orig := len(out.Prompt)
		out.Prompt = out.Prompt[:p.MaxPromptChars]
		note = fmt.Sprintf("provider profile: clamped prompt %d -> %d chars", orig, p.MaxPromptChars)
	}
	return &out, note
}
