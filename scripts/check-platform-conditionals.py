#!/usr/bin/env python3
"""Ratchet on platform conditionals in the Apple clients' shared app layer.

usage: check-platform-conditionals.py [--root DIR] [--allowlist FILE] [--seed]

`apple/CabalmailUI/` is one module linked into every Apple app, and a layout or
OS difference belongs in one of two places: a layout shell (`Shell/`) or an OS
adapter (`Platform/`, and the UIKit/AppKit wrapper types). Everything else is
shared and reads `ShellLayout` or a `HostPlatform` capability instead of
compiling differently per OS. The files that still hold a platform `#if` are
listed, with their counts, in `apple/platform-conditionals-allowlist.txt`, and
the list may only shrink (docs/apple.md, "Platform conditionals").

The rule:

- Scope: every `.swift` file under `apple/CabalmailUI/` except `Shell/` and
  `Platform/`. The app targets are out of scope.
- What counts: a line that, after leading whitespace, starts with `#if` and
  whose condition contains `os(` or matches
  `canImport\\((UIKit|AppKit|EventKitUI)\\)`. `#elseif` and `#else` never count,
  and a nested `#if` counts on its own line. An `#elseif os(` arm added to an
  existing block is therefore not caught; review catches that.
- Exempt: a file declaring a struct, class or extension (outside comments)
  whose inheritance clause names `UIViewRepresentable`,
  `NSViewRepresentable`, `UIViewControllerRepresentable` or
  `NSViewControllerRepresentable` as a whole word. A `where` clause is not
  part of the inheritance clause.
- Ratchet: an unlisted file fails at its first counted line, and a listed
  file fails when its count rises above its row. A PR that lowers a count
  lowers or removes the row in the same change. A row left above its file's
  count is slack the next conditional could hide in, so it is reported (as a
  warning annotation in CI) but does not fail: two PRs that each lower the
  same row merge cleanly, and neither should turn the branch red.

`--seed` prints the allowlist the current tree would need, for a PR that
lowers counts to paste from. Standard library only, so it runs in the cloud
containers that have no Swift toolchain.
"""
import argparse
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCOPE = pathlib.PurePosixPath("apple/CabalmailUI")
EXEMPT_DIRS = ("Shell", "Platform")
ALLOWLIST = pathlib.PurePosixPath("apple/platform-conditionals-allowlist.txt")

IF_DIRECTIVE = re.compile(r"^\s*#if\b(?P<condition>.*)$")
PLATFORM_IMPORT = re.compile(r"canImport\((UIKit|AppKit|EventKitUI)\)")
WRAPPER_DECLARATION = re.compile(
    r"\b(?:struct|class|extension)\s+[\w.]+(?:<[^>{]*>)?\s*:(?P<clause>[^{]*)\{"
)
WHERE_CLAUSE = re.compile(r"\bwhere\b")
WRAPPER_PROTOCOL = re.compile(
    r"\b(?:UIViewRepresentable|NSViewRepresentable|"
    r"UIViewControllerRepresentable|NSViewControllerRepresentable)\b"
)


def counted_lines(source):
    """The 1-based line numbers of the platform `#if`s in `source`."""
    lines = []
    for number, line in enumerate(source.splitlines(), start=1):
        match = IF_DIRECTIVE.match(line)
        if not match:
            continue
        condition = match.group("condition")
        if "os(" in condition or PLATFORM_IMPORT.search(condition):
            lines.append(number)
    return lines


def strip_comments(source):
    """`source` with its comments blanked out and its string literals
    emptied, so a declaration named in a doc comment can't exempt a file.
    Swift block comments nest."""
    out = []
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end == -1 else end
        elif source.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if source.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif source.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            out.append(" ")
        elif source.startswith('"""', i):
            end = source.find('"""', i + 3)
            i = n if end == -1 else end + 3
            out.append('""')
        elif source[i] == '"':
            i += 1
            while i < n and source[i] not in '"\n':
                i += 2 if source[i] == "\\" else 1
            i += 1
            out.append('""')
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def is_wrapper(source):
    """Whether the file wraps a UIKit or AppKit view: such files are the OS
    adapter, so their conditionals are where they belong."""
    code = strip_comments(source)
    return any(
        WRAPPER_PROTOCOL.search(WHERE_CLAUSE.split(match.group("clause"), maxsplit=1)[0])
        for match in WRAPPER_DECLARATION.finditer(code)
    )


def in_scope(relative):
    """`relative` is a path under `SCOPE`."""
    return relative.suffix == ".swift" and relative.parts[0] not in EXEMPT_DIRS


def census(root):
    """{path under SCOPE: [counted line numbers]} for every file that counts."""
    base = root / SCOPE
    found = {}
    for path in sorted(base.rglob("*.swift")):
        relative = pathlib.PurePosixPath(path.relative_to(base).as_posix())
        if not in_scope(relative):
            continue
        source = path.read_text(encoding="utf-8")
        lines = counted_lines(source)
        if lines and not is_wrapper(source):
            found[str(relative)] = lines
    return found


def read_allowlist(path):
    """{path under SCOPE: count}. Blank lines and `#` comments are skipped."""
    rows = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            name, count = line.rsplit(None, 1)
            rows[name] = int(count)
        except ValueError:
            raise SystemExit(f"{path}:{number}: expected '<path> <count>', got {line!r}")
    return rows


def check(found, allowed):
    """The failures, one message each; empty when the tree is within the list."""
    failures = []
    for name, lines in found.items():
        path = SCOPE / name
        if name not in allowed:
            failures.append(
                f"{path}:{lines[0]}: platform #if outside Shell/ and Platform/. "
                "Read ShellLayout or a HostPlatform capability, or put the OS "
                "difference in a Platform/ adapter."
            )
        elif len(lines) > allowed[name]:
            failures.append(
                f"{path}:{lines[allowed[name]]}: {len(lines)} platform #ifs, the "
                f"allowlist allows {allowed[name]}. The list may only shrink."
            )
    return failures


def stale_rows(found, allowed):
    """Rows above their file's count, one message each. They don't fail the
    check; they are slack to take out of the list."""
    notes = []
    for name in sorted(allowed):
        count = len(found.get(name, ()))
        if count == 0:
            notes.append(f"{name} has no counted platform #ifs now; remove its row.")
        elif count < allowed[name]:
            notes.append(f"{name} has {count} platform #ifs now; lower its row from {allowed[name]} to {count}.")
    return notes


def seed(found):
    return "".join(f"{name} {len(lines)}\n" for name, lines in found.items())


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=pathlib.Path, default=ROOT, help="repository root")
    parser.add_argument("--allowlist", type=pathlib.Path, help="allowlist file (default: the repo's)")
    parser.add_argument("--seed", action="store_true", help="print the rows the current tree needs")
    args = parser.parse_args(argv)

    found = census(args.root)
    if args.seed:
        sys.stdout.write(seed(found))
        return 0
    allowed = read_allowlist(args.allowlist or args.root / ALLOWLIST)
    failures = check(found, allowed)
    for failure in failures:
        print(failure)
    # A GitHub Actions run shows these on the PR; elsewhere they are plain lines.
    prefix = f"::warning file={ALLOWLIST}::" if os.environ.get("GITHUB_ACTIONS") else f"{ALLOWLIST}: "
    for note in stale_rows(found, allowed):
        print(prefix + note)
    if failures:
        return 1
    total = sum(len(lines) for lines in found.values())
    print(f"platform conditionals: {len(found)} files, {total} blocks, all within the allowlist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
