#!/usr/bin/env python3
"""
Guard against rendering vault content as rich text.

`Text` defaults to `textFormat: Text.AutoText`, which means a string that looks
like markup is rendered as markup -- including `<img src="...">`, which makes
Qt fetch that URL. A vault can be a clone, a synced folder, or something shared
with you, so note names, folder paths and search snippets are attacker
controlled, and listing them must never cause the long-lived shell to fetch
anything.

This is a static check rather than a behavioural one: the failure mode is an
absent property, so the only reliable way to catch it is to read the QML. It
exists because the same class of bug was found by hand more than once, in more
than one place, and fixing them individually is how the next one survives.

Rule: any Text whose `text:` is derived from the vault must state its
textFormat explicitly. In Main.qml that means Text.PlainText. Note bodies are
deliberately rendered as markdown, so NoteView.qml may use MarkdownText -- but
it still has to be explicit, rather than inheriting the AutoText default.

Run: python3 tests/test_untrusted_text.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Expressions that pull in vault-derived or persisted-config data.
UNTRUSTED = re.compile(
    r"""(
        modelData\.(name|rel|path|snippets)   # note name, relative path, folder, snippets
      | noteRow\.modelData\.(name|rel|snippets)
      | \bsnippets\b                          # search snippet text
      | root\.(noteName|currentNote|rawText)  # current note identity / contents
      | root\.(draftVaultPath|vaultPathRaw)   # configured vault path
      | folderHeader\.section                 # folder path header
      | blockItem\.text                       # note body blocks in NoteView
    )""",
    re.X,
)

TEXT_EL = re.compile(r"^(\s*)Text\s*\{\s*$")
TEXT_INPUT_EL = re.compile(r"^(\s*)TextInput\s*\{\s*$")
TEXT_FORMAT = re.compile(r"^\s*textFormat\s*:\s*(\S+)")
TEXT_BIND = re.compile(r"^\s*text\s*:\s*(.+?)\s*$")

# Note bodies are intentionally markdown. Everything else must be plain.
ALLOWED = {"Main.qml": {"Text.PlainText"}, "NoteView.qml": {"Text.MarkdownText", "Text.PlainText"}}


def blocks(lines, start):
    """Collect the lines of a brace-delimited element starting at `start`."""
    base_indent = len(lines[start]) - len(lines[start].lstrip())
    out = []
    for j in range(start + 1, len(lines)):
        line = lines[j]
        if line.strip() == "}" and (len(line) - len(line.lstrip())) == base_indent:
            break
        out.append(line)
    return out


def audit(path):
    name = os.path.basename(path)
    allowed = ALLOWED[name]
    lines = open(path, encoding="utf-8").read().split("\n")
    problems = []
    checked = 0

    for i, line in enumerate(lines):
        # TextInput has no textFormat property at all -- it is plain text by
        # construction and never renders rich text, so it neither needs nor
        # accepts one. Setting it is a mistake, and a quiet one: qmllint --bare
        # does not resolve the type, so the build stays green.
        if TEXT_INPUT_EL.match(line):
            for b in blocks(lines, i):
                if TEXT_FORMAT.match(b):
                    problems.append(
                        "%s:%d  textFormat set on a TextInput, which has no such "
                        "property (it is already plain text)" % (name, i + 1)
                    )
                    break
            continue

        m = TEXT_EL.match(line)
        if not m:
            continue
        body = blocks(lines, i)
        text_val, fmt = None, None
        for b in body:
            tf = TEXT_FORMAT.match(b)
            if tf:
                fmt = tf.group(1)
            tb = TEXT_BIND.match(b)
            # Only the first line of a multi-line binding expression.
            if tb and text_val is None:
                text_val = tb.group(1)
        if text_val is None or not UNTRUSTED.search(text_val):
            continue

        checked += 1
        if fmt is None:
            problems.append(
                "%s:%d  Text rendering vault content has no textFormat: %s"
                % (name, i + 1, text_val[:60])
            )
            problems[-1] += (
                "  -> defaults to AutoText, so <img src=...> would be fetched"
            )
        elif fmt not in allowed:
            problems.append(
                "%s:%d  textFormat %s is not one of %s for vault content"
                % (name, i + 1, fmt, sorted(allowed))
            )

    return checked, problems


def main():
    total = 0
    failures = []
    for rel in ("Main.qml", "NoteView.qml"):
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            failures.append("%s: missing" % rel)
            continue
        checked, problems = audit(path)
        total += checked
        print("  %-14s %d Text element(s) rendering vault content" % (rel, checked))
        failures.extend(problems)

    if failures:
        print("\nuntrusted-text: %d checked, %d problem(s)" % (total, len(failures)))
        for f in failures:
            print("  FAIL " + f)
        return 1
    print("\nuntrusted-text: %d checked, all state a textFormat explicitly" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())