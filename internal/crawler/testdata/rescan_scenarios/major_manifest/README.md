# Major manifest scenario

Fixture for the rescan major-change path. The harness edits TWO
manifests (package.json AND Cargo.toml) — `manifestChanges >= 2`
classifies as major and triggers a full crawl fallback.
