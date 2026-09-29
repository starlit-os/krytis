---
name: bluefin-bazaar-recommends
description: Mine Bluefin's Bazaar curated app recommendations (projectbluefin/common's curated.yaml) for Flatpak candidates krytis could recommend, and refresh docs/design/bazaar-curated-candidates.md. Use whenever the user asks what Bluefin recommends in Bazaar, wants to check Bluefin's curated/recommended apps for changes, refresh the Bazaar candidate list, find new Flatpak candidates, or mentions issue #245 or the curated.yaml in projectbluefin/common.
---

# Bluefin Bazaar recommends

Bluefin maintains a hand-picked "Curated" page for Bazaar, the Flatpak store krytis ships
(`files/flatpak-preinstall/flatpak-preinstall.sh`). krytis uses it as a source of
candidates for its own curated page
([#245](https://github.com/starlit-os/krytis/issues/245)). This skill turns "what changed
in Bluefin's picks since we last looked" into an updated candidate list.

The state lives in `docs/design/bazaar-curated-candidates.md`:

- the `<!-- bluefin-curated-sha: <sha> -->` marker, which is the projectbluefin/common
  commit last mined;
- the per-section tables, which mirror Bluefin's list at that commit.

**Where the list lives.** It's in `system_files/bluefin/etc/bazaar/curated.yaml` in
**projectbluefin/common**. It isn't in dakota, which doesn't configure Bazaar at all, and
it isn't in the legacy `ublue-os/bluefin` repo. #245's first investigation searched
`ublue-os/bluefin`, found nothing, and wrongly concluded that Bluefin had no positive
list. If the file ever moves, `git log --follow` in common finds where it went.

## Workflow

### 1. Diff

```bash
mise run bazaar-recommends-diff              # added / removed / moved since the marker
mise run bazaar-recommends-diff --summaries  # + Flathub name/summary per added app
mise run bazaar-recommends-diff --list       # full current list as TSV (section, id)
```

The task clones projectbluefin/common as the sibling `bluefin-common/` on its first run,
then fetches. It prints the commits in the range that touched `etc/bazaar/`, plus the new
marker line. "Up to date" is a normal result, since Bluefin curates in monthly-ish
batches.

If it errors with `parsed 0 app ids`, Bluefin changed the schema again. Fix `parse()` in
`mise/tasks/bazaar-recommends-diff` before trusting any diff. The parser already handles
two layouts: the legacy `category:` + bare `appids:` schema from before
projectbluefin/common#1155, and the modern `section:` + `appids: list:` schema. A range
can span both.

### 2. Read the curation commits, not just the IDs

Bluefin's curation PRs (e.g. common `43bb429`, #1173) carry a table in the commit body
with each new app's name, author, description and upstream repo. That table is the
cheapest source of summaries and of Bluefin's reasons for a pick:

```bash
git -C ../bluefin-common log --format='%h %s%n%b' <old>..<new> -- system_files/bluefin/etc/bazaar/
```

**Interpret the diff:**

- **Remove + add of near-identical IDs is a rename**, not a churn. Keypunch went
  `dev.bragefuglseth.Keypunch` → `no.bragefuglseth.Keypunch` when its domain changed.
  Update the row in place.
- **Moves between sections** are Bluefin re-organising. Mirror them, but they aren't new
  candidates.
- **Removals** deserve a look at the commit body. "Removed because abandoned or broken"
  is a signal for krytis too. "Moved to a host install" (the IDE hooks) isn't.

### 3. Get summaries

Order of preference:

1. `--summaries` (Flathub API `https://flathub.org/api/v2/appstream/<id>`). This works
   on a dev machine. **flathub.org and dl.flathub.org are blocked by the cloud-agent
   egress proxy**, so every lookup there reports `flathub lookup failed`.
2. The curation commit body (step 2).
3. The AppStream metainfo in git, which is reachable through the proxy. Clone
   `https://github.com/flathub/<id>` at depth 1 and look for `*.metainfo.xml` /
   `*.appdata.xml`. If there's none, clone the upstream repo named in the manifest's
   `sources` and read the file there. Take the untranslated `<name>` and `<summary>`.
   **Sanity-check the result.** The first metainfo in an upstream tree can belong to a
   vendored dependency: this returned "GUsb" for Ente Auth, "chrono" for Planify, "F3D"
   for Exhibit, and flatpak-builder's test fixture for GNOME Builder. Some summaries are
   also unexpanded templates, like Easy Effects' `@APPLICATION_NAME@`.
4. Write it by hand and mark it † (the doc's convention).

### 4. Update the doc

Edit `docs/design/bazaar-curated-candidates.md` in place:

- **Policy: no proprietary or paid apps.** Check every added app's license before
  proposing it. `--summaries` prints it from the Flathub API. In the sandbox, read
  `<project_license>` from the metainfo in `github.com/flathub/<id>`, or from the
  upstream repo. An app is out if any of these hold:
  - it declares `LicenseRef-proprietary`;
  - it is a vendor binary with no source (its manifest downloads a prebuilt tarball
    from the vendor's CDN, as with Ecosia);
  - it needs a paid subscription to be useful, even under a FOSS license (as with
    Mozilla VPN).

  Record the drop under **Decided** with the reason. Don't ask again: the user settled
  this for all future picks.

  **Exceptions** are the user's call, one app at a time: a proprietary app that has no
  free alternative (so far only Steam). They're listed in the doc's **Exceptions**
  table. Never grant one yourself. If a new Bluefin pick looks like a case for one,
  drop it anyway and point it out to the user as a possible exception.
- **Rejected candidates stay in the mirror.** When the user drops a Bluefin pick, keep
  its row, strike it through, and list it in the doc's **Decided** section. Deleting the
  row would make the next refresh report it as "added" and propose it again. If Bluefin
  itself later removes a struck app, remove it from both places.
- Add, remove, rename and move rows so each section table mirrors Bluefin's list, in
  Bluefin's order. Update the per-section counts in the headings and the snapshot line
  (SHA, date, totals).
- Replace the marker with the `New marker:` line the task printed.
- Re-check **Currently preinstalled by krytis** against its two sources,
  `files/flatpak-preinstall/flatpak-preinstall.sh` (`APPS=`) and `live/src/flatpaks`.
  That section exists so each preinstalled app can be weighed against the curated
  alternatives. If Bluefin starts recommending an app krytis preinstalls, note it on
  that app's row.
- If a change affects a point under **Things to settle before picking**, update that
  point too. Examples: Bluefin drops an app krytis ships natively, the IDE-hook set
  changes, or `blocklist.yaml` changes. Don't append a new point beside a stale one.

Then give the user a short summary of the new, removed and renamed apps, each with its
Flathub link and one line on how it fits krytis (niri, not GNOME; no Homebrew;
proprietary or free). The doc is only the candidate pool. Choosing which apps go into
krytis's own `curated.yaml` is #245's decision and the user's, so don't pre-select.

When the user does pick, the picks go into the `appids.list` entries of krytis's
`curated.yaml` and nowhere else. The #245 wiring owns the rows, banners, titles,
`bazaar.yaml` and `blocklist.yaml`. The five rules a list change must meet are in the
candidate doc's **Contract with the wiring** section. Check rules 1 and 2 before
proposing a list: every ID must pass `flatpak remote-info flathub <id>`, and no ID may
appear in `blocklist.yaml`. flathub.org is blocked in the cloud sandbox, so rule 1 can
only be checked on a dev machine. Say so rather than skipping it.

### 5. Commit

Commit the doc update, marker included, as one `docs(bazaar): …` commit on a no-issue
branch (for example `docs/bazaar-recommends-<date>`) unless the user ties the run to an
issue. Run `mise run docs-links` first. If anything about the process turned out to be
wrong, such as a new schema or a moved file, fix this skill and
`docs/skills/desktop.md` § *Bluefin's Bazaar curated list* in the same commit.

## Reference

- Bazaar's curated schema is described in
  [bazaar-org/bazaar's `overview.md`](https://github.com/bazaar-org/bazaar/blob/main/docs/overview.md).
  Bluefin's own notes are in
  [projectbluefin/common's `bazaar.md` skill](https://github.com/projectbluefin/common/blob/main/docs/skills/bazaar.md).
- Pipeline and Flatpak notes on the krytis side: `docs/skills/desktop.md` §
  *Bluefin's Bazaar curated list*.
