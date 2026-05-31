package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/geoffgodwin/tekhton/internal/crawler"
	"github.com/spf13/cobra"
)

// newCrawlerCmd wires `tekhton crawler` — the m30.1 Go entry point for
// the project crawler. Replaces the six lib/crawler*.sh files deleted in
// the same milestone.
//
// Subcommands:
//   crawl      — full crawl; writes .claude/index/* artifacts.
//   inventory  — print inventory shape (--json for inventory.jsonl).
//   deps       — print dependency graph (--json for dependencies.json).
//   content    — print sampled file content (--json for samples manifest).
//   rescan     — m30.2 placeholder; errors with ErrRescanNotImplemented.
//
// Hidden until the bash callers (init.sh, rescan.sh, tekhton-legacy.sh)
// are fully migrated; users still go through tekhton.sh today.
func newCrawlerCmd() *cobra.Command {
	c := &cobra.Command{
		Use:    "crawler",
		Short:  "Project crawler — produce .claude/index/ artifacts (internal — developer tool)",
		Hidden: true,
		Long: "Internal Cobra root for the m30.1 crawler port. Subcommands " +
			"emit the structured artifact set (.claude/index/) consumed by " +
			"init, scout, rescan, and downstream agents. The rescan subcommand " +
			"is a m30.2 placeholder.",
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
	c := &cobra.Command{
		Use:   "rescan",
		Short: "Incremental rescan (NOT IMPLEMENTED in m30.1 — see m30.2)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintln(cmd.ErrOrStderr(),
				"crawler: rescan is a m30.2 placeholder. Use `tekhton crawler crawl` for now.")
			return errExitCode{code: 1, err: errors.New("rescan: not yet implemented (m30.2)")}
		},
	}
	return c
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
