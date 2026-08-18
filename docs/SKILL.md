# Krytis Skill Router

Agent entry point. Load only the skill for your current task — do not load everything.

## Task → Skill

| I need to... | Load |
|---|---|
| Understand BST element syntax and patterns | [`docs/skills/bst.md`](skills/bst.md) |
| Add a package to Krytis | [`docs/skills/bst.md`](skills/bst.md) § Adding a Package |
| Debug a build failure | [`docs/skills/bst.md`](skills/bst.md) § BST Weak-Key Caching Bug |
| Understand the OCI assembly pipeline | [`docs/skills/bst.md`](skills/bst.md) § OCI Assembly Pipeline |
| Package a Rust project | [`docs/skills/bst.md`](skills/bst.md) § Rust / Cargo Projects |
| Package a prebuilt desktop app — choose `.deb` vs portable tarball, defuse an Electron self-updater | [`docs/skills/bst.md`](skills/bst.md) § Electron self-updaters on a read-only image |
| Backport a patch onto a release pinned by a junction | [`docs/skills/bst.md`](skills/bst.md) § Mirroring a junction element to patch its *source* |
| Work with greetd / noctalia-greeter / wlroots rendering | [`docs/skills/desktop.md`](skills/desktop.md) |
| PAM stack, keyring integration, FIDO2 auth flow | [`docs/skills/pam.md`](skills/pam.md) |
| Decide whether to (re-)attempt the gnome-keyring → oo7 migration (#84) | [`docs/design/secrets-service.md`](design/secrets-service.md) |
| Re-pin oo7, or check whether an upstream oo7 fix actually helps krytis (`mise run oo7-prompter-test`) | [`docs/skills/pam.md`](skills/pam.md) § krytis patches oo7's prompter detection |
| Change SSH config, sshd auth policy, or make SSH work for some account type | [`docs/skills/pam.md`](skills/pam.md) § `UsePAM yes` — **read the priority note first: SSH is opt-in and not a release blocker** |
| Secure boot, signed UKI, TPM/PCR interaction with LUKS | [`docs/skills/secure-boot.md`](skills/secure-boot.md) |
| Generate or debug the firmware key-enrollment `.auth` files, or refresh the dbx revocation list (`mise run enroll-test`, `mise run fetch-microsoft-dbx`, `scripts/parse-efi-auth.py`) | [`docs/skills/secure-boot.md`](skills/secure-boot.md) § Every shipped `.auth` enrolled an empty allow-list |
| Decide which boot-chain tests to run for a change, or find what is still untested | [`docs/design/secure-boot-testing.md`](design/secure-boot-testing.md) |
| Work on gaming support, or wonder why there is no native Steam/gamescope/sysext | [`docs/design/gaming-variant.md`](design/gaming-variant.md) |
| Use or extend mise tasks and tool installation | [`docs/skills/mise.md`](skills/mise.md) |
| Reference or borrow from the sibling zirconium-hawaii project | [`docs/skills/zirconium-hawaii.md`](skills/zirconium-hawaii.md) |
| Manage the GitHub Project board, milestones, or issue hierarchy | [`docs/skills/github-projects.md`](skills/github-projects.md) |
| Set up a worktree / branch, or follow the self-improvement loop | [`docs/skills/workflow.md`](skills/workflow.md) |
| Sync dakota/zirconium-hawaii forks and mine them for lessons | [`docs/skills/upstream-sync.md`](skills/upstream-sync.md), skill: `.claude/skills/upstream-lessons/` |
| Generate/attach the SBOM or run the Grype vuln scan (`mise run sbom`, `mise run vuln-scan`, `mise run push`) | [`docs/skills/sbom.md`](skills/sbom.md) |
| Re-check Grype vuln-scan false positives, or update `.grype.yaml`'s ignore list | [`docs/skills/sbom.md`](skills/sbom.md) § Mitigated: Grype `stock-matcher`..., skill: `.claude/skills/vuln-scan-triage/` |
| Change `.github/renovate.json5`, enable a manager, or decide what auto-merges (`mise run renovate-check`) | [`docs/skills/renovate.md`](skills/renovate.md) |
| Sign the published image/SBOM/vuln report with cosign, or work on the publish workflow (`mise run sign`, `.github/workflows/publish.yml`) | [`docs/skills/signing.md`](skills/signing.md) |
| Write a design doc or an implementation plan | [`AGENTS.md`](../AGENTS.md) § Plan & Design Docs — `docs/design/` vs `docs/plans/` |

## Reference Docs

| Topic | File |
|---|---|
| Agent workflow, decision gates, skill mandate | [`AGENTS.md`](../AGENTS.md) |
| Enroll secure boot keys on real hardware | [`docs/secure-boot-enrollment.md`](secure-boot-enrollment.md) |
| Architecture, rationale, deferred work | [`docs/design/`](design/) |
| Live execution plans (dated) | [`docs/plans/`](plans/) — completed ones in [`done/`](plans/done/) |

## Full Skill Index

Skills are added to `docs/skills/` as they are written. Check that directory for the current list.
