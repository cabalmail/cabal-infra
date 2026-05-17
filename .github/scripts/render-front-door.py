#!/usr/bin/env python3
"""
Render the front door site by substituting ``{{VAR}}`` placeholders
with values from the environment.

Reads every file under ``front-door/`` and writes the result to
``front-door-rendered/``. Text files (html, css, js, svg, txt, xml,
json) are scanned for ``{{NAME}}`` tokens where ``NAME`` matches
``[A-Z][A-Z0-9_]*``; each match is replaced with ``os.environ[NAME]``.
Binary files are copied verbatim. Unknown placeholders are left in place
and surface as a GitHub Actions ``::warning::`` so a missing environment
variable is visible in the run summary without failing the deploy.

Invoked from ``.github/workflows/app.yml`` (front-door job). The
intent is that the operator (or a workflow step) sets the env vars they
want substituted before running this script; the matching ``{{VAR}}``
in the HTML/CSS/JS is then rewritten in place during the build.

Usage:
  render-front-door.py [src_dir] [dst_dir]

Defaults: src=front-door, dst=front-door-rendered.
"""

import os
import pathlib
import re
import shutil
import sys

TEXT_EXTS = {".html", ".css", ".js", ".svg", ".txt", ".xml", ".json"}
PLACEHOLDER = re.compile(r"\{\{([A-Z][A-Z0-9_]*)\}\}")


def render(src_root: pathlib.Path, dst_root: pathlib.Path) -> int:
    if not src_root.is_dir():
        print(f"error: source directory not found: {src_root}", file=sys.stderr)
        return 1

    if dst_root.exists():
        shutil.rmtree(dst_root)
    dst_root.mkdir(parents=True)

    missing: dict[str, list[str]] = {}

    for src in src_root.rglob("*"):
        if src.is_dir():
            continue
        rel = src.relative_to(src_root)
        dst = dst_root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)

        if src.suffix.lower() not in TEXT_EXTS:
            shutil.copy2(src, dst)
            continue

        text = src.read_text(encoding="utf-8")
        file_missing: set[str] = set()

        def replace(match: re.Match) -> str:
            name = match.group(1)
            value = os.environ.get(name)
            if value is None:
                file_missing.add(name)
                return match.group(0)
            return value

        rendered = PLACEHOLDER.sub(replace, text)
        dst.write_text(rendered, encoding="utf-8")

        if file_missing:
            for name in sorted(file_missing):
                missing.setdefault(name, []).append(str(rel))

    if missing:
        for name in sorted(missing):
            files = ", ".join(sorted(missing[name]))
            print(
                f"::warning::no env value for placeholder {{{{{name}}}}} "
                f"(files: {files}); left literal in output",
                file=sys.stderr,
            )

    return 0


if __name__ == "__main__":
    src = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path("front-door")
    dst = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else pathlib.Path("front-door-rendered")
    sys.exit(render(src, dst))
