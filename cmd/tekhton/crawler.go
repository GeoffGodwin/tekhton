package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/crawler"
	"github.com/spf13/cobra"
)

// newCrawlerCmd wires `tekhton crawler` — the Go entry point for the
// project crawler. Replaces the six lib/crawler*.sh files (m30.1) plus
// the two lib/rescan*.sh files (m30.2).
//
// Subcommands:
//   crawl      — full crawl; writes .claude/index/* artifacts.
//   inventory  — print inventory shape (--json for inventory.jsonl).
//   deps       — print dependency graph (--json for dependencies.json).
//   content    — print sampled file content (--json for samples manifest).
//   rescan     — incremental rescan (git-diff-driven); --full forces a
//                full crawl regardless of change detection.
//
// Hidden until the bash callers (init.sh, tekhton-legacy.sh) are fully
// migrated; users still go through tekhton.sh today.
func newCrawlerCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "crawler",
		Short:  "Project crawler — produce .claude/index/ artifacts (internal — developer tool)",
		Hidden: true,
		Long: "Internal Cobra root for the m30 crawler port. Subcommands " +
			"emit the structured artifact set (.claude/index/) consumed by " +
			"init, scout, rescan, and downstream agents.",
	}
	c.AddCommand(
		newCrawlerCrawlCmd(),
		newCrawlerInventoryCmd(),
		newCrawlerDepsCmd(),
		newCrawlerContentCmd(),
		newCrawlerRescanCmd(),
	)
	return c
}

// crawlerFlags is the shared flag set for the four read/write subcommands.
type crawlerFlags struct {
	projectDir string
	budget     int
	indexDir   string
	asJSON     bool
}

func (f *crawlerFlags) attach(c *cobra.Command, withJSON bool) {
	c.Flags().StringVar(&f.projectDir, "project-dir", "", "project root (defaults to cwd)")
	c.Flags().IntVar(&f.budget, "budget", 120_000, "total char budget for the index")
	c.Flags().StringVar(&f.indexDir, "index-dir", "", "override .claude/index path")
	if withJSON {
		c.Flags().BoolVar(&f.asJSON, "json", false, "emit JSON instead of human-readable text")
	}
}

func (f *crawlerFlags) options() (crawler.Options, error) {
	if f.projectDir == "" {
		dir, err := os.Getwd()
		if err != nil {
			return crawler.Options{}, fmt.Errorf("resolve cwd: %w", err)
		}
		f.projectDir = dir
	}
	return crawler.Options{
		ProjectDir:  f.projectDir,
		BudgetChars: f.budget,
		IndexDir:    f.indexDir,
		DesignFile:  os.Getenv("DESIGN_FILE"),
	}, nil
}

func newCrawlerCrawlCmd() *cobra.Command {
	var f crawlerFlags
	c := &cobra.Command{
		Use:   "crawl",
		Short: "Full crawl: write .claude/index/* artifacts",
		RunE: func(cmd *cobra.Command, _ []string) error {
			opts, err := f.options()
			if err != nil {
				return err
			}
			r, err := crawler.Crawl(context.Background(), opts)
			if err != nil {
				return fmt.Errorf("crawler: %w", err)
			}
			if f.asJSON {
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(crawlCLISummary{
					IndexDir:   r.IndexDir,
					FileCount:  r.FileCount,
					TotalLines: r.TotalLines,
					TreeLines:  r.TreeLines,
					DocQuality: r.DocQuality,
				})
			}
			fmt.Fprintf(cmd.OutOrStdout(),
				"crawler: wrote %s (%d files, %d total lines, %d tree lines, %d sample chars)\n",
				r.IndexDir, r.FileCount, r.TotalLines, r.TreeLines, r.SamplesUsed)
			return nil
		},
	}
	f.attach(c, true)
	return c
}

func newCrawlerInventoryCmd() *cobra.Command {
	var f crawlerFlags
	c := &cobra.Command{
		Use:   "inventory",
		Short: "Print file inventory (--json for inventory.jsonl shape)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			opts, err := f.options()
			if err != nil {
				return err
			}
			files := crawler.ListTrackedFiles(opts.ProjectDir)
			inv := crawler.BuildFileInventory(opts.ProjectDir, files)
			if f.asJSON {
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(inv)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "files: %d\n", len(inv.Entries))
			return nil
		},
	}
	f.attach(c, true)
	return c
}

func newCrawlerDepsCmd() *cobra.Command {
	var f crawlerFlags
	c := &cobra.Command{
		Use:   "deps",
		Short: "Print dependency graph (--json for dependencies.json shape)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			opts, err := f.options()
			if err != nil {
				return err
			}
			g, _ := crawler.ParseDependencies(opts.ProjectDir)
			if f.asJSON {
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(g)
			}
			fmt.Fprintf(cmd.OutOrStdout(),
				"manifests: %d, key dependencies: %d\n",
				len(g.Manifests), len(g.KeyDependencies))
			return nil
		},
	}
	f.attach(c, true)
	return c
}

