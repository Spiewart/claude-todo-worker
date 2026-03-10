#!/usr/bin/env python3
"""Pre-commit hook: regenerate the Patches section of TODO.md.

Language-agnostic. Scans source files for:
  - Lines containing ``TODO`` comments (e.g. ``# TODO:``, ``// TODO:``)
  - Functions/methods that raise not-implemented stubs

Rebuilds everything between ``## Patches`` and ``## Features`` in TODO.md,
preserving the Features section and the file header verbatim.

Based on the knee-acoustic-emissions project's update_todo_patches.py,
generalised for multi-language repositories.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys

# ── Defaults ────────────────────────────────────────────────────────

REPO_ROOT = Path.cwd()

DEFAULT_EXCLUDE_DIRS = {
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    "migrations",
    "vendor",
    "build",
    "dist",
    ".git",
    ".claude",
    ".tox",
    ".eggs",
    "egg-info",
    ".next",
    "coverage",
    "target",        # Rust / Java
    "out",
}

# ── Language-specific patterns ──────────────────────────────────────
#
# Each entry maps a file extension to a dict with:
#   todo_re:      compiled regex matching TODO comment lines
#   stub_re:      compiled regex matching not-implemented stubs (or None)
#   func_re:      compiled regex matching function/method declarations
#   docstring_re: compiled regex matching docstring openers (or None)

def _build_todo_re(prefix: str) -> re.Pattern[str]:
    """Build a TODO regex for a given comment prefix (e.g. '#' or '//')."""
    escaped = re.escape(prefix)
    return re.compile(rf"{escaped}\s*TODO[:\s]+(.+)", re.IGNORECASE)


LANG: dict[str, dict] = {}

# Python
_py = {
    "todo_re": _build_todo_re("#"),
    "stub_re": re.compile(r"raise\s+NotImplementedError\("),
    "func_re": re.compile(r"\s*def\s+(\w+)\s*\("),
    "docstring_re": re.compile(r'''^\s*(?:"""|\'\'\')\s*(.*)'''),
}
for ext in (".py", ".pyi"):
    LANG[ext] = _py

