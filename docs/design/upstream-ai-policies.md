# Upstream AI-contribution policies

Status: **current as of 2026-10-15**. For every upstream project krytis is holding
something against, this file records whether that project has written rules about
AI/LLM-assisted contributions, and what they say. `mise run upstream-policy-check`
fails when the set of rows and the set of upstreams disagree.

Read the relevant row before proposing anything upstream. Opening the PR, issue or
comment is still an Upstream Gate decision for the human (AGENTS.md § Third-party
repositories). This file answers a different question: if the human says yes, what will
the project accept? Krytis commits carry an `Assisted-by:` trailer (AGENTS.md § AI
attribution). Some upstreams require exactly that trailer, and some refuse any AI
credit. Several refuse AI-written code, issues or comments outright.

## Scope

An upstream gets a row when krytis holds either of:

- **a carry**: an element in the [carried-patches Inventory](carried-patches.md#inventory),
  either a patch or a fork pin. The upstream is the project the patch would go to. For a
  mirrored junction element, that means both the component and the junction it mirrors.
- **an open upstream reference**: an OPEN issue or PR in another project, cited in
  `docs/` (minus `docs/plans/done/`), `elements/`, `mise/tasks/`, or an open krytis issue
  body. These are the things krytis waits on, works around, or plans to carry.

Owned orgs (`starlit-os`, `kitten-lily`) are excluded. So are upstreams whose only
references are closed, and sibling projects that krytis only reads for lessons
(projectbluefin/dakota, tuna-os/fisherman, and so on).

**AI policy** column values:

- `Yes`: a written rule binds contributions to this repo. It can be in the repo, its org,
  or its project.
- `Partial`: the repo has no rule of its own, but its hosting platform imposes one.
- `No`: nothing written binds the repo. The *Rules in brief* cell still notes adjacent
  policies (another body in the same org, or the kernel's policy for a kernel-style
  maintainer) and maintainer behaviour seen in threads. Those are context, not rules.

## Inventory

`upstream-policy-check` reads the first four columns. **Repo**: every backticked
`<host>/<path>`, which must match the repo's canonical name after renames. **Stake**:
every backticked `elements/….bst` path must exist, and a carried one satisfies the
carry. Other text in Stake is free. **AI policy**: exactly `Yes`, `Partial` or `No`.

| Upstream | Repo | Stake | AI policy | Rules in brief |
|---|---|---|---|---|
| vim | `github.com/vim/vim` | Own patch `elements/overrides/vim.bst` (krytis policy, not upstreamable). | Yes | Disclose AI use. An **`Assisted-by: <tool>` trailer is required**. The PR template has "AI involvement is disclosed" / "No AI was used" boxes. No ban. |
| greetd | `git.sr.ht/~kennylevinsen/greetd`, `github.com/kennylevinsen/greetd` (mirror) | Vuln-remediation patches `elements/desktop/greetd.bst`. | Partial | No project rule. **SourceHut's ToS bans LLM-written or LLM-assisted code, tickets and emails** on the platform. Patches go to `greetd-devel@lists.sr.ht`. |
| rust-bindgen | `github.com/rust-lang/rust-bindgen` | Vuln-remediation patches `elements/overrides/rust-bindgen.bst`. | No | rust-lang/rust's LLM policy explicitly excludes other rust-lang repos. The Rust moderation team's spam policy bans unreviewed automated contributions [INFERENCE: it applies org-wide]. |
| freedesktop-sdk | `gitlab.com/freedesktop-sdk/freedesktop-sdk` | Junction. `elements/overrides/vim.bst`, `elements/overrides/rust-bindgen.bst` and `elements/overrides/btrfs-progs.bst` mirror its elements. `elements/core/efitools.bst` keeps two of its dropped patches. | No | Nothing in the repo, wiki or the freedesktop.org CoC. Commit subjects are capitalised, imperative, ≤ 50 characters. |
| freedesktop-sdk-extra | `gitlab.com/freedesktop-sdk/freedesktop-sdk-extra` | gnome-build-meta's nested junction since gnome-build-meta MR !5085. freedesktop-sdk-extra#41 (ppp 2.5.4, fix open as freedesktop-sdk-extra!246) gates #1221. | No | Nothing in the repo. The README defers to fdsdk's shared quality standards and documentation, which have no AI text either (see the freedesktop-sdk row). |
| efitools | `git.kernel.org/pub/scm/linux/kernel/git/jejb/efitools.git` | Patches `elements/core/efitools.bst`. | No | Nothing in the tree. Patches go to `sbsigntools@groups.io`, kernel-style with `Signed-off-by` [INFERENCE]. |
| btrfs-progs | `git.kernel.org/pub/scm/linux/kernel/git/kdave/btrfs-progs.git`, `github.com/kdave/btrfs-progs` (issues, PRs) | Own patch `elements/overrides/btrfs-progs.bst` (#1302). | No | Nothing in the tree. Patches go to linux-btrfs@vger.kernel.org or as GitHub PRs, and it cites the kernel's DCO. The kernel's policy (no agent `Signed-off-by`, `Assisted-by: LLM [tools]`) is context [INFERENCE]. |
| ananicy-cpp | `gitlab.com/ananicy-cpp/ananicy-cpp` | Backport `elements/desktop/ananicy-cpp.bst`. | No | No contributor docs at all. |
| Ghostty | `github.com/ghostty-org/ghostty` | Own patch `elements/desktop/ghostty.bst`. | Yes | AI allowed. **Disclose the tool and its extent.** The human must fully understand the code. No AI media. Slop gets you on a public denounce list. PRs need a vouch and a pre-accepted issue. Its `AGENTS.md` tells agents never to open issues or PRs. |
| oo7 | `github.com/linux-credentials/oo7` | Own patch `elements/desktop/oo7.bst`. Waits on oo7#506. | No | No contributor docs, and the org `.github` has none either. |
| xwayland-satellite | `github.com/Supreeeme/xwayland-satellite` | Patch `elements/desktop/xwayland-satellite.bst`. | Yes | Pinned issue Supreeeme/xwayland-satellite#512: AI-assisted PRs are fine if you understand them. **No pasted LLM issues, comments, PR descriptions or review replies.** |
| GNOME (gnome-build-meta) | `gitlab.gnome.org/GNOME/gnome-build-meta` | `elements/desktop/xwayland-satellite.bst` bypasses its `sdk/xwayland-satellite.bst`. | No | gnome-build-meta has no rule, and there is no GNOME-wide one. Extensions, Circle and Discourse ban AI-generated work, and many modules (Loupe, Calendar, …) ban LLM contributions outright. Check the module's own CONTRIBUTING. |
| gnome-disk-utility | `gitlab.gnome.org/GNOME/gnome-disk-utility` | GNOME/gnome-disk-utility#505 (whether the GTK4 51 release slipped) gates step 3 of `docs/plans/2026-09-30-gtk3-realistic-floor.md` (#1033). `elements/desktop/gnome-disk-utility.bst` mirrors its gnome-build-meta element. | No | Nothing in the tree (`HACKING` covers only commit-message format). No issue or MR mentions an AI rule. The GNOME-wide notes on the gnome-build-meta row apply as context. |
| noctalia | `github.com/noctalia-dev/noctalia` | Fork pin and patch `elements/desktop/noctalia.bst`. The fork's prompter was proposed as noctalia-dev/noctalia#4951 (issue noctalia-dev/noctalia#4950). | No | No rule, though contributors have asked for one (noctalia-dev/noctalia#4380). Only "Do not machine translate strings". Conventional Commits. A bot enforces the PR template. |
| omarchy-mxcontrol | `github.com/zachwilke/omarchy-mxcontrol` | Own patches `elements/desktop/noctalia-plugin-mx-control.bst`: one proposed as zachwilke/omarchy-mxcontrol#18 (#1220), and one as suggested changes in a review on zachwilke/omarchy-mxcontrol#16, taken as `7432d3e` (#1316). | No | No contributor docs or templates. The owner's own commits carry `Co-Authored-By: Claude …` and `Cursor Agent` trailers, so AI-assisted work is visibly normal there. |
| community-plugins | `github.com/noctalia-dev/community-plugins` | Own patches `elements/desktop/noctalia-plugin-mx-control.bst` on its Luau: one proposed as noctalia-dev/community-plugins#1073 (#1316), one feature not proposed. | No | No AI rule. A required attestation says the code is "not obfuscated, minified, or generated", which is about readability. "No unreviewed machine/LLM translations". A bot enforces the PR template. **A PR changing someone else's plugin is drafted until its author replies.** The README waives the author's sign-off for fixes. |
| bootc | `github.com/bootc-dev/bootc` | `elements/config/starlit-update.bst` works around bootc#2422. #1232 and #545 track bootc PRs. | Yes | Human review is required. **An LLM must not add `Signed-off-by`.** Use `Assisted-by: AI` / `Generated-by: AI` **without model names** (REVIEW.md says the opposite). No `Co-developed-by`. Over ~500 lines, file a design issue first. |
| Podman | `github.com/podman-container-tools/podman` | containers/podman#27779 and containers/podman#28038 (multistage builds ignore a local image), `docs/skills/krytis-live-config.md`. | Yes | Org-wide LLM policy. **No verbatim LLM output in issues, comments or PR text.** A PR checkbox says they are human-written. Assisted code is fine, but "remove … LLM metadata". Violations can mean bans. DCO is mandatory. |
| container-libs | `github.com/podman-container-tools/container-libs` | podman-container-tools/container-libs#34 and podman-container-tools/container-libs#625 (Fulcio workflow identity) gate #418. | Yes | Same org-wide policy as Podman. |
| fish-shell | `github.com/fish-shell/fish-shell` | fish-shell/fish-shell#8553 (conf.d order), `docs/skills/mise.md`. | Yes | **Ban.** "We do not accept contributions created with generative artificial intelligence tools", covering PRs, issues, comments and artwork. |
| Pangolin CLI | `github.com/fosrl/cli` | `elements/core/pangolin-cli.bst` works around fosrl/cli#27. Tracked in #915. | Yes | AI allowed, but **disclosure is required** in the PR template and the bug form. A CLA goes in every PR body. |
| niri | `github.com/niri-wm/niri` | niri-wm/niri#1966, niri-wm/niri#3587 and niri-wm/niri#823 (missing portals) shape `files/xdg-desktop-portal/niri-portals.conf`. | Yes | **Ban on creating anything with an LLM**: code, issues, comments or reviews. LLM translation is allowed if you attach the original. PR and issue checkboxes say "I did not use an LLM". |
| OpenRazer | `github.com/openrazer/openrazer` | Plan to carry openrazer/openrazer#2719 (#1224). | No | Nothing written. A maintainer thanked a contributor for disclosing AI use, and contributors disclose without being asked. |
| polkit | `github.com/polkit-org/polkit` | polkit-org/polkit#704 (setuid-less pkexec) affects `elements/config/polkit-agent-sandbox.bst`. | Yes | AI allowed. **State the tool and its extent** in the PR or issue. The submitter is fully responsible. A large volume of generated content slows review. |
| COSMIC | `github.com/pop-os/cosmic-epoch` | pop-os/cosmic-epoch#3453 (libsecret hangs without a prompter), `docs/design/secrets-service.md`. | Yes | **Pop!\_OS-wide ban**: no LLM content in issues or PRs, including code, comments and descriptions. A CI-enforced PR checkbox applies, and PRs without it are closed. |
| Renovate | `github.com/renovatebot/renovate` | renovatebot/renovate#45236 (digest PRs stuck under `minimumReleaseAge`), `.github/renovate.json5`. | Yes | **Disclose any AI use and its extent**, including who replies to review comments. Agents must name the model. Non-admins can't open issues; use Discussions. A CLA is required. Strict etiquette, enforced by blocks. |
| systemd | `github.com/systemd/systemd` | Open homed resize issues (`docs/skills/pam.md`) and systemd/systemd#37079 (dmem cgroup). | Yes | AI allowed if you understand and edit the output. **No AI credit in commits** ("no Co-Developed-By or Co-Authored-By or anything similar"). **No agent may open PRs or post for you.** Warning, then ban. Disclosure was dropped 2026-06. |
| fedora-atomic-desktops-sealed | `github.com/travier/fedora-atomic-desktops-sealed` | travier/fedora-atomic-desktops-sealed#13 (UKI addons in bootc), tracked in #545. | No | Personal repo with no rule. Fedora's AI policy (disclose, `Assisted-by:` recommended) applies only by [INFERENCE]. |
| ublue-os image-template | `github.com/ublue-os/image-template` | ublue-os/image-template#215 (strict signature policy), `docs/design/cosign-keyless-signing.md`. | No | No rule. Universal Blue requires that "you have authored 100% of the content". projectbluefin's agents are told never to write to `ublue-os/*`. |
| Zen Browser | `github.com/zen-browser/desktop` | Native-messaging issues (`docs/design/native-messaging-proxy.md`) and Flatpak migration issues (#1237). | No | Nothing written, but maintainers close PRs that look AI-generated (zen-browser/desktop#15898). |
| Flathub (Zen manifest) | `github.com/flathub/app.zen_browser.zen` | flathub/app.zen_browser.zen#109 and flathub/app.zen_browser.zen#57 block #1237. | Yes | Flathub-wide: **manifests must not contain AI-generated or AI-assisted content**. Other generated material must be disclosed. AI must not open submission PRs or write their commit messages, descriptions or replies. |
| arboard | `github.com/1Password/arboard` | 1Password/arboard#209 (Wayland clipboard backend), `docs/design/proton-pass-flatpak.md`. | No | No contributor docs. |
| umbriel | `github.com/noctalia-dev/umbriel` | noctalia-dev/umbriel#259 (XWayland grabs), tracked in #1055. | No | No rule. Conventional Commits. |
| seance | `github.com/no1msd/seance` | no1msd/seance#21 and no1msd/seance#13, tracked in #1120. | No | No rule. Bigger features go to a Discussion first. |
| Rust | `github.com/rust-lang/rust` | rust-lang/rust#150123 and rust-lang/rust#156675 (aarch64 Windows PGO), cited in #681. | Yes | LLMs may "analyze, … check, suggest, review. But not to **create**". No LLM-written comments or docs. LLM code only if pre-arranged, well reviewed, **with disclosure**. |

## What krytis's `Assisted-by:` trailer meets

The same trailer is a requirement at some upstreams and grounds for rejection at others.
Grouped by what happens to an AI-assisted krytis patch sent as-is:

- **Refused, whatever the disclosure:** niri, fish-shell, COSMIC, greetd (SourceHut ToS),
  rust-lang/rust (unless pre-arranged), the Flathub manifest repo, and GNOME modules with
  a Loupe-style ban. Here a patch must be human-written, or it stays a downstream carry.
- **Accepted with the trailer krytis already writes:** vim (requires `Assisted-by:`).
  Fedora recommends the same trailer.
- **Accepted with disclosure in another form:** Ghostty (tool and extent), Renovate
  (extent, plus who replies), polkit (tool and extent), Pangolin CLI (template field).
  The trailer helps, but the PR body still needs the statement.
- **Accepted, but the trailer must change:** systemd (no AI credit of any kind in commits),
  Podman and container-libs (strip LLM metadata; all prose human-written), bootc
  (`Assisted-by: AI` with no model name per AGENTS.md, but REVIEW.md asks for the model).
- **No written rule:** the rest. Disclose anyway; Zen shows an unwritten rule can still
  close a PR.

Three rules apply regardless of policy. The human must be able to explain the change
(Ghostty, systemd, Podman, polkit, bootc and COSMIC write this down). Issue text, review
replies and comments must be human-written at niri, Podman, systemd, xwayland-satellite,
COSMIC, Flathub and fish-shell. And agents must not open the PR or issue themselves
(systemd, Ghostty, Renovate, Flathub). That matches krytis's Upstream Gate.

## Details

Policy texts and evidence, one subsection per row, in table order. "Checked" lists where
nothing was found, so an absence is evidenced and not assumed.

### vim

- [CONTRIBUTING.md](https://github.com/vim/vim/blob/master/CONTRIBUTING.md) "Using AI":
  "When using AI for contributions, please disclose this." AI code must pass
  `test_codestyle.vim`.
- [AGENTS.md](https://github.com/vim/vim/blob/master/AGENTS.md): "**`Assisted-by:` is
  required** when AI was used." It also says `Signed-off-by:` is required, but CONTRIBUTING
  and the PR template call sign-off "recommended but not required". The commit format is
  strict: `Problem:` / `Solution:` lines plus `closes:` trailers.
- Decided in [vim#21318](https://github.com/vim/vim/issues/21318): "Let's use
  `Assisted-by: <tool>`".
- As of: CONTRIBUTING.md `632abba51f` (2026-08-23), AGENTS.md `ce7c78578f` (2026-10-14).

### greetd

- The repo (sourcehut and the GitHub mirror) has no CONTRIBUTING, AGENTS or HACKING file,
  and its README names only IRC and the list.
- SourceHut [terms](https://man.sr.ht/terms.md) prohibit "original content written with or
  which facilitates the use of LLMs". The
  [announcement](https://sourcehut.org/blog/2026-08-27-tos-changes-and-llms/) covers "source
  code, assets, tickets, emails". Private use (review, questions) followed by original
  code is allowed. Existing projects must adopt consistent policies. Violators are
  suspended.
- Whether this binds greetd is [INFERENCE]: greetd is an existing project hosted there, and
  its list is on lists.sr.ht. greetd-devel threads mentioning LLMs couldn't be read
  (lists.sr.ht returned HTTP 418 to automated fetches).

### rust-bindgen and Rust

- bindgen [CONTRIBUTING.md](https://github.com/rust-lang/rust-bindgen/blob/main/CONTRIBUTING.md)
  says nothing about AI. Recent PRs disclosing LLM use have been merged (rust-lang/rust-bindgen#3490).
- The [Rust Forge LLM policy](https://forge.rust-lang.org/policies/llm-usage.html) binds
  rust-lang/rust, cargo, clippy, rustfmt, mdBook and rustlings, and says "Other
  repositories in `rust-lang`" are "free to set their own policies". For rust-lang/rust:
  fine to "answer questions, analyze, distill, refine, check, suggest, review. But not to
  **create**". LLM-created code is allowed only if "Pre-arranged, non-critical,
  high-quality, well-tested, and well-reviewed … **with disclosure**".
- The [moderation spam policy](https://github.com/rust-lang/moderation-team/blob/main/policies/spam.md)
  bans "Fully or partially automated contribs". Whether it reaches bindgen is [INFERENCE].

### freedesktop-sdk

- [CONTRIBUTING.md](https://gitlab.com/freedesktop-sdk/freedesktop-sdk/-/blob/master/CONTRIBUTING.md):
  fork, MR, a seven-rule commit style, `git describe` refs, and `git_repo` over `git`. No AI
  text.
- Checked: repo root (no AGENTS/CLAUDE/AI files); README, RELEASE.md, BOOTABLE_IMAGES.md;
  `code-of-conduct.md`, which defers to the
  [freedesktop.org CoC](https://www.freedesktop.org/wiki/CodeOfConduct/) (no AI text); 26
  wiki page names; GitLab issue and MR title searches.

### freedesktop-sdk-extra

- [README.md](https://gitlab.com/freedesktop-sdk/freedesktop-sdk-extra/-/blob/main/README.md)
  (`2232d396`, checked 2026-10-20) § Contributions defers to freedesktop-sdk's "quality
  standards including the coding styles and coding practices" and its shared
  [documentation](https://freedesktop-sdk.gitlab.io/documentation/getting-started/index.html).
  It has no AI text.
- Checked: repo root (`LICENSES`, `NEWS.yml`, `README.md`, `REUSE.toml`; no CONTRIBUTING,
  AGENTS, CLAUDE or AI files; no `.gitlab/` templates). A GitLab issue search for "AI",
  "LLM", "machine learning" and "copilot" found no policy thread.

### efitools

- The [README](https://git.kernel.org/pub/scm/linux/kernel/git/jejb/efitools.git/tree/README)
  sends patches to `sbsigntools@groups.io`. There is nothing else, and master has been
  quiet since 2020.
- The kernel's
  [coding-assistants.rst](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/process/coding-assistants.rst)
  ("AI agents MUST NOT add Signed-off-by tags", `Assisted-by: LLM [TOOL]`) is a plausible
  expectation for a kernel maintainer's list. That is [INFERENCE] only.

### btrfs-progs

- The [README](https://github.com/kdave/btrfs-progs/blob/devel/README.md) "Development"
  section accepts patches on linux-btrfs@vger.kernel.org or as GitHub pull requests,
  one logical change per patch. `Signed-off-by` is optional for small changes, and it
  links the kernel's DCO. There is no AI text.
- Checked at v7.1: the repo root (no CONTRIBUTING, AGENTS, CLAUDE or AI files),
  `README.md` and `Documentation/dev/*.rst`, grepped for AI/LLM/generative/copilot.
- Because it follows kernel process, the kernel's
  [coding-assistants.rst](https://docs.kernel.org/process/coding-assistants.html) is the
  likely expectation: "AI agents MUST NOT add Signed-off-by tags", and the trailer is
  `Assisted-by: LLM [TOOL1] [TOOL2]`. That is [INFERENCE] only.

### ananicy-cpp

- The repo root has no CONTRIBUTING, templates or `docs/`. Issue and MR searches for
  AI/LLM found no policy. MR !45 discloses AI help and has no maintainer reply as of
  2026-10-15.

### Ghostty

- [AI_POLICY.md](https://github.com/ghostty-org/ghostty/blob/main/AI_POLICY.md): "All AI
  usage in any form must be disclosed. You must state the tool you used … along with the
  extent". "The human-in-the-loop must fully understand all code." "No AI-generated media".
  Slop authors go on "our public denouncement list. This list will block all future
  contributions." Maintainers are exempt.
- [CONTRIBUTING.md](https://github.com/ghostty-org/ghostty/blob/main/CONTRIBUTING.md):
  "Using AI to write code is fine." The vouch request must be written "in your own voice".
  Unvouched PRs are auto-closed. PRs must be "associated with a previously accepted issue".
- [AGENTS.md](https://github.com/ghostty-org/ghostty/blob/main/AGENTS.md) tells agents:
  "Never create an issue. Never create a PR."
- As of: AI_POLICY.md `00c33eaf72` (2026-02-15).

### oo7

- The repo has only `.github/workflows` and dependabot. The org
  [profile](https://github.com/linux-credentials/.github/blob/main/profile/README.md) points
  to Matrix and Issues, with no AI text. The maintainers are GNOME people, but GNOME
  policy isn't referenced.

### xwayland-satellite

- [Supreeeme/xwayland-satellite#512](https://github.com/Supreeeme/xwayland-satellite/issues/512) (owner, pinned,
  2026-09-24): "AI-assisted PRs are fine as long as you generally understand what is going
  on." "Do NOT copy/paste an LLM description of a PR." "Do NOT reply to PR review comments
  with an LLM." Violations "may result in your PR/issue being ignored or closed."
  Disclosure isn't required.

### GNOME (gnome-build-meta)

- gnome-build-meta's [contributing guide](https://gitlab.gnome.org/GNOME/gnome-build-meta/-/raw/master/docs/contributing.md)
  has no AI text. It says changes to shared components belong in freedesktop-sdk.
- The [Handbook](https://handbook.gnome.org/governance.html) leaves technical decisions to
  each module's maintainers, and no GNOME-wide AI page was found.
- Not binding on gnome-build-meta:
  [extension review guidelines](https://gjs.guide/extensions/review-guidelines/review-guidelines.html#extensions-must-not-be-ai-generated)
  ("Extensions must not be AI-generated"); GNOME Circle, which adopted the same wording;
  [Discourse moderation](https://discourse.gnome.org/t/llm-generated-projects-and-content-on-gnomes-discourse-instance/36006);
  and module-level bans such as [Loupe's](https://gitlab.gnome.org/GNOME/loupe/-/blob/1c3300d340d26ebea47f4b79cad91808c4f76b7b/CONTRIBUTING.md#use-of-generative-ai).

### gnome-disk-utility

- The tree's root has `HACKING` and `README.md`, neither with AI text. `HACKING` says where
  development and bugs live, and how to format a commit message. There is no `.gitlab/`
  directory, so there are no issue or MR templates.
- Issue and MR searches for `LLM`, `AI-generated`, `ChatGPT` and `Copilot` found nothing.
  The 12 `generative` hits are all fuzzy matches on "generate".
- As of: `main` `836cf716` (2026-09-25).

### noctalia

- [CONTRIBUTING.md](https://github.com/noctalia-dev/noctalia/blob/main/CONTRIBUTING.md) and
  the PR template have no AI rule. The [ethos page](https://noctalia.dev/ethos) has none
  either. A contributor noted the absence in
  [noctalia-dev/noctalia#4380](https://github.com/noctalia-dev/noctalia/issues/4380).
- The same org's noctalia-greeter (formerly a krytis fork pin, see carried-patches.md §
  Historical carries) and umbriel also have no rule.
- As of: CONTRIBUTING.md `127c43eff6` (2026-10-08).

### omarchy-mxcontrol

- The repo has no CONTRIBUTING, AGENTS, CLAUDE or AI file. `.github/` holds only
  `workflows/`, and there is no owner-level `.github` repo. The README has no contributor
  section.
- Behaviour: 5 of the repo's 22 commits carry `Co-Authored-By: Claude …` trailers and 3
  carry `Co-authored-by: Cursor Agent`, all on the owner's own work.
- As of: `main` `0968d77` (2026-09-07).

### community-plugins

- The [README](https://github.com/noctalia-dev/community-plugins/blob/main/README.md) and
  the [PR template](https://github.com/noctalia-dev/community-plugins/blob/main/.github/PULL_REQUEST_TEMPLATE.md)
  have no AI rule. The template's "Code review attestation" requires "The code is
  readable and not obfuscated, minified, or generated". The README's matching rule is
  "No obfuscated, minified, or generated code. A reviewer must be able to read every line
  you ship", so it is about readability. Translations must not be "unreviewed
  machine/LLM translations", and the README forbids machine-translated locales.
- **Someone else's plugin:** "Someone else's PR changing your plugin is not merged without
  your sign-off, unless it fixes something that is broken or is a mechanical change
  applied across the whole repo." `pr-notify-plugin-authors.yml` @-mentions the author
  and converts the PR to draft "until you have had a chance to look at it". Their reply
  marks it ready. On noctalia-dev/community-plugins#503, a maintainer waited for the author
  and said "Will wait a bit more since this is not a bug fix."
- **Template bot:** `enforce-pr-template.yml` converts a ready PR back to draft (and
  earlier closed it) when the description loses the `<!-- noctalia-pr-template:v1 -->`
  marker or a required heading. A ready PR needs exactly one plugin type, at least one
  compositor and every Checklist and attestation box checked. An update must bump
  `version` in `plugin.toml`, and a PR touches exactly one plugin directory.
- Behaviour: AI-assisted PRs that disclose it are merged. noctalia-dev/community-plugins#503
  ("Disclaimer: AI-assisted tooling was used.") was merged by a maintainer. Several
  plugins are AI tooling themselves.
- noctalia-dev/community-plugins#1073 disclosed the tool in the PR body and carried an
  `Assisted-by:` trailer.
- As of: README `2bb2854cc9` (2026-10-13), PR template `e6eaa58b54` (2026-09-03).

### bootc

- [AGENTS.md](https://github.com/bootc-dev/bootc/blob/main/AGENTS.md), synced from
  [bootc-dev/infra](https://github.com/bootc-dev/infra/blob/main/common/AGENTS.md): "Human
  review is required for all code that is generated or assisted by a large language
  model. If you are a LLM, you MUST NOT include a `Signed-off-by`". "You SHOULD insert an
  `Assisted-by: AI` tag … and `Generated-by: AI` when the commit is effectively entirely
  generated." "do NOT reference specific model names or tools".
- [REVIEW.md](https://github.com/bootc-dev/bootc/blob/main/REVIEW.md) contradicts that: it
  asks for "an `Assisted-by:` trailer indicating the tool and model used". The infra
  commit that last changed AGENTS.md itself names the model.
- CONTRIBUTING.md both requires and doesn't require DCO sign-off. A DCO check runs, so sign
  off [INFERENCE].
- As of: infra AGENTS.md `90f71f83e2` (2026-07-23).

### Podman and container-libs

- [LLM_POLICY.md](https://github.com/podman-container-tools/community/blob/main/LLM_POLICY.md)
  "applies to all our repositories in this GitHub Organization". "LLM output cannot be used
  verbatim in: Issues, comments, or pull request content". "All communication must be in
  your own words". "You may use LLMs to assist with code, but you're fully responsible".
  "Remove unnecessary comments and LLM metadata". "Violations may result in submission
  closure or permanent project bans."
- Podman's [PR template](https://github.com/podman-container-tools/podman/blob/main/.github/PULL_REQUEST_TEMPLATE.md)
  has the "human-written, per LLM Policy" checkbox. container-libs links the policy from a
  stub `LLM_POLICY.md`.
- The org [CONTRIBUTING](https://github.com/podman-container-tools/community/blob/main/CONTRIBUTING.md)
  makes DCO mandatory: the author must match `Signed-off-by`.
- As of: `LLM_POLICY.md` `13a876d1cd` (2026-08-03).

### fish-shell

- [CONTRIBUTING.rst](https://github.com/fish-shell/fish-shell/blob/master/CONTRIBUTING.rst):
  "We do not accept contributions created with generative artificial intelligence tools.
  Do not submit pull requests, GitHub issues or comments, artwork, where the output has
  been created by or edited with one of these tools."
- Adopted in [fish-shell/fish-shell#12630](https://github.com/fish-shell/fish-shell/pull/12630) (2026-08-13),
  where one core maintainer dissented. Private use for understanding was described as out
  of scope.

### Pangolin CLI

- [PR template](https://github.com/fosrl/cli/blob/main/.github/PULL_REQUEST_TEMPLATE.md):
  "Please disclose how AI was used … The use of AI does not preclude this from being
  merged". The [bug form](https://github.com/fosrl/cli/blob/main/.github/ISSUE_TEMPLATE/1.bug_report.yml)
  has a required "AI Disclosure" field.
- [CONTRIBUTING.md](https://github.com/fosrl/cli/blob/main/CONTRIBUTING.md): a CLA (AGPLv3
  plus the Fossorial commercial licence) goes at the top of every PR.

### niri

- [CONTRIBUTING.md](https://github.com/niri-wm/niri/blob/main/CONTRIBUTING.md): "You're not
  allowed to use LLMs to *create*. All pull request code, issue descriptions, comments,
  public reviews, etc. must be human-written." Translation is allowed with the original
  attached.
- The PR and issue templates have the checkbox "I did not use an LLM to write this…".
- As of: `7256ccf627` (2026-09-20). The niri-wm org `.github` repo wasn't checked (API
  rate limit).

### OpenRazer

- [DEVELOPMENT.md](https://github.com/openrazer/openrazer/blob/master/DEVELOPMENT.md) is the
  only contributor doc, and it has no AI text. There is no org `.github`, and no wiki page
  on the subject.
- Maintainer practice: "Thank you for disclosing AI was used."
  ([openrazer/openrazer#2904](https://github.com/openrazer/openrazer/pull/2904)).

### polkit

- [README.md](https://github.com/polkit-org/polkit/blob/main/README.md) "AI-assisted
  contributions": "please state this in the description of your pull request or issue. A
  brief note mentioning which tool was used and the extent of its involvement is
  sufficient." "you remain fully responsible for any AI-generated content you submit".
- [AGENTS.md](https://github.com/polkit-org/polkit/blob/main/AGENTS.md) says the same about
  commits and PR descriptions: "must be reviewed by a human before submission."
- As of: both `d3ba690b08` (2026-10-07).

### COSMIC

- [pop-os/pop CONTRIBUTING.md](https://github.com/pop-os/pop/blob/master/CONTRIBUTING.md):
  "Content generated by any LLM (also known as AI) may not be contributed in issues or PRs
  to Pop!\_OS projects including code, comments, and descriptions." Allowed-use examples
  were removed on purpose (`ce5545ab20`).
- The [PR template](https://github.com/pop-os/cosmic-epoch/blob/master/.github/PULL_REQUEST_TEMPLATE.md)
  is copied into every component repo, with `require-checklist` enforcing it: no LLM
  content, "I understand these changes in full", and DCO by attestation.
- As of: policy merged 2026-09-30 ([pop-os/cosmic-epoch#3911](https://github.com/pop-os/cosmic-epoch/pull/3911)).

### Renovate

- [contributing.md § AI assistance notice](https://github.com/renovatebot/renovate/blob/main/.github/contributing.md#ai-assistance-notice):
  "If you are using **any kind of AI assistance** … it must be disclosed in the pull
  request", "along with the extent". AI-generated PR responses must be disclosed too.
  Adapted from Ghostty's.
- The [PR template](https://github.com/renovatebot/renovate/blob/main/.github/pull_request_template.md)
  asks for a disclosure level and who replies to review. Agents must state their model.
- [AGENTS.md](https://github.com/renovatebot/renovate/blob/main/AGENTS.md): "Do not create
  GitHub Issues directly", and PRs start as drafts until the CLA is signed. Etiquette
  ([CODE_OF_CONDUCT.md](https://github.com/renovatebot/renovate/blob/main/CODE_OF_CONDUCT.md)):
  no "any update?" comments, no pinging, no force-push after opening.

### systemd

- systemd's [contributing guide](https://github.com/systemd/systemd/blob/main/docs/CONTRIBUTING.md)
  ([systemd.io](https://systemd.io/CONTRIBUTING)): "You may use generative AI and LLM tools …
  as long as you review and edit what they produce". "Do not list AI tools as author or
  co-author, or credit them in any way that suggests ownership." "Do not let an AI agent
  open pull requests or post for you." First offence is a warning, the second a ban.
- [AGENTS.md](https://github.com/systemd/systemd/blob/main/AGENTS.md): "Only human beings
  can ever be credited within commit messages … no Co-Developed-By or Co-Authored-By or
  anything similar that lists an AI model". Agents must add a reviewed-by-human marker
  that only the human removes. Whether `Assisted-by:` counts as "anything similar" isn't
  stated. Assume it does.
- Disclosure was required from 2025-07 until
  [systemd/systemd#42636](https://github.com/systemd/systemd/pull/42636) (2026-06-17) dropped it.
- As of: CONTRIBUTING.md `643b93185c` (2026-10-03), AGENTS.md `75344c7829` (2026-09-09).

### fedora-atomic-desktops-sealed

- The repo and the owner's `.github` have no contributor files. The
  [Fedora AI policy](https://docs.fedoraproject.org/en-US/council/policy/ai-contribution-policy/)
  (v1.0, 2025-10-24) says: "You MUST disclose the use of AI tools when the significant part
  of the contribution is taken from a tool without changes". Recommended method: an
  `Assisted-by:` trailer. It applies only by [INFERENCE]: the repo is personal and doesn't
  adopt it.

### ublue-os image-template

- The repo and `ublue-os/.github` have no AI text.
  [universal-blue.org/contributing](https://universal-blue.org/contributing.html): "you must
  agree that you have authored 100% of the content". Conventional Commits are bot-enforced.
- projectbluefin's [org AGENTS.md](https://github.com/projectbluefin/.github/blob/main/AGENTS.md)
  forbids its agents from any write to `ublue-os/*`. That's a sibling org's rule, not
  ublue-os policy.

### Zen Browser

- The repo, [docs/contribute](https://docs.zen-browser.app/contribute) and the CoC
  (Contributor Covenant 2.1) have no AI text. A member closed
  [zen-browser/desktop#15898](https://github.com/zen-browser/desktop/pull/15898) (2026-10-11): "this seems very
  AI generated". PRs target `dev`, with `{bugId}: {message}` commits.

### Flathub (Zen manifest)

- [Requirements § Generative AI policy](https://docs.flathub.org/docs/for-app-authors/requirements):
  "Flathub manifests must not contain AI-generated or AI-assisted content. Disclosure does
  not exempt manifests from this restriction." "AI tools or agents must not open or
  automate Flathub submission pull requests, or generate their commit messages,
  descriptions, review comments, or replies." Repeat violations can mean a permanent ban.
- `flathub/app.zen_browser.zen` holds only the manifest, so every PR there is a manifest
  change.

### arboard

- The repo has README, licences and CI only, and 1Password has no org `.github`.
  Contributions are dual-licensed by default (README).

### umbriel

- [CONTRIBUTING.md](https://github.com/noctalia-dev/umbriel/blob/main/CONTRIBUTING.md) and
  the templates have no AI text. Conventional Commits, summary line by default. As of
  `94ecec54cc` (2026-10-13).

### seance

- [CONTRIBUTING.md](https://github.com/no1msd/seance/blob/main/CONTRIBUTING.md) and the
  templates have no AI text. Use an issue template, and open a Discussion before larger
  features. As of `fbab426d53` (2026-09-10).

## Refreshing

- **When the check fails with MISSING:** research the new upstream the same way. Check the
  repo root and `docs/` for CONTRIBUTING, AGENTS.md, CLAUDE.md, AI_POLICY, the PR and issue
  templates, the org `.github` repo, the project or platform-wide policy, and an issue
  search for AI/LLM policy threads. Add a row and a Details subsection, dated, with the
  policy file's commit SHA.
- **When it fails with STALE:** krytis no longer holds anything there. Delete the row and
  its subsection. If the upstream is still a likely PR target, re-scope it into Stake.
- **Policies change fast.** Ten of the rules above were adopted or rewritten in 2026-08
  through 2026-10. Re-read a row's sources before acting on it if its date is more than a
  month old. The check doesn't do this: it proves coverage, not currency.