func newCrawlerContentCmd() *cobra.Command {
	var f crawlerFlags
	c := &cobra.Command{
		Use:   "content",
		Short: "Print sampled file content (--json for samples/manifest.json shape)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			opts, err := f.options()
			if err != nil {
				return err
			}
			files := crawler.ListTrackedFiles(opts.ProjectDir)
			budget := opts.BudgetChars * 55 / 100
			samples := crawler.SampleFiles(opts.ProjectDir, files, budget, opts.DesignFile)
			if f.asJSON {
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				return enc.Encode(samples)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "samples: %d\n", len(samples))
			return nil
		},
	}
	f.attach(c, true)
	return c
}

func newCrawlerRescanCmd() *cobra.Command {
	var (
		f         crawlerFlags
		full      bool
		indexFile string
	)
	c := &cobra.Command{
		Use:   "rescan",
		Short: "Incremental rescan — update .claude/index/ from git-diff since last scan",
		Long: "Performs the git-diff-driven decision tree from rescan.sh. Falls " +
			"back to a full crawl when the index is missing, the project is not " +
			"a git repository, the recorded scan commit was rebased away, or " +
			"the change set is major (2+ manifests, 5+ new dirs, 10+ deletions). " +
			"--full forces a full crawl regardless.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			base, err := f.options()
			if err != nil {
				return err
			}
			opts := crawler.RescanOptions{
				ProjectDir:  base.ProjectDir,
				BudgetChars: base.BudgetChars,
				IndexDir:    base.IndexDir,
				DesignFile:  base.DesignFile,
				ForceFull:   full,
				IndexFile:   indexFile,
			}
			result, err := crawler.Rescan(context.Background(), opts)
			if err != nil {
				return fmt.Errorf("crawler: %w", err)
			}
			emitRescanSummary(cmd, result, f.asJSON)
			return nil
		},
	}
	f.attach(c, true)
	c.Flags().BoolVar(&full, "full", false, "force full crawl regardless of change detection")
	c.Flags().StringVar(&indexFile, "index-file", "",
		"override PROJECT_INDEX_FILE path (default .tekhton/PROJECT_INDEX.md)")
	return c
}

// rescanCLISummary is the JSON shape printed by `tekhton crawler rescan --json`.
// Mirrors crawlCLISummary's design — flat keys, no nesting, distinct
// from the package-internal RescanResult so the wire shape stays stable
// across rescan refactors.
type rescanCLISummary struct {
	Mode            string   `json:"mode"`
	FallbackReason  string   `json:"fallback_reason,omitempty"`
	Significance    string   `json:"significance,omitempty"`
	ChangeCount     int      `json:"change_count"`
	Regenerated     []string `json:"regenerated_sections,omitempty"`
	FullCrawlFiles  int      `json:"full_crawl_files,omitempty"`
	FullCrawlLines  int      `json:"full_crawl_total_lines,omitempty"`
}

// emitRescanSummary writes the human-readable or --json output for a
// RescanResult. Mirrors the bash log lines (`Index is up to date`,
// `Found N changed files`, etc.) on the human-readable branch.
func emitRescanSummary(cmd *cobra.Command, r *crawler.RescanResult, asJSON bool) {
	if asJSON {
		summary := rescanCLISummary{
			Mode:           r.Mode,
			FallbackReason: r.FallbackReason,
			Significance:   r.Significance.String(),
			ChangeCount:    len(r.Changes),
			Regenerated:    r.RegeneratedSections,
		}
		if r.FullCrawl != nil {
			summary.FullCrawlFiles = r.FullCrawl.FileCount
			summary.FullCrawlLines = r.FullCrawl.TotalLines
		}
		enc := json.NewEncoder(cmd.OutOrStdout())
		enc.SetIndent("", "  ")
		_ = enc.Encode(summary)
		return
	}
	switch r.Mode {
	case "noop":
		fmt.Fprintln(cmd.OutOrStdout(), "Index is up to date.")
	case "full":
		if r.FallbackReason != "" {
			fmt.Fprintf(cmd.OutOrStdout(), "Full crawl (%s): wrote .claude/index/\n", r.FallbackReason)
		} else {
			fmt.Fprintln(cmd.OutOrStdout(), "Full crawl (forced): wrote .claude/index/")
		}
	case "incremental":
		fmt.Fprintf(cmd.OutOrStdout(),
			"Incremental rescan (%s): %d changed file(s); regenerated %d section(s)\n",
			r.Significance.String(), len(r.Changes), len(r.RegeneratedSections))
	default:
		fmt.Fprintf(cmd.OutOrStdout(), "Rescan completed (mode=%s)\n", r.Mode)
	}
}

// crawlCLISummary is the JSON payload printed by --json on `crawler crawl`.
// Distinct from the package-internal Result so test compares are stable.
type crawlCLISummary struct {
	IndexDir   string `json:"index_dir"`
	FileCount  int    `json:"file_count"`
	TotalLines int    `json:"total_lines"`
	TreeLines  int    `json:"tree_lines"`
	DocQuality int    `json:"doc_quality_score"`
}
