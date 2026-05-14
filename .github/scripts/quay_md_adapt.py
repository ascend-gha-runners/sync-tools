#!/usr/bin/env python3
"""Adapt markdown for quay.io's repository description renderer.

quay.io's Information tab uses react-markdown, but the deployed build does not
render GFM pipe tables — they collapse onto one line as literal text. Inline
HTML <table> tags are also stripped because rehype-raw is not enabled.

For each pipe table we pick the form that preserves the most information:

- If any cell contains a markdown link, render the table as a bullet list with
  inline-code padding so the first column still aligns visually while links
  remain clickable.
- Otherwise, render as a fenced code block — quay shows code blocks in a
  monospace font, so columns line up cleanly.

Usage: quay_md_adapt.py <input.md> <output.md>
"""
import re
import sys
import unicodedata
import pathlib

LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def parse_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", s)]


def is_separator(line: str) -> bool:
    s = line.strip()
    if not s.startswith("|"):
        return False
    cells = [c for c in parse_row(s) if c]
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", c) for c in cells)


def display_width(s: str) -> int:
    width = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        width += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return width


def has_link(rows: list[list[str]]) -> bool:
    return any(LINK_RE.search(cell) for row in rows for cell in row)


def render_codeblock(headers: list[str], rows: list[list[str]]) -> list[str]:
    n = len(headers)
    norm = [(r + [""] * n)[:n] for r in rows if any(r)]
    widths = [display_width(h) for h in headers]
    for r in norm:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], display_width(c))

    def fmt(cells: list[str]) -> str:
        return " | ".join(
            cells[i] + " " * (widths[i] - display_width(cells[i]))
            for i in range(n)
        ).rstrip()

    sep = "-+-".join("-" * w for w in widths)
    out = ["", "```", fmt(headers), sep]
    out.extend(fmt(r) for r in norm)
    out.append("```")
    out.append("")
    return out


def render_bullets(headers: list[str], rows: list[list[str]]) -> list[str]:
    n = len(headers)
    norm = [(r + [""] * n)[:n] for r in rows if any(r)]

    def first_col_width(cell: str) -> int:
        # Strip markdown link syntax to measure visible text.
        return display_width(LINK_RE.sub(r"\1", cell))

    pad = max((first_col_width(r[0]) for r in norm), default=0)

    out = ["", f"**{' / '.join(headers)}**", ""]
    for r in norm:
        first = r[0]
        rest = [c for c in r[1:] if c]
        first_padded = first + " " * (pad - first_col_width(first))
        # Wrap first column in inline code for monospace alignment, but only
        # if it has no markdown link of its own (links inside code are
        # rendered literally).
        if LINK_RE.search(first):
            line = f"- {first_padded}"
        else:
            line = f"- `{first_padded}`"
        if rest:
            line += " — " + " — ".join(rest)
        out.append(line)
    out.append("")
    return out


def render_table(headers: list[str], rows: list[list[str]]) -> list[str]:
    headers = [h for h in headers if h]
    if not headers:
        return []
    norm = [(r + [""] * len(headers))[: len(headers)] for r in rows if any(r)]
    if has_link(norm):
        return render_bullets(headers, norm)
    return render_codeblock(headers, norm)


def convert(md: str) -> str:
    lines = md.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        if (
            i + 1 < len(lines)
            and lines[i].lstrip().startswith("|")
            and is_separator(lines[i + 1])
        ):
            headers = parse_row(lines[i])
            j = i + 2
            rows: list[list[str]] = []
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                rows.append(parse_row(lines[j]))
                j += 1
            out.extend(render_table(headers, rows))
            i = j
        else:
            out.append(lines[i])
            i += 1
    return "\n".join(out)


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: quay_md_adapt.py <input.md> <output.md>", file=sys.stderr)
        sys.exit(2)
    src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    pathlib.Path(sys.argv[2]).write_text(convert(src), encoding="utf-8")


if __name__ == "__main__":
    main()
