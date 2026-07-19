#!/usr/bin/env python3
"""Guard production codex timeout defaults behind the workflow resolver."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Callable, Iterable

CODEX_SPAWN_RE = re.compile(r"\bspawn_codex(?:_sync)?\s*\(")
NUMERIC_TIMEOUT_RE = re.compile(r"\btimeout\s*=\s*(?:\d+\s*(?:\*\s*\d+\s*)*)")
CODEX_TIMEOUT_CONST_RE = re.compile(
    r"\b(?:local\s+)?(?=[A-Za-z_][A-Za-z0-9_]*\s*=)(?=[A-Za-z0-9_]*codex_timeout)[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?:\d+\s*(?:\*\s*\d+\s*)*)",
    re.IGNORECASE,
)


def matching_lua_paren(text: str, open_index: int) -> int | None:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def codex_timeout_literal_lines(
    text: str,
    strip_lua_comments_and_strings: Callable[[str], str],
) -> list[int]:
    stripped = strip_lua_comments_and_strings(text)
    lines: set[int] = set()
    for match in CODEX_TIMEOUT_CONST_RE.finditer(stripped):
        lines.add(text.count("\n", 0, match.start()) + 1)
    for spawn in CODEX_SPAWN_RE.finditer(stripped):
        close = matching_lua_paren(stripped, spawn.end() - 1)
        if close is None:
            continue
        body = stripped[spawn.end() : close]
        for match in NUMERIC_TIMEOUT_RE.finditer(body):
            lines.add(text.count("\n", 0, spawn.end() + match.start()) + 1)
    return sorted(lines)


def repository_messages(
    root: Path,
    package_lua_files: Callable[[Path], Iterable[tuple[Path, Path]]],
    read_text: Callable[[Path], str],
    rel: Callable[[Path, Path], str],
    strip_lua_comments_and_strings: Callable[[str], str],
) -> list[str]:
    messages: list[str] = []
    for packages, path in package_lua_files(root):
        package_relative = path.relative_to(packages)
        if "tests" in package_relative.parts:
            continue
        for line in codex_timeout_literal_lines(read_text(path), strip_lua_comments_and_strings):
            messages.append(
                f"{rel(root, path)}:{line} production codex timeout defaults must come from workflow_internal.codex"
            )
    return messages
