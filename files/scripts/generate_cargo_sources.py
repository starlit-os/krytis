#!/usr/bin/env python3
"""Emit a BST `kind: cargo2` source block's `ref:` list from a Cargo.lock.

Usage: python3 files/scripts/generate_cargo_sources.py <path/to/Cargo.lock>

Reads every `[[package]]` entry sourced from crates.io's registry and prints
the `- kind: registry / name / version / sha` entries `docs/skills/bst.md`'s
cargo2 workflow expects, in Cargo.lock order. Output is the `ref:` list body
only — paste it under an existing `- kind: cargo2` source's `ref:` key
(replacing the previous list) rather than the whole source block, since the
element may carry extra keys (`url:`, `git-mirrors:`, `build-args:`) this
script doesn't know about.

Git-sourced packages (`source = "git+..."`) are skipped — cargo2's registry
kind only vendors crates.io tarballs; a git dependency needs its own
`kind: git_repo`/`kind: git` source alongside, added by hand.
"""
import sys
import tomllib


def generate_refs(cargo_lock_path):
    with open(cargo_lock_path, "rb") as f:
        data = tomllib.load(f)

    lines = []
    for package in data.get("package", []):
        source = package.get("source", "")
        if "registry+https://github.com/rust-lang/crates.io-index" not in source:
            continue
        checksum = package.get("checksum")
        if not checksum:
            # Path/workspace-member packages have no checksum and aren't vendored.
            continue
        lines.append("  - kind: registry")
        lines.append(f"    name: {package['name']}")
        lines.append(f"    version: {package['version']}")
        lines.append(f"    sha: {checksum}")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_Cargo.lock>", file=sys.stderr)
        sys.exit(1)
    print(generate_refs(sys.argv[1]))
