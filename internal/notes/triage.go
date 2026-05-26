package notes

import (
	"fmt"
	"hash/crc32"
	"regexp"
	"strings"
)

// TriageDisposition is the outcome of triaging a single note. Mirrors
// the bash `_TRIAGE_DISPOSITION` global values.
type TriageDisposition string

const (
	// TriageFit means the note fits within a normal coder run budget.
	TriageFit TriageDisposition = "fit"
	// TriageOversized means the note exceeds the heuristic threshold
	// and should be promoted to a milestone.
	TriageOversized TriageDisposition = "oversized"
)

// TriageConfidence is the heuristic engine's self-rating. Low
// confidence triggers agent escalation in the bash original. The Go
// port surfaces it but leaves the escalation decision to the caller
// (CLI / pipeline).
type TriageConfidence string

const (
	TriageHigh TriageConfidence = "high"
	TriageLow  TriageConfidence = "low"
)

// TriageResult records the heuristic verdict on a note. Mirrors the
// `_TRIAGE_*` bash globals: disposition, estimated turns, confidence,
// plus the raw score for callers that want to debug threshold tuning.
type TriageResult struct {
	NoteID      string
	Disposition TriageDisposition
	EstTurns    int
	Confidence  TriageConfidence
	Score       int
}

// scope keywords (+3 each) — direct port of the bash `_TRIAGE_SCOPE_KEYWORDS`.
var triageScopeKeywords = []string{
	"rewrite", "redesign", "migrate", "new system",
	"replace", "overhaul", "refactor entire", "add support for",
}

// scale indicators (+2 each) — direct port of `_TRIAGE_SCALE_INDICATORS`.
var triageScaleIndicators = []*regexp.Regexp{
	regexp.MustCompile(`\ball\b`),
	regexp.MustCompile(`\bevery\b`),
	regexp.MustCompile(`\bentire\b`),
	regexp.MustCompile(`across the codebase`),
}

// HeuristicScore returns the triage score for the given note text/tag.
// Mirrors `_triage_heuristic_score` from lib/notes_triage.sh. Score is
// floored at 0; confidence is reported separately so callers can
// decide whether to escalate.
func HeuristicScore(text, tag string) (score int, confidence TriageConfidence) {
	lower := strings.ToLower(text)
	for _, kw := range triageScopeKeywords {
		if strings.Contains(lower, kw) {
			score += 3
		}
	}
	for _, re := range triageScaleIndicators {
		if re.MatchString(lower) {
			score += 2
		}
	}
	if len(text) > 120 {
		score++
	}
	switch tag {
	case "BUG":
		score -= 2
	case "POLISH":
		score--
	}
	if score < 0 {
		score = 0
	}
	switch {
	case score >= 5:
		confidence = TriageHigh
	case score <= 1:
		confidence = TriageHigh
	default:
		confidence = TriageLow
	}
	return score, confidence
}

// TriageNote evaluates a single note and returns a structured verdict.
// Mirrors the heuristic path of `triage_note` from lib/notes_triage.sh.
// Agent escalation is not invoked here — the bash version called
// `_triage_agent_escalation` for low-confidence verdicts; the Go port
// exposes the heuristic outcome and lets the CLI/pipeline decide
// whether to spawn the agent.
//
// Returns an empty Result when the note has no ID (the bash version
// keyed everything on ID-based metadata storage).
func TriageNote(n *Note) TriageResult {
	res := TriageResult{NoteID: n.ID}
	if n.ID == "" {
		res.Disposition = TriageFit
		return res
	}
	// Cached triage path: if the metadata has a triage value AND the
	// text hash matches, reuse the cached result.
	cached := n.Metadata["triage"]
	cachedHash := n.Metadata["text_hash"]
	currentHash := textHash(n.Title)
	if cached != "" && cachedHash == currentHash {
		res.Disposition = TriageDisposition(cached)
		res.Confidence = TriageHigh
		if v := n.Metadata["est_turns"]; v != "" {
			res.EstTurns = parseInt(v)
		}
		return res
	}
	score, conf := HeuristicScore(n.Title, n.Tag)
	res.Score = score
	res.Confidence = conf
	switch {
	case score >= 5:
		res.Disposition = TriageOversized
		res.EstTurns = score * 5
	case score <= 1:
		res.Disposition = TriageFit
		res.EstTurns = (score + 1) * 3
	default:
		// Mid-band: bash defaults to "fit" pending agent verdict.
		res.Disposition = TriageFit
		res.EstTurns = (score + 1) * 3
	}
	return res
}

// textHash returns a short stable hash for change-detection — used by
// the cached-triage path. Bash used `cksum`; Go uses CRC32 over the
// same input bytes for a comparable (not byte-identical) signature.
// The hash is local to the triage cache, so the algorithm choice is
// not user-visible.
func textHash(s string) string {
	return fmt.Sprintf("%08x", crc32.ChecksumIEEE([]byte(s)))
}

// parseInt is a tiny zero-fail integer parser used by the triage
// metadata reload path. Returns 0 on any failure — the bash version
// silently dropped malformed values.
func parseInt(s string) int {
	v := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0
		}
		v = v*10 + int(c-'0')
	}
	return v
}

// TriageReport runs TriageNote across every Pending note in the
// document (optionally tag-filtered) and returns the verdicts. Used
// by `tekhton note triage` and by the pipeline's `triage_bulk_warn`
// equivalent. Empty filter → all tags.
func TriageReport(d *Document, filterTag string) []TriageResult {
	if d == nil {
		return nil
	}
	var out []TriageResult
	for _, n := range d.Notes {
		if n.State != Pending {
			continue
		}
		if filterTag != "" && n.Tag != filterTag {
			continue
		}
		out = append(out, TriageNote(n))
	}
	return out
}
