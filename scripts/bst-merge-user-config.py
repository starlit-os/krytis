#!/usr/bin/env python3
"""Layer mise/tasks/bst's generated settings on top of the user's own BuildStream config.

    scripts/bst-merge-user-config.py <overlay.yaml>

`bst --config FILE` *replaces* the default user configuration instead of
merging with it (BuildStream 2.7 `_context.py` `Context.load()`: the default
file is only looked up when no config is given). So the temporary config that
`mise/tasks/bst` writes for `--pull`/`--push` or `BST_CACHE_QUOTA` used to drop
everything in `~/.config/buildstream.conf`: a quota the user sized for a big
dedicated cache, `scheduler: builders:`, `cachedir`. Dropping a quota on a
large cache is what made one `--pull` evict tens of GB (#1507).

This rewrites <overlay.yaml> in place as: the user's default config, with the
overlay deep-merged over it (overlay wins key by key). `build: max-jobs:` in the
overlay is only a fallback and never replaces the user's own value. The default
file is found the way BuildStream finds it: `$XDG_CONFIG_HOME` (or
`~/.config`), `buildstream2.conf` first, then `buildstream.conf`. With no
default file the overlay is left as written. Prints the base file used, if any,
to stderr.
"""

import os
import sys

import yaml

# Keys in the overlay that are defaults, not overrides: the user's value wins.
FALLBACKS = {("build", "max-jobs")}


def default_user_config():
    home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    for name in ("buildstream2.conf", "buildstream.conf"):
        path = os.path.join(home, name)
        if os.path.exists(path):
            return path
    return None


def merge(base, overlay, path=()):
    out = dict(base)
    for key, value in overlay.items():
        here = path + (key,)
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value, here)
        elif here in FALLBACKS and key in out:
            continue
        else:
            out[key] = value
    return out


def main():
    if len(sys.argv) != 2:
        print("usage: scripts/bst-merge-user-config.py <overlay.yaml>", file=sys.stderr)
        return 2
    overlay_path = sys.argv[1]
    base_path = default_user_config()
    if base_path is None:
        return 0
    with open(base_path) as f:
        base = yaml.safe_load(f) or {}
    with open(overlay_path) as f:
        overlay = yaml.safe_load(f) or {}
    if not isinstance(base, dict):
        print(f"ERROR: {base_path} is not a YAML mapping", file=sys.stderr)
        return 1
    merged = merge(base, overlay)
    with open(overlay_path, "w") as f:
        yaml.safe_dump(merged, f, default_flow_style=False, sort_keys=False)
    print(f"bst: layered over {base_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
