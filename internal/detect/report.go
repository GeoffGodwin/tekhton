package detect

import (
	"fmt"
	"strings"
)

// Render emits the markdown report for s, byte-for-byte equivalent to
// lib/detect_report.sh::format_detection_report when m29.2 lands the
// remaining detectors. In m29.1 only the Languages, Frameworks, and
// Project Type sections come from Go; every other section is rendered
// as "(none detected)" because the detectors that would populate them
// have not yet ported. The bash report formatter remains the canonical
// path for full end-to-end output through m29.1's close.
//
// Whitespace is load-bearing — `echo ""` blank lines in the bash source
// map to a single `\n` here so the parity gate's diff against the
// frozen bash baselines stays clean.
func Render(s *Summary) string {
	var b strings.Builder
	fmt.Fprintln(&b, "## Tech Stack Detection Report")
	fmt.Fprintln(&b)
	fmt.Fprintf(&b, "### Project Type: %s\n", s.ProjectType())
	fmt.Fprintln(&b)

	renderLanguages(&b, s.Languages)
	renderFrameworks(&b, s.Frameworks)
	renderCommands(&b, s.Commands)
	renderEntryPoints(&b, s.EntryPoints)
	renderWorkspaces(&b, s.Workspaces)
	renderServices(&b, s.Services)
	renderCI(&b, s.CI)
	renderInfrastructure(&b, s.Infrastructure)
	renderTestFrameworks(&b, s.TestFrameworks)
	renderDocQuality(&b, s.DocQuality)
	return b.String()
}

func renderLanguages(b *strings.Builder, langs []Language) {
	fmt.Fprintln(b, "### Languages")
	fmt.Fprintln(b, "| Language | Confidence | Manifest |")
	fmt.Fprintln(b, "|----------|------------|----------|")
	if len(langs) == 0 {
		fmt.Fprintln(b, "| (none detected) | — | — |")
	} else {
		for _, l := range langs {
			fmt.Fprintf(b, "| %s | %s | %s |\n", l.Name, l.Confidence, l.Manifest)
		}
	}
	fmt.Fprintln(b)
}

func renderFrameworks(b *strings.Builder, fws []Framework) {
	fmt.Fprintln(b, "### Frameworks")
	if len(fws) == 0 {
		fmt.Fprintln(b, "(none detected)")
	} else {
		fmt.Fprintln(b, "| Framework | Language | Evidence |")
		fmt.Fprintln(b, "|-----------|----------|----------|")
		for _, f := range fws {
			fmt.Fprintf(b, "| %s | %s | %s |\n", f.Name, f.Language, f.Evidence)
		}
	}
	fmt.Fprintln(b)
}

func renderCommands(b *strings.Builder, cmds []Command) {
	fmt.Fprintln(b, "### Detected Commands")
	if len(cmds) == 0 {
		fmt.Fprintln(b, "(none detected)")
	} else {
		fmt.Fprintln(b, "| Type | Command | Source | Confidence |")
		fmt.Fprintln(b, "|------|---------|--------|------------|")
		for _, c := range cmds {
			fmt.Fprintf(b, "| %s | `%s` | %s | %s |\n", c.Type, c.Command, c.Source, c.Confidence)
		}
	}
	fmt.Fprintln(b)
}

func renderEntryPoints(b *strings.Builder, eps []EntryPoint) {
	fmt.Fprintln(b, "### Entry Points")
	if len(eps) == 0 {
		fmt.Fprintln(b, "(none detected)")
	} else {
		for _, ep := range eps {
			fmt.Fprintf(b, "- `%s`\n", ep.Path)
		}
	}
	fmt.Fprintln(b)
}

func renderWorkspaces(b *strings.Builder, ws []Workspace) {
	if len(ws) == 0 {
		return
	}
	fmt.Fprintln(b, "### Workspaces / Monorepo")
	fmt.Fprintln(b, "| Type | Manifest | Subprojects |")
	fmt.Fprintln(b, "|------|----------|-------------|")
	for _, w := range ws {
		// Bash: count excludes any "...(N more)" overflow marker.
		count := 0
		for _, s := range w.Subprojects {
			if !strings.Contains(s, "...") {
				count++
			}
		}
		fmt.Fprintf(b, "| %s | %s | %d (%s) |\n", w.Type, w.Manifest,
			count, strings.Join(w.Subprojects, ","))
	}
	fmt.Fprintln(b)
}

func renderServices(b *strings.Builder, svcs []Service) {
	if len(svcs) == 0 {
		return
	}
	fmt.Fprintln(b, "### Services")
	fmt.Fprintln(b, "| Service | Directory | Tech Stack | Source |")
	fmt.Fprintln(b, "|---------|-----------|------------|--------|")
	for _, s := range svcs {
		fmt.Fprintf(b, "| %s | %s | %s | %s |\n", s.Name, s.Directory, s.TechStack, s.Source)
	}
	fmt.Fprintln(b)
}

func renderCI(b *strings.Builder, cis []CIConfig) {
	if len(cis) == 0 {
		return
	}
	fmt.Fprintln(b, "### CI/CD Configuration")
	fmt.Fprintln(b, "| CI System | Build | Test | Lint | Deploy | Confidence |")
	fmt.Fprintln(b, "|-----------|-------|------|------|--------|------------|")
	dash := func(s string) string {
		if s == "" {
			return "-"
		}
		return s
	}
	for _, c := range cis {
		fmt.Fprintf(b, "| %s | %s | %s | %s | %s | %s |\n",
			c.System, dash(c.Build), dash(c.Test), dash(c.Lint), dash(c.Deploy), dash(c.Confidence))
	}
	fmt.Fprintln(b)
}

func renderInfrastructure(b *strings.Builder, items []InfraItem) {
	if len(items) == 0 {
		return
	}
	fmt.Fprintln(b, "### Infrastructure as Code")
	fmt.Fprintln(b, "| Tool | Path | Provider | Confidence |")
	fmt.Fprintln(b, "|------|------|----------|------------|")
	for _, i := range items {
		fmt.Fprintf(b, "| %s | %s | %s | %s |\n", i.Tool, i.Path, i.Provider, i.Confidence)
	}
	fmt.Fprintln(b)
}

func renderTestFrameworks(b *strings.Builder, tfs []TestFW) {
	if len(tfs) == 0 {
		return
	}
	fmt.Fprintln(b, "### Test Frameworks")
	fmt.Fprintln(b, "| Framework | Config File | Confidence |")
	fmt.Fprintln(b, "|-----------|-------------|------------|")
	for _, t := range tfs {
		fmt.Fprintf(b, "| %s | %s | %s |\n", t.Name, t.Config, t.Confidence)
	}
	fmt.Fprintln(b)
}

func renderDocQuality(b *strings.Builder, dq *DocQuality) {
	if dq == nil {
		return
	}
	fmt.Fprintln(b, "### Documentation Quality")
	fmt.Fprintln(b)
	fmt.Fprintf(b, "**Score: %d/100**\n", dq.Score)
	fmt.Fprintln(b)
	for _, d := range dq.Details {
		if d == "" {
			continue
		}
		fmt.Fprintf(b, "- %s\n", d)
	}
	fmt.Fprintln(b)
}
