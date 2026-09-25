"""Shared helpers for BST elements that build a Zig project with vendored deps.

Zig has no lockfile-with-checksums that BST can consume, and no BST source kind
understands `build.zig.zon`. Every Zig element in this repo therefore carries one
`kind: remote` source per dependency tarball, staged into `zig-deps/`, and calls
`zig fetch` on each of them in `build-commands` to populate a `ZIG_GLOBAL_CACHE_DIR`
the offline BST sandbox can build against.

Regenerating that list by hand is not viable — ghostty is 30+ deps and seance
(which vendors ghostty as a submodule) is more. `mise/tasks/{ghostty,seance}-update`
generate it from the release tarball instead, using the primitives here.

Not a mise task: `mise` only scans `mise/tasks/`, so this module is importable
without becoming a runnable task. Tasks import it with:

    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
"""

import hashlib
import re
import shutil
import subprocess
import tempfile
import urllib.request
from pathlib import Path

# Alias mappings matching include/aliases.yml (longest prefix first).
URL_ALIASES = [
    ("https://deps.files.ghostty.org/", "ghostty_deps:"),
    ("https://release.files.ghostty.org/", "ghostty_releases:"),
    ("https://raw.githubusercontent.com/", "github_raw:"),
    ("https://codeberg.org/", "codeberg_files:"),
    ("https://github.com/", "github_files:"),
]


def apply_alias(url: str) -> str:
    for prefix, alias in URL_ALIASES:
        if url.startswith(prefix):
            return alias + url[len(prefix):]
    return url


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: str | Path, user_agent: str = "krytis-zig-update/1.0") -> None:
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req) as resp, open(dest, "wb") as out:
        while chunk := resp.read(65536):
            out.write(chunk)


def parse_zon_deps(content: str) -> list[str]:
    """Return every `.url = "..."` dependency URL in a build.zig.zon, verbatim.

    Two shapes appear: a plain tarball URL, and `git+https://host/owner/repo#<sha>`.
    Both are returned as written — `resolve_dep` turns them into something
    fetchable. Missing the git+ form is not a cosmetic gap: vaxis declares
    zigimg and uucode that way, and they are real build inputs.

    Lazy deps are included: a lazy dep that the current target does not need is
    an unused tarball in the artifact, whereas a missing one is a build failure
    that only reproduces on the platform that needs it.

    Commented-out lines are not: ghostty's `example/*/build.zig.zon` files each
    carry a `//     .url = ".../archive/COMMIT.tar.gz"` template line, which is
    a 404 the moment it is treated as a real dep.
    """
    live = "\n".join(
        line for line in content.splitlines() if not line.lstrip().startswith("//")
    )
    return re.findall(r'\.url\s*=\s*"((?:git\+)?https?://[^"]+)"', live)


def resolve_dep(raw_url: str) -> tuple[str, str]:
    """Map a zon dep URL to (fetchable URL, BST staging directory).

    A `git+https://…#<sha>` dep has no tarball of its own; take the forge's
    commit archive instead. It is staged under `zig-deps-git/` rather than
    `zig-deps/` purely to record that provenance — both directories get the
    same `zig fetch` treatment at build time. Do NOT try to unpack a git dep
    into `$ZIG_GLOBAL_CACHE_DIR/p/<hash>` by hand: on Zig 0.16 that entry is
    ignored and the dep is re-fetched over the network, which fails in the
    offline BST sandbox (see elements/desktop/falcond.bst).
    """
    if not raw_url.startswith("git+"):
        return raw_url, "zig-deps"

    base, _, commit = raw_url[len("git+"):].partition("#")
    base = base.split("?", 1)[0].removesuffix(".git")
    if not commit:
        raise SystemExit(f"ERROR: git dep without a commit ref: {raw_url}")
    return f"{base}/archive/{commit}.tar.gz", "zig-deps-git"


def _extract(archive: Path, dest: Path) -> bool:
    """Best-effort extraction. Returns False if the format is unsupported here."""
    dest.mkdir(parents=True, exist_ok=True)
    name = archive.name
    if name.endswith(".tar.zst") or name.endswith(".tzst"):
        # BST2 runs on Python 3.13, whose tarfile has no zstd support (3.14 adds
        # it). Shell out when a zstd-capable tar exists; a dep we cannot open is
        # still emitted, we just can't walk into it for transitive deps.
        if shutil.which("tar") is None:
            return False
        return subprocess.run(
            ["tar", "--zstd", "-xf", str(archive), "-C", str(dest)],
            capture_output=True,
        ).returncode == 0
    try:
        shutil.unpack_archive(str(archive), str(dest))
        return True
    except Exception:
        return False


