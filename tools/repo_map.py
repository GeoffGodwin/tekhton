#!/usr/bin/env python3
"""Tree-sitter repo map generator with PageRank ranking.

Parses source files, extracts definition/reference tags, builds a file
relationship graph, ranks by PageRank biased toward task-relevant files,
and emits a token-budgeted markdown repo map of signatures only.

Milestone 7 additions:
- --history-file: load task→file association history for personalized ranking
- --warm-cache: parse all files and populate tag cache without output
- Blended personalization: keyword (0.6) + history (0.3) + git recency (0.1)

Exit codes:
    0 — success (full map on stdout)
    1 — partial (some files failed, best-effort map on stdout)
    2 — fatal error (no output)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Optional

import networkx as nx

try:
    import pathspec
except ImportError:
    pathspec = None  # type: ignore[assignment]

from tag_cache import TagCache
from tree_sitter_languages import get_parser, supported_extensions, ext_to_language_name, extensions_for_languages

# Characters per token estimate (conservative, matches v2 CHARS_PER_TOKEN)
CHARS_PER_TOKEN = 4

# Common stop words filtered from task keywords
_STOP_WORDS = frozenset(
    "a an the is are was were be been being have has had do does did "
    "will would shall should may might can could to for from in on at "
    "by with of and or not no but if then else so this that these those "
    "it its my your our their he she they we you i me him her us them "
    "add create implement fix update change modify remove delete write "
    "make build run test check".split()
)


def _extract_task_keywords(task: str) -> list[str]:
    """Extract meaningful keywords from a task description."""
    words = re.findall(r"[a-zA-Z_][a-zA-Z0-9_]*", task.lower())
    return [w for w in words if w not in _STOP_WORDS and len(w) > 1]


def _walk_project_files(
    root: str, languages: Optional[str] = None
) -> list[str]:
    """Walk project tree, respecting .gitignore. Returns relative paths."""
    root_path = Path(root).resolve()

    # Try git ls-files first (most reliable .gitignore handling)
    try:
        import subprocess

        result = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=str(root_path),
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0 and result.stdout.strip():
            files = result.stdout.strip().splitlines()
            return _filter_by_extension(files, languages)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass

    # Fallback: manual walk with pathspec
    spec = None
    gitignore_path = root_path / ".gitignore"
    if pathspec and gitignore_path.exists():
        try:
            with open(gitignore_path, "r", encoding="utf-8") as f:
                spec = pathspec.PathSpec.from_lines("gitwildmatch", f)
        except OSError:
            pass

    files: list[str] = []
    for dirpath, dirnames, filenames in os.walk(str(root_path)):
        # Skip hidden directories and common junk
        dirnames[:] = [
            d
            for d in dirnames
            if not d.startswith(".")
            and d not in ("node_modules", "__pycache__", ".venv", "venv", "dist", "build")
        ]
        for fname in filenames:
            full = os.path.join(dirpath, fname)
            rel = os.path.relpath(full, str(root_path))
            if spec and spec.match_file(rel):
                continue
            files.append(rel)

    return _filter_by_extension(files, languages)


def _filter_by_extension(
    files: list[str], languages: Optional[str]
) -> list[str]:
    """Filter files to those with supported tree-sitter extensions."""
    exts = set(supported_extensions())

    # If specific languages requested, filter to those extensions only
    if languages and languages != "auto":
        requested = {l.strip() for l in languages.split(",")}
        exts = extensions_for_languages(requested)

    result = []
    for f in files:
        _, ext = os.path.splitext(f)
        if ext in exts:
            result.append(f)
    return result


# --- Tag extraction ----------------------------------------------------------


def _extract_tags(
    filepath: str, root: str, cache: TagCache
) -> Optional[dict[str, Any]]:
    """Parse a file with tree-sitter and extract definition/reference tags."""
    full_path = os.path.join(root, filepath)
    try:
        mtime = os.path.getmtime(full_path)
    except OSError:
        return None

    # Check cache
    cached = cache.get_tags(filepath, mtime)
    if cached is not None:
        return cached

    _, ext = os.path.splitext(filepath)
    parser = get_parser(ext)
    if parser is None:
        return None

    try:
        with open(full_path, "rb") as f:
            source = f.read()
    except OSError:
        return None

    import time
    t0 = time.monotonic()

    try:
        tree = parser.parse(source)
    except Exception:
        return None

    definitions: list[dict[str, Any]] = []
    references: list[dict[str, Any]] = []

    _walk_tree(tree.root_node, source, definitions, references, ext)

    parse_ms = (time.monotonic() - t0) * 1000.0

    tags = {
        "definitions": definitions,
        "references": references,
    }
    cache.set_tags(filepath, mtime, tags, parse_ms=parse_ms)
    return tags


def _walk_tree(
    node: Any,
    source: bytes,
    definitions: list[dict[str, Any]],
    references: list[dict[str, Any]],
    ext: str,
) -> None:
    """Recursively walk the AST extracting definitions and references."""
    ntype = node.type

    # --- Definitions ---
    if ntype in (
        "function_definition",       # Python, Ruby
        "function_declaration",      # JS, Go, C, Java
        "method_definition",         # JS classes, Ruby
        "method_declaration",        # Java, C#
        "arrow_function",            # JS/TS (when assigned)
    ):
        name = _get_name_child(node)
        sig = _extract_signature(node, source, ext)
        if name:
            definitions.append(
                {"name": name, "type": "function", "line": node.start_point[0] + 1, "signature": sig}
            )

    elif ntype in (
        "class_definition",          # Python
        "class_declaration",         # JS, Java, C#
        "struct_definition",         # Rust
        "type_declaration",          # Go
        "struct_specifier",          # C/C++
        "class_specifier",           # C++
    ):
        name = _get_name_child(node)
        if name:
            definitions.append(
                {"name": name, "type": "class", "line": node.start_point[0] + 1, "signature": f"class {name}"}
            )

    elif ntype in ("impl_item",):     # Rust
        name = _get_name_child(node)
        if name:
            definitions.append(
                {"name": name, "type": "class", "line": node.start_point[0] + 1, "signature": f"impl {name}"}
            )

    # --- References ---
    elif ntype == "call_expression":
        name = _get_call_name(node, source)
        if name:
            references.append({"name": name, "type": "call", "line": node.start_point[0] + 1})

    elif ntype in ("import_statement", "import_from_statement", "import_declaration"):
        names = _get_import_names(node, source)
        for n in names:
            references.append({"name": n, "type": "import", "line": node.start_point[0] + 1})

    # Recurse into children
    for child in node.children:
        _walk_tree(child, source, definitions, references, ext)


def _get_name_child(node: Any) -> Optional[str]:
    """Extract the name identifier from a definition node."""
    for child in node.children:
        if child.type in ("identifier", "name", "type_identifier", "property_identifier"):
            return child.text.decode("utf-8", errors="replace")
    return None


def _extract_signature(node: Any, source: bytes, ext: str) -> str:
    """Extract a clean function/method signature (no body)."""
    # Get the first line of the node as a rough signature
    start = node.start_byte
    # Find end of signature: first { or : or newline after params
    text = source[start:min(start + 500, len(source))].decode("utf-8", errors="replace")

    # Try to find the end of the signature line
    for i, ch in enumerate(text):
        if ch == "{":
            sig = text[:i].strip()
            return _clean_signature(sig)
        if ch == ":" and ext == ".py" and i > 0:
            # Python: def foo(x): or class Foo:
            # Accept colon only after closing paren or identifier char (not after comma/operator)
            before = text[:i].rstrip()
            if before.endswith(")") or (before and before[-1].isalnum()):
                sig = text[:i].strip()
                return _clean_signature(sig)
    # Fallback: first line
    first_line = text.split("\n")[0].rstrip()
    return _clean_signature(first_line)


def _clean_signature(sig: str) -> str:
    """Clean up a signature string."""
    # Remove decorators, comments, trailing colons
    sig = sig.rstrip(":").rstrip()
    # Remove leading whitespace
    sig = sig.strip()
    # Cap length
    if len(sig) > 200:
        sig = sig[:197] + "..."
    return sig


def _get_call_name(node: Any, source: bytes) -> Optional[str]:
    """Extract the function/method name from a call expression."""
    func = node.child_by_field_name("function")
    if func is None and node.children:
        func = node.children[0]
    if func is None:
        return None

    if func.type == "identifier":
        return func.text.decode("utf-8", errors="replace")
    if func.type in ("member_expression", "attribute"):
        # Get the last identifier (method name)
        for child in reversed(func.children):
            if child.type in ("identifier", "property_identifier"):
                return child.text.decode("utf-8", errors="replace")
    return None


def _get_import_names(node: Any, source: bytes) -> list[str]:
    """Extract imported names from import statements."""
    names: list[str] = []
    for child in node.children:
        if child.type in ("dotted_name", "identifier", "scoped_identifier"):
            name = child.text.decode("utf-8", errors="replace")
            # Take the last component of dotted names
            parts = name.split(".")
            names.append(parts[-1])
        elif child.type == "import_clause":
            for sub in child.children:
                if sub.type in ("identifier", "named_imports"):
                    name = sub.text.decode("utf-8", errors="replace")
                    names.append(name)
    return names


# --- Task history (Milestone 7) ---------------------------------------------


def _load_task_history(history_file: str) -> list[dict[str, Any]]:
    """Load task→file association records from a JSONL file.

    Skips malformed lines and records missing required fields.
    Returns a list of valid records (dicts with at least 'task' and 'files').
    """
    if not os.path.exists(history_file):
        return []

    records: list[dict[str, Any]] = []
    try:
        with open(history_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Require at minimum 'task' and 'files' keys
                if "task" in record and "files" in record:
                    records.append(record)
    except OSError:
        return []

    return records


def _compute_history_scores(
    task_keywords: list[str],
    history: list[dict[str, Any]],
) -> dict[str, float]:
    """Compute file relevance scores from historical task→file associations.

    Uses bag-of-words overlap between current task keywords and historical
    task descriptions. Files from similar past tasks get higher scores.
    Scores accumulate across multiple matching records.

    Returns: dict mapping filepath → relevance score (0.0 if no match).
    """
    if not task_keywords or not history:
        return {}

    keyword_set = set(task_keywords)
    scores: dict[str, float] = {}

    for record in history:
        hist_task = record.get("task", "")
        hist_keywords = set(_extract_task_keywords(hist_task))

        # Compute overlap
        overlap = keyword_set & hist_keywords
        if not overlap:
            continue

        # Score = fraction of current keywords that matched
        similarity = len(overlap) / len(keyword_set)

        for filepath in record.get("files", []):
            scores[filepath] = scores.get(filepath, 0.0) + similarity

    return scores


def _get_git_recency_scores(
    root: str,
    files: list[str],
) -> dict[str, float]:
    """Get git recency scores for files. Most recently modified = 1.0.

    Uses `git log --format=%at` to get last modification time per file.
    Returns normalized scores [0.0, 1.0]. Non-git repos return empty dict.
    """
    import subprocess

    try:
        # Get last commit timestamp for each file in one call
        result = subprocess.run(
            ["git", "log", "--format=%at", "--name-only", "--diff-filter=ACMR",
             "-n", "200", "--no-merges"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return {}
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return {}

    # Parse: timestamps alternate with blank-separated file lists
    file_times: dict[str, int] = {}
    current_time = 0
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            current_time = int(line)
        except ValueError:
            # It's a filename — record the first (most recent) time seen
            if line not in file_times:
                file_times[line] = current_time

    if not file_times:
        return {}

    # Normalize to [0.0, 1.0]
    max_time = max(file_times.values())
    min_time = min(file_times.values())
    time_range = max(max_time - min_time, 1)

    scores: dict[str, float] = {}
    for filepath in files:
        t = file_times.get(filepath)
        if t is not None:
            scores[filepath] = (t - min_time) / time_range
        # Files not in git history get no recency score (omitted from dict)

    return scores


# --- Graph building ----------------------------------------------------------


def _build_graph(
    all_tags: dict[str, dict[str, Any]]
) -> nx.DiGraph:
    """Build a directed file relationship graph from extracted tags."""
    g = nx.DiGraph()

    # Index: symbol name → set of files that define it
    symbol_to_files: dict[str, set[str]] = {}
    for filepath, tags in all_tags.items():
        g.add_node(filepath)
        for defn in tags.get("definitions", []):
            name = defn["name"]
            if name not in symbol_to_files:
                symbol_to_files[name] = set()
            symbol_to_files[name].add(filepath)

    # Build edges: file A references a symbol defined in file B → edge A→B
    for filepath, tags in all_tags.items():
        edge_weights: dict[str, int] = {}
        for ref in tags.get("references", []):
            name = ref["name"]
            defining_files = symbol_to_files.get(name, set())
            for def_file in defining_files:
                if def_file != filepath:
                    edge_weights[def_file] = edge_weights.get(def_file, 0) + 1
        for target, weight in edge_weights.items():
            g.add_edge(filepath, target, weight=weight)

    return g


# --- PageRank ranking --------------------------------------------------------


def _rank_files(
    graph: nx.DiGraph,
    task_keywords: list[str],
    all_files: list[str],
    history: Optional[list[dict[str, Any]]] = None,
    git_recency: Optional[dict[str, float]] = None,
) -> list[tuple[str, float]]:
    """Rank files by PageRank with blended personalization.

    Personalization weights (when history is available):
      - Task keyword matches: 0.6
      - Historical file relevance: 0.3
      - Git recency: 0.1

    Without history, falls back to keyword-only (0.9 keyword + 0.1 recency).
    Without git repo, keyword weight absorbs recency weight.
    """
    if not graph.nodes:
        return [(f, 1.0 / max(len(all_files), 1)) for f in all_files]

    # Compute component scores
    history_scores = _compute_history_scores(task_keywords, history or [])
    if git_recency is None:
        git_recency = {}

    # Determine weights based on available signals
    has_history = bool(history_scores)
    has_recency = bool(git_recency)

    if has_history and has_recency:
        w_keyword, w_history, w_recency = 0.6, 0.3, 0.1
    elif has_history:
        w_keyword, w_history, w_recency = 0.7, 0.3, 0.0
    elif has_recency:
        w_keyword, w_history, w_recency = 0.9, 0.0, 0.1
    else:
        w_keyword, w_history, w_recency = 1.0, 0.0, 0.0

    # Build personalization vector
    personalization: dict[str, float] = {}
    has_any_signal = False

    for node in graph.nodes:
        score = 0.0
        node_lower = node.lower()

        # Keyword signal
        parts = re.findall(r"[a-zA-Z_][a-zA-Z0-9_]*", node_lower)
        kw_score = 0.0
        for kw in task_keywords:
            if kw in node_lower or any(kw in p for p in parts):
                kw_score += 1.0
        if kw_score > 0:
            has_any_signal = True
        score += kw_score * w_keyword

        # History signal
        hist_score = history_scores.get(node, 0.0)
        if hist_score > 0:
            has_any_signal = True
        score += hist_score * w_history

        # Recency signal
        rec_score = git_recency.get(node, 0.0)
        score += rec_score * w_recency

        personalization[node] = max(score, 0.01)  # small floor to avoid zero

    if not has_any_signal:
        # No signals at all — uniform personalization (standard PageRank)
        personalization = {n: 1.0 for n in graph.nodes}

    # Normalize
    total = sum(personalization.values())
    if total > 0:
        personalization = {k: v / total for k, v in personalization.items()}

    try:
        scores = nx.pagerank(
            graph,
            alpha=0.85,
            personalization=personalization,
            max_iter=100,
            tol=1e-6,
            weight="weight",
        )
    except nx.PowerIterationFailedConvergence:
        # Fall back to uniform scores
        scores = {n: 1.0 / len(graph.nodes) for n in graph.nodes}

    # Include files that might not be in the graph (isolated files)
    for f in all_files:
        if f not in scores:
            scores[f] = 0.0

    ranked = sorted(scores.items(), key=lambda x: x[1], reverse=True)
    return ranked


# --- Output formatting -------------------------------------------------------


def _format_file_entry(filepath: str, tags: dict[str, Any]) -> str:
    """Format a single file's signatures as markdown."""
    lines = [f"## {filepath}"]
    definitions = tags.get("definitions", [])
    if not definitions:
        return ""

    # Group by class context (simple heuristic: methods after class def)
    current_indent = "  "
    for defn in definitions:
        sig = defn.get("signature", defn["name"])
        dtype = defn.get("type", "function")
        if dtype == "class":
            current_indent = "  "
            lines.append(f"{current_indent}{sig}")
            current_indent = "    "  # methods get extra indent
        else:
            lines.append(f"{current_indent}{sig}")

    return "\n".join(lines)


