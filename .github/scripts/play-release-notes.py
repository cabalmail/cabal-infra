#!/usr/bin/env python3
#
# Write the Play Console release notes for the Android build being uploaded.
#
# gradle-play-publisher (android.yml's upload job) attaches release notes from
# files in the app source tree - app/src/main/play/release-notes/<locale>/
# <track>.txt, falling back to default.txt - and there is no API-side hook to
# set them after the fact, so this script writes that file just before
# `publishBundle` runs. It is the Android counterpart of set-testflight-notes.py.
#
# Scope: prod releases only. android.yml gates the calling step on
# `github.ref_name == 'main'`: on stage the top CHANGELOG.md section is still
# the *previous* release (fragments are collated only at promotion), so notes
# derived there would be stale. The stage upload ships without notes, like the
# TestFlight stage track.
#
# Source of the notes: the top `## [x.y.z]` section of CHANGELOG.md, narrowed
# to entries prefixed `Android:` (the convention CLAUDE.md and
# changelog.d/README.md describe, enforced for Android client PRs by
# android-changelog.yml). Google Play caps release notes at 500 characters per
# locale - an eighth of App Store Connect's field - so, unlike the TestFlight
# notes, only each entry's bold **headline** survives, never the body. The
# output leads with a pointer at CHANGELOG.md for the details, then lists the
# headlines under their category, e.g.:
#
#     See CHANGELOG.md for details.
#
#     Added:
#     - First alpha - not yet for production use
#     - Compose with on-the-fly From and drafts
#
# If the headlines still overrun the cap, whole trailing lines are dropped
# (never a mid-line cut) with a `::warning::` naming what fell off. A release
# with no Android-scoped entries gets generic maintenance text so the field is
# never blank.
#
# Usage:
#   play-release-notes.py [--changelog CHANGELOG.md] [--out PATH] [--max 500]
#
# With no --out the notes are printed to stdout, which is also how the unit
# tests (scripts/tests/test_play_release_notes.py) and a curious operator
# preview them.

import argparse
import os
import re
import sys

PLAY_NOTES_MAX = 500  # Google Play's cap on release notes, per locale.

# Changelog bullets meant for Android testers are prefixed `Android:`.
ANDROID_PREFIX = re.compile(r"^Android:\s*")

# The bold noun-phrase headline that opens every entry, per the house style:
# `- Android: **Headline.** details...`. A trailing period inside the bold is
# dropped; the details after it never make the notes.
HEADLINE = re.compile(r"^\*\*(.+?)\.?\*\*")

LEAD = "See CHANGELOG.md for details."
FALLBACK_NOTES = "No Android-specific changes in this release. " + LEAD


def warn(message):
    """Emit a GitHub Actions warning annotation (plain text elsewhere)."""
    print(f"::warning::{message}", file=sys.stderr)


def top_section(lines):
    """Return the lines of the first `## [x.y.z]` section, heading excluded."""
    start = None
    for index, line in enumerate(lines):
        if re.match(r"^## \[\d+\.\d+\.\d+\]", line):
            start = index
            break
    if start is None:
        raise RuntimeError("no version section found in CHANGELOG.md")
    section = []
    for line in lines[start + 1:]:
        if re.match(r"^## \[\d+\.\d+\.\d+\]", line):
            break
        section.append(line)
    return section


def tokenize(section):
    """Parse a changelog section into ("heading", text) / ("bullet", text).

    Rejoins hard-wrapped bullets (two-space continuation indent) into single
    lines, the same shape set-testflight-notes.py works from.
    """
    tokens = []
    current = None

    def flush():
        nonlocal current
        if current is not None:
            tokens.append(("bullet", current))
            current = None

    for line in section:
        if not line.strip():
            flush()
            continue
        heading = re.match(r"^### (.+?):?$", line)
        if heading:
            flush()
            tokens.append(("heading", heading.group(1).strip()))
        elif line.startswith("- "):
            flush()
            current = line[2:].strip()
        elif line.startswith("  ") and current is not None:
            current += " " + line.strip()
        # Stray non-bullet, non-heading text is never Android-scoped; drop it.
    flush()
    return tokens


def plain_text(text):
    """Strip the Markdown the house style uses; Play renders notes as text."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)  # [label](url) -> label
    text = text.replace("**", "").replace("`", "")
    return text.strip()


def headline_of(bullet):
    """The entry's bold headline as plain text (first sentence if no bold)."""
    match = HEADLINE.match(bullet)
    if match:
        return plain_text(match.group(1))
    # No bold summary (off-style entry): fall back to the first sentence.
    first = re.split(r"(?<=[.!?])\s", bullet, maxsplit=1)[0]
    return plain_text(first).rstrip(".")


def android_headlines(tokens):
    """[(heading, [headline, ...]), ...] for headings with Android entries."""
    groups = []
    heading = None
    for kind, text in tokens:
        if kind == "heading":
            heading = text
            continue
        if not ANDROID_PREFIX.match(text):
            continue
        entry = ANDROID_PREFIX.sub("", text, count=1)
        if not groups or groups[-1][0] != heading:
            groups.append((heading, []))
        groups[-1][1].append(headline_of(entry))
    return groups


def render(groups, limit=PLAY_NOTES_MAX):
    """Compose the notes text under `limit`, dropping trailing lines if needed."""
    if not groups:
        return FALLBACK_NOTES
    lines = [LEAD]
    for heading, headlines in groups:
        lines.append("")
        if heading:
            lines.append(f"{heading}:")
        lines.extend(f"- {headline}" for headline in headlines)

    dropped = []
    while len("\n".join(lines)) > limit and len(lines) > 1:
        line = lines.pop()
        if line.startswith("- "):
            dropped.append(line[2:])
        # Never leave a heading (or its blank spacer) dangling with no bullet
        # under it - it would say nothing.
        while len(lines) > 1 and (
            lines[-1] == "" or (lines[-1].endswith(":") and not lines[-1].startswith("- "))
        ):
            lines.pop()
    if dropped:
        warn(
            f"Android release notes exceeded {limit} chars; dropped "
            f"{len(dropped)} headline(s): " + "; ".join(reversed(dropped))
        )
    return "\n".join(lines)


def main():
    """Entry point."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changelog", default="CHANGELOG.md")
    parser.add_argument("--out", help="write the notes here (default: stdout)")
    parser.add_argument("--max", type=int, default=PLAY_NOTES_MAX)
    args = parser.parse_args()

    with open(args.changelog, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    notes = render(android_headlines(tokenize(top_section(lines))), args.max)

    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(notes + "\n")
        print(f"[play-release-notes] wrote {len(notes)} chars to {args.out}")
    else:
        print(notes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