def resolve_closure(
    zon_texts: list[str],
    workdir: Path,
    user_agent: str = "krytis-zig-update/1.0",
    log=print,
) -> list[tuple[str, str, str]]:
    """Download the transitive dep closure, returning (aliased_url, sha256, directory).

    Parsing only the zon files shipped in the source tarball is not enough: a
    fetched dependency carries its own build.zig.zon, and Zig fetches that one
    too. ghostty.bst's `zigimg`/`uucode` entries are exactly this case — they
    come from vaxis, which is itself a downloaded tarball. So walk the graph
    breadth-first, unpacking each dep to look for more.

    Ordering is first-seen, so a regenerated element diffs cleanly against the
    previous run when upstream only bumps one dep.
    """
    queue: list[str] = []
    seen: set[str] = set()
    for text in zon_texts:
        for url in parse_zon_deps(text):
            if url not in seen:
                seen.add(url)
                queue.append(url)

    entries: list[tuple[str, str, str]] = []
    dl_dir = workdir / "dl"
    dl_dir.mkdir(parents=True, exist_ok=True)

    while queue:
        raw = queue.pop(0)
        url, directory = resolve_dep(raw)
        filename = url.rsplit("/", 1)[-1]
        # Forge archive URLs collapse to bare `<sha>.tar.gz`; keep them distinct.
        dest = dl_dir / f"{hashlib.sha256(url.encode()).hexdigest()[:8]}-{filename}"
        log(f"      {filename}")
        download(url, dest, user_agent)
        entries.append((apply_alias(url), sha256_file(dest), directory))

        with tempfile.TemporaryDirectory(dir=workdir) as scratch:
            if not _extract(dest, Path(scratch)):
                log(f"      (cannot unpack {filename}; not walking its deps)")
                continue
            for zon in Path(scratch).rglob("build.zig.zon"):
                for dep_url in parse_zon_deps(zon.read_text(errors="replace")):
                    if dep_url not in seen:
                        seen.add(dep_url)
                        queue.append(dep_url)

    return entries


def extract_source_blocks(text: str, kind: str) -> list[str]:
    """Return the raw YAML for every `- kind: <kind>` source in an element.

    Regenerating `sources:` wholesale would otherwise silently drop hand-written
    entries that are not deps — ghostty.bst's `kind: patch` carrying
    patches/ghostty/allow-shlib-undefined.patch is load-bearing, and losing it
    on the next version bump would surface as an unrelated link failure.

    The contiguous comment lines directly above the entry come with it: for a
    patch source that comment is the only record of *why* the patch exists.
    """
    blocks: list[str] = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() != f"- kind: {kind}":
            continue
        indent = len(line) - len(line.lstrip())
        head = i
        while head > 0 and lines[head - 1].lstrip().startswith("#"):
            head -= 1
        block = lines[head:i + 1]
        for follow in lines[i + 1:]:
            if not follow.strip():
                break
            if len(follow) - len(follow.lstrip()) <= indent:
                break
            block.append(follow)
        blocks.append("\n".join(block))
    return blocks


def render_sources(source_tarball: tuple[str, str], entries: list[tuple[str, str, str]],
                   src_comment: str, preserved: list[str] = [],
                   base_dir: str | None = None) -> str:
    """Render a complete `sources:` block.

    `base_dir` is for tarballs BST will not auto-strip: the default `*` only
    fires when exactly one top-level member matches, and an archive that also
    carries a `./` entry (seance's release tarball does) leaves the project one
    directory down, where `zig fetch` and `zig build` cannot see build.zig.
    """
    lines = [
        "sources:",
        f"  # {src_comment}",
        "  - kind: tar",
        f"    url: {source_tarball[0]}",
        f"    ref: {source_tarball[1]}",
    ]
    if base_dir:
        lines.append(f"    base-dir: '{base_dir}'")
    lines.append("")
    for block in preserved:
        lines += [block, ""]
    lines += [
        "  # Zig package dependencies — generated, do not hand-edit.",
        "  # Regenerate with the element's `-update` mise task.",
    ]
    for aliased, sha, directory in entries:
        lines += [
            "  - kind: remote",
            f"    url: {aliased}",
            f"    ref: {sha}",
            f"    directory: {directory}",
            "",
        ]
    return "\n".join(lines)


def replace_sources_block(text: str, new_sources: str) -> str:
    """Swap the `sources:` block, which always runs up to the `config:` block."""
    new_text, n = re.subn(
        r"^sources:.*?(?=^config:)",
        lambda _: new_sources + "\n",
        text,
        flags=re.DOTALL | re.MULTILINE,
        count=1,
    )
    if n != 1:
        raise SystemExit("ERROR: could not locate the sources: … config: block")
    return new_text