def _build_output(
    ranked: list[tuple[str, float]],
    all_tags: dict[str, dict[str, Any]],
    token_budget: int,
) -> str:
    """Assemble the final output, stopping when token budget is exhausted."""
    entries: list[str] = []
    current_tokens = 0

    for filepath, _score in ranked:
        tags = all_tags.get(filepath)
        if tags is None or not tags.get("definitions"):
            continue

        entry = _format_file_entry(filepath, tags)
        if not entry:
            continue

        entry_tokens = len(entry) // CHARS_PER_TOKEN
        if current_tokens + entry_tokens > token_budget and entries:
            break  # Budget exhausted (but always include at least one file)

        entries.append(entry)
        current_tokens += entry_tokens

    return "\n\n".join(entries) + "\n" if entries else ""


# --- Main --------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a ranked repo map using tree-sitter."
    )
    parser.add_argument("--root", required=True, help="Project root directory")
    parser.add_argument("--task", default="", help="Task description for ranking")
    parser.add_argument("--budget", type=int, default=2048, help="Token budget")
    parser.add_argument("--cache-dir", default=".cache", help="Cache directory")
    parser.add_argument("--languages", default="auto", help="Languages to index")
    parser.add_argument(
        "--files", default="", help="Comma-separated file list (slice mode)"
    )
    parser.add_argument(
        "--history-file", default="",
        help="Path to task_history.jsonl for personalized ranking"
    )
    parser.add_argument(
        "--warm-cache", action="store_true",
        help="Parse all files and populate tag cache, then exit (no output)"
    )
    parser.add_argument(
        "--stats", action="store_true",
        help="Print cache statistics as JSON to stderr after run"
    )

    args = parser.parse_args()
    root = os.path.abspath(args.root)

    if not os.path.isdir(root):
        print(f"Error: root directory not found: {root}", file=sys.stderr)
        return 2

    # Set up cache
    cache_dir = args.cache_dir
    if not os.path.isabs(cache_dir):
        cache_dir = os.path.join(root, cache_dir)
    os.makedirs(cache_dir, exist_ok=True)

    cache = TagCache(os.path.join(cache_dir, "tags.json"))
    cache.load()

    # Prune deleted files from cache on every run
    pruned = cache.prune_cache(root)
    if pruned > 0:
        print(f"Pruned {pruned} deleted file(s) from cache", file=sys.stderr)

    # Walk project files
    files = _walk_project_files(root, args.languages)
    if not files:
        print("Warning: no parseable files found", file=sys.stderr)
        return 2

    # --warm-cache mode: parse everything, save cache, exit
    if args.warm_cache:
        total = len(files)
        parsed = 0
        for i, filepath in enumerate(files):
            tags = _extract_tags(filepath, root, cache)
            if tags is not None:
                parsed += 1
            # Progress reporting every 100 files
            if (i + 1) % 100 == 0 or i + 1 == total:
                print(
                    f"  Warming cache: {i + 1}/{total} files ({parsed} parsed)...",
                    file=sys.stderr,
                )
        cache.save()
        if args.stats:
            print(json.dumps(cache.stats_dict()), file=sys.stderr)
        return 0

    # If --files specified, filter to those files only (slice mode)
    if args.files:
        requested = {f.strip() for f in args.files.split(",")}
        files = [f for f in files if f in requested]
        if not files:
            print("Warning: no matching files found for --files", file=sys.stderr)
            return 2

    # Extract tags from all files
    all_tags: dict[str, dict[str, Any]] = {}
    had_failures = False

    for filepath in files:
        tags = _extract_tags(filepath, root, cache)
        if tags is not None:
            all_tags[filepath] = tags
        else:
            had_failures = True

    # Save cache after extraction
    cache.save()

    if not all_tags:
        print("Warning: no files could be parsed", file=sys.stderr)
        return 2

    # Load task history for personalized ranking
    history: list[dict[str, Any]] = []
    if args.history_file and os.path.exists(args.history_file):
        history = _load_task_history(args.history_file)

    # Get git recency scores
    git_recency = _get_git_recency_scores(root, list(all_tags.keys()))

    # Build graph and rank
    keywords = _extract_task_keywords(args.task)
    graph = _build_graph(all_tags)
    ranked = _rank_files(
        graph, keywords, list(all_tags.keys()),
        history=history if history else None,
        git_recency=git_recency if git_recency else None,
    )

    # Generate output
    output = _build_output(ranked, all_tags, args.budget)
    if output:
        print(output, end="")

    # Print stats if requested
    if args.stats:
        print(json.dumps(cache.stats_dict()), file=sys.stderr)

    return 1 if had_failures else 0


if __name__ == "__main__":
    sys.exit(main())
