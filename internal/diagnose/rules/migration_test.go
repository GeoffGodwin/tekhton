package rules

import (
	"path/filepath"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/diagnose"
)

func TestMigrationCrash_Match(t *testing.T) {
	t.Parallel()
	t.Run("LAST_FAILURE_CONTEXT MIGRATION_FAILURE → high", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "LAST_FAILURE_CONTEXT.json"),
			`{"classification":"MIGRATION_FAILURE","migration_from":"3","migration_to":"4"}`)
		d, ok := MigrationCrash{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "intake"})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceHigh {
			t.Fatalf("conf: want high, got %s", d.Confidence)
		}
	})
	t.Run("backup dir + no version pin → medium", func(t *testing.T) {
		dir := t.TempDir()
		d, ok := MigrationCrash{}.Match(&diagnose.Context{
			ProjectDir:       dir,
			Stage:            "intake",
			MigrationBackups: []string{"/tmp/pre-1"},
		})
		if !ok {
			t.Fatal("want match")
		}
		if d.Confidence != diagnose.ConfidenceMedium {
			t.Fatalf("conf: want medium, got %s", d.Confidence)
		}
	})
	t.Run("pipeline.conf with version pin + backup → no match", func(t *testing.T) {
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "pipeline.conf"),
			"TEKHTON_CONFIG_VERSION=4.0\n")
		_, ok := MigrationCrash{}.Match(&diagnose.Context{
			ProjectDir:       dir,
			Stage:            "intake",
			MigrationBackups: []string{"/tmp/pre-1"},
		})
		if ok {
			t.Fatal("want no match (version pinned)")
		}
	})
	t.Run("no signal → no match", func(t *testing.T) {
		_, ok := MigrationCrash{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "intake"})
		if ok {
			t.Fatal("want no match")
		}
	})
}

func TestVersionMismatch_Match(t *testing.T) {
	// Cannot t.Parallel — uses t.Setenv.
	t.Run("config older than tekhton → match", func(t *testing.T) {
		t.Setenv("TEKHTON_VERSION", "4.32.0")
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "pipeline.conf"),
			"TEKHTON_CONFIG_VERSION=3.0\n")
		d, ok := VersionMismatch{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "intake"})
		if !ok {
			t.Fatal("want match")
		}
		if d.Classification != "VERSION_MISMATCH" {
			t.Fatalf("class drift: %s", d.Classification)
		}
		if d.Confidence != diagnose.ConfidenceMedium {
			t.Fatalf("conf: want medium, got %s", d.Confidence)
		}
	})
	t.Run("config matches tekhton → no match", func(t *testing.T) {
		t.Setenv("TEKHTON_VERSION", "4.32.0")
		dir := t.TempDir()
		writeFile(t, filepath.Join(dir, ".claude", "pipeline.conf"),
			"TEKHTON_CONFIG_VERSION=4.32\n")
		_, ok := VersionMismatch{}.Match(&diagnose.Context{ProjectDir: dir, Stage: "intake"})
		if ok {
			t.Fatal("want no match")
		}
	})
	t.Run("no pipeline.conf → no match", func(t *testing.T) {
		t.Setenv("TEKHTON_VERSION", "4.32.0")
		_, ok := VersionMismatch{}.Match(&diagnose.Context{ProjectDir: t.TempDir(), Stage: "intake"})
		if ok {
			t.Fatal("want no match")
		}
	})
}
