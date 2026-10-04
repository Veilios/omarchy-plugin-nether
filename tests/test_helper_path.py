#!/usr/bin/env python3
"""
Guard against the vault-helper path silently resolving to "".

Process blocks in Main.qml shell out to `nether_vault.py` via
`["python3", root.vaultHelper, ...]`. The helper path had been built with
`Qt.resolvedUrl(...).toLocalFile()`, which throws in Quickshell -- so the
property fell back to "" and every helper ran as `python3 "" ...`. python
then searched its working directory for __main__, and the useful part of the
error (create, delete) or the entire write (autosave) was silently lost.

This is a static check rather than a behavioural one: the failure mode is a
missing method that only the QML runtime notices, so the only reliable way
to catch it is to read the QML. It exists because one line broke five call
sites at once and the tests all still passed.

Rules:
  1. No Process command may use Qt.resolvedUrl(...).toLocalFile() to build a
     path; the working idiom is decodeURIComponent(String(...).replace(...)).
  2. The vaultHelper definition must not contain `toLocalFile`.
  3. Every Process that invokes root.vaultHelper must check its exit code and
     read its stderr, or the earlier silent-failure bug returns in a new form.

Run: python3 tests/test_helper_path.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

QML_FILES = ("Main.qml", "NoteView.qml", "HotKeysPopup.qml")

GHOST_PATH = re.compile(r"Qt\.resolvedUrl\([^)]*\)\.toLocalFile\s*\(\s*\)")
VAULT_HELPER_USE = re.compile(r"root\.vaultHelper")
MUST_HAVE = (re.compile(r"onExited"), re.compile(r"exitCode"), re.compile(r"StdioCollector"))


def qml_blocks(lines, start):
    """Collect the lines of a brace-delimited element starting at `start`."""
    base_indent = len(lines[start]) - len(lines[start].lstrip())
    out = [lines[start]]
    for j in range(start + 1, len(lines)):
        line = lines[j]
        if line.strip() == "}" and (len(line) - len(line.lstrip())) <= base_indent:
            out.append(line)
            break
        out.append(line)
    return out


def audit(path):
    name = os.path.basename(path)
    lines = open(path, encoding="utf-8").read().split("\n")
    problems = []
    for i, line in enumerate(lines):
        if GHOST_PATH.search(line):
            problems.append(
                "%s:%d  Qt.resolvedUrl(...).toLocalFile() throws in Quickshell -- "
                "use decodeURIComponent(String(...).replace(/^file:\\/\\//, \"\"))"
                % (name, i + 1)
            )
        if "process" in line.lower() and "vaultHelper" in line:
            problems.append("%s:%d  helper invocation written as raw text?" % (name, i + 1))
        if re.match(r"^\s*Process\s*\{", line):
            body = qml_blocks(lines, i)
            if any(VAULT_HELPER_USE.search(b) for b in body):
                for need in MUST_HAVE:
                    if not any(need.search(b) for b in body):
                        problems.append(
                            "%s:%d  Process using root.vaultHelper is missing a "
                            "%s guard -- helper failures must not be silent"
                            % (name, i + 1, need.pattern)
                        )
    # The definition itself must not use the broken idiom.
    for i, line in enumerate(lines):
        if re.search(r"property string vaultHelper", line) and "toLocalFile" in line:
            problems.append(
                "%s:%d  vaultHelper uses toLocalFile(), which resolves to \"\" and "
                "breaks every helper invocation" % (name, i + 1)
            )
    return problems


def main():
    failures = []
    for rel in QML_FILES:
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            failures.append("%s: missing" % rel)
            continue
        failures.extend(audit(path))
    if failures:
        print("helper-path: %d problem(s)" % len(failures))
        for f in failures:
            print("  FAIL " + f)
        return 1
    print("helper-path: no silent helper-path failures found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