# JavaScript / TypeScript
_js = {
    "todo_re": _build_todo_re("//"),
    "stub_re": re.compile(r"throw\s+new\s+Error\(\s*['\"]not\s+implemented", re.IGNORECASE),
    "func_re": re.compile(
        r"(?:"
        r"(?:export\s+)?(?:async\s+)?function\s+(\w+)"  # function declarations
        r"|(?:const|let|var)\s+(\w+)\s*="                # arrow / assigned functions
        r"|(\w+)\s*\([^)]*\)\s*\{"                       # method shorthand
        r")"
    ),
    "docstring_re": None,
}
for ext in (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"):
    LANG[ext] = _js

# Go
LANG[".go"] = {
    "todo_re": _build_todo_re("//"),
    "stub_re": re.compile(r'panic\(\s*"not\s+implemented', re.IGNORECASE),
    "func_re": re.compile(r"\s*func\s+(?:\([^)]+\)\s+)?(\w+)\s*\("),
    "docstring_re": None,
}

# Rust
LANG[".rs"] = {
    "todo_re": _build_todo_re("//"),
    "stub_re": re.compile(r"(?:todo|unimplemented)!\s*\("),
    "func_re": re.compile(r"\s*(?:pub\s+)?(?:async\s+)?fn\s+(\w+)"),
    "docstring_re": None,
}

# Ruby
LANG[".rb"] = {
    "todo_re": _build_todo_re("#"),
    "stub_re": re.compile(r"raise\s+NotImplementedError"),
    "func_re": re.compile(r"\s*def\s+(\w+)"),
    "docstring_re": None,
}

# Java / Kotlin
_java = {
    "todo_re": _build_todo_re("//"),
    "stub_re": re.compile(r"throw\s+new\s+UnsupportedOperationException\("),
    "func_re": re.compile(
        r"(?:public|private|protected|static|\s)*\s+\w+\s+(\w+)\s*\("
    ),
    "docstring_re": None,
}
LANG[".java"] = _java
LANG[".kt"] = {
    **_java,
    "stub_re": re.compile(r"TODO\(\)"),
    "func_re": re.compile(r"\s*(?:fun|suspend\s+fun)\s+(\w+)"),
}

# Swift
LANG[".swift"] = {
    "todo_re": _build_todo_re("//"),
    "stub_re": re.compile(r"fatalError\("),
    "func_re": re.compile(r"\s*func\s+(\w+)"),
    "docstring_re": None,
}

# C / C++ / Header files
_c = {
    "todo_re": _build_todo_re("//"),
    "stub_re": None,
    "func_re": re.compile(r"\w+\s+(\w+)\s*\([^)]*\)\s*\{"),
    "docstring_re": None,
}
for ext in (".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hxx"):
    LANG[ext] = _c

# Shell / YAML / TOML (comment-only, no stubs or functions)
_hash_comment = {
    "todo_re": _build_todo_re("#"),
    "stub_re": None,
    "func_re": re.compile(r"(\w+)\s*\(\)\s*\{"),  # shell functions
    "docstring_re": None,
}
for ext in (".sh", ".bash", ".zsh", ".yaml", ".yml", ".toml"):
    LANG[ext] = _hash_comment

# ── Scanning helpers ────────────────────────────────────────────────


def _rel(path: Path, root: Path) -> str:
    """Return a POSIX-style path relative to the repo root."""
    return path.relative_to(root).as_posix()


def _github_link(path: Path, line: int, root: Path, end_line: int | None = None) -> str:
    rel = _rel(path, root)
    if end_line and end_line != line:
        return f"[{rel}:{line}-{end_line}]({rel}#L{line}-L{end_line})"
    return f"[{rel}:{line}]({rel}#L{line})"


def _find_enclosing_function(
    lines: list[str], line_idx: int, func_re: re.Pattern[str]
) -> str | None:
    """Walk backwards to find the nearest function declaration above *line_idx*."""
    for i in range(line_idx - 1, -1, -1):
        m = func_re.search(lines[i])
        if m:
            # Return the first non-None group (different patterns have different groups)
            for g in m.groups():
                if g:
                    return g
    return None


def _read_docstring_summary(
    lines: list[str], def_idx: int, docstring_re: re.Pattern[str] | None
) -> str | None:
    """Read the first non-empty line of the docstring after a def."""
    if docstring_re is None:
        return None
    for i in range(def_idx + 1, min(def_idx + 8, len(lines))):
        stripped = lines[i].strip()
        if stripped.startswith('"""') or stripped.startswith("'''"):
            # Single-line docstring
            doc = stripped.strip("\"'").strip()
            if doc:
                return doc
            # Multi-line: grab the next line
            for j in range(i + 1, min(i + 4, len(lines))):
                doc = lines[j].strip().strip("\"'").strip()
                if doc:
                    return doc
            return None
    return None


# ── Data structures ─────────────────────────────────────────────────


class PatchItem:
    """A single patch entry (TODO comment or not-implemented stub)."""

    def __init__(
        self,
        file: Path,
        line: int,
        description: str,
        *,
        root: Path,
        end_line: int | None = None,
        func_name: str | None = None,
    ) -> None:
        self.file = file
        self.line = line
        self.end_line = end_line
        self.description = description
        self.func_name = func_name
        self._root = root

    @property
    def module(self) -> str:
        """Top-level directory name (e.g. 'src', 'lib', 'core')."""
        rel = self.file.relative_to(self._root)
        return rel.parts[0] if len(rel.parts) > 1 else "root"

    def to_markdown(self) -> str:
        link = _github_link(self.file, self.line, self._root, self.end_line)
        title = f"`{self.func_name}()`" if self.func_name else "TODO"
        return f"- **{title}** — {self.description}\n  {link}\n"


# ── Scanner ─────────────────────────────────────────────────────────


def _should_skip_dir(name: str, exclude_dirs: set[str]) -> bool:
    """Return True if directory name should be skipped."""
    return name in exclude_dirs or name.startswith(".")


def scan_patches(
    root: Path,
    scan_dirs: list[Path],
    exclude_dirs: set[str],
) -> list[PatchItem]:
    items: list[PatchItem] = []

    for scan_dir in scan_dirs:
        if not scan_dir.is_dir():
            continue

        for source_file in sorted(scan_dir.rglob("*")):
            # Skip excluded directories
            if any(_should_skip_dir(p, exclude_dirs) for p in source_file.relative_to(root).parts[:-1]):
                continue

            ext = source_file.suffix
            if ext not in LANG:
                continue

            lang = LANG[ext]
            todo_re = lang["todo_re"]
            stub_re = lang["stub_re"]
            func_re = lang["func_re"]
            docstring_re = lang.get("docstring_re")

            try:
                lines = source_file.read_text(errors="replace").splitlines()
            except (OSError, UnicodeDecodeError):
                continue

            i = 0
            while i < len(lines):
                line = lines[i]

                # ── Multi-line TODO comments ────────────────────
                m = todo_re.search(line)
                if m:
                    desc_parts = [m.group(1).strip().rstrip(".,")]
                    start_line = i + 1  # 1-indexed
                    # Collect continuation TODO lines
                    j = i + 1
                    while j < len(lines):
                        m2 = todo_re.search(lines[j])
                        if m2:
                            desc_parts.append(m2.group(1).strip().rstrip(".,"))
                            j += 1
                        else:
                            break
                    end_line = j  # 1-indexed (exclusive → last matched)
                    func_name = _find_enclosing_function(lines, i, func_re)
                    items.append(
                        PatchItem(
                            source_file,
                            start_line,
                            ". ".join(desc_parts),
                            root=root,
                            end_line=end_line if end_line != start_line else None,
                            func_name=func_name,
                        )
                    )
                    i = j
                    continue

                # ── Not-implemented stubs ───────────────────────
                if stub_re and stub_re.search(line):
                    func_name = _find_enclosing_function(lines, i, func_re)
                    if func_name:
                        # Find the def/func line for docstring extraction
                        for k in range(i - 1, -1, -1):
                            if func_re.search(lines[k]):
                                def_line = k
                                break
                        else:
                            def_line = i
                        doc = _read_docstring_summary(lines, def_line, docstring_re) or ""
                        stub_label = _stub_label(ext)
                        desc = f"Raises `{stub_label}`. {doc}".strip()
                    else:
                        stub_label = _stub_label(ext)
                        desc = f"Raises `{stub_label}`."
                    items.append(
                        PatchItem(
                            source_file,
                            i + 1,
                            desc,
                            root=root,
                            func_name=func_name,
                        )
                    )
                i += 1

    return items


def _stub_label(ext: str) -> str:
    """Human-readable label for the stub type."""
    labels = {
        ".py": "NotImplementedError",
        ".pyi": "NotImplementedError",
        ".rb": "NotImplementedError",
        ".rs": "todo!/unimplemented!",
        ".kt": "TODO()",
        ".swift": "fatalError",
        ".go": "panic",
        ".java": "UnsupportedOperationException",
    }
    return labels.get(ext, "not implemented")


# ── Markdown generation ─────────────────────────────────────────────


def group_by_module(items: list[PatchItem]) -> dict[str, list[PatchItem]]:
    groups: dict[str, list[PatchItem]] = {}
    for item in items:
        groups.setdefault(item.module, []).append(item)
    return groups


def build_patches_section(items: list[PatchItem]) -> str:
    if not items:
        return "## Patches\n\n_No TODO comments or not-implemented stubs found._\n"

    parts = ["## Patches\n"]
    parts.append(
        "Code-level TODOs and stubs that need attention in existing modules.\n"
    )

    for module, group in group_by_module(items).items():
        heading = module.replace("_", " ").replace("-", " ").title()
        parts.append(f"### {heading}\n")
        for item in group:
            parts.append(item.to_markdown())

    return "\n".join(parts)


# ── File rewriting ──────────────────────────────────────────────────

FEATURES_MARKER = "## Features"
PATCHES_MARKER = "## Patches"


def rewrite_todo_md(todo_path: Path, patches_md: str) -> bool:
    """Rewrite TODO.md, returning True if the content changed."""
    if not todo_path.exists():
        print("TODO.md not found — skipping patch update.", file=sys.stderr)
        return False

    content = todo_path.read_text()

    # Find section boundaries
    patches_start = content.find(PATCHES_MARKER)
    features_start = content.find(FEATURES_MARKER)

    if patches_start == -1 or features_start == -1:
        print(
            "TODO.md missing ## Patches or ## Features marker — skipping.",
            file=sys.stderr,
        )
        return False

    header = content[:patches_start]
    features_section = content[features_start:]

    new_content = header + patches_md + "\n---\n\n" + features_section

    if new_content == content:
        return False

    todo_path.write_text(new_content)
    return True


# ── CLI ─────────────────────────────────────────────────────────────


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Regenerate the Patches section of TODO.md from source code TODOs.",
    )
    parser.add_argument(
        "--scan-dirs",
        default="",
        help="Comma-separated directories to scan (relative to repo root). "
        "Default: scan entire repo root.",
    )
    parser.add_argument(
        "--exclude-dirs",
        default="",
        help="Comma-separated directories to exclude. "
        f"Default: {','.join(sorted(DEFAULT_EXCLUDE_DIRS))}",
    )
    parser.add_argument(
        "--repo-root",
        default="",
        help="Repository root directory. Default: current working directory.",
    )
    parser.add_argument(
        "--todo-file",
        default="TODO.md",
        help="Path to TODO.md (relative to repo root). Default: TODO.md",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    root = Path(args.repo_root).resolve() if args.repo_root else REPO_ROOT.resolve()

    # Determine scan directories
    if args.scan_dirs:
        scan_dirs = [root / d.strip() for d in args.scan_dirs.split(",") if d.strip()]
    else:
        scan_dirs = [root]

    # Determine exclude directories
    if args.exclude_dirs:
        exclude_dirs = {d.strip() for d in args.exclude_dirs.split(",") if d.strip()}
    else:
        exclude_dirs = DEFAULT_EXCLUDE_DIRS.copy()

    todo_path = root / args.todo_file

    items = scan_patches(root, scan_dirs, exclude_dirs)
    patches_md = build_patches_section(items)
    changed = rewrite_todo_md(todo_path, patches_md)
    if changed:
        print(f"TODO.md updated ({len(items)} patch items found).")
        # Exit 1 so pre-commit re-stages the modified file
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
