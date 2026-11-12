# Contributing

Issues and pull requests are welcome. For a security problem, follow
[`SECURITY.md`](SECURITY.md) instead of opening an issue.

## Before you start

[`AGENTS.md`](AGENTS.md) holds the rules every change follows, for people and agents
alike, and [`docs/SKILL.md`](docs/SKILL.md) routes to the notes for each area. Read
`AGENTS.md` first: it says which changes need a maintainer's decision before work
starts (architecture, auth and signing, the boot path, anything sent to another
project).

## Setup

Every tool comes from [mise](https://mise.jdx.dev), pinned in `mise.toml`, and every
maintenance step is a mise task (`mise tasks` lists them). [`README.md`](README.md)
§ Setup shows how to bootstrap a machine and build the image.

## Before you open a pull request

- If the change can reach the image, `mise run build` passes (it ends with the lint and
  image gates) and the image boots: `mise run boot-test`. Say in the PR what you ran.
  `AGENTS.md` § Mandatory Gates says when a change can't reach the image and needs
  neither.
- If you changed docs, `mise run docs-links` passes.
- If you learned something a future contributor would need, write it into the matching
  file under `docs/skills/`, in the same PR.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org).
- Sign your commits, so GitHub shows them as Verified. The `main` ruleset refuses
  unsigned commits, with no exceptions.

Pull requests are merged with a merge commit, never squashed or rebased.

## AI-assisted contributions

AI tools are allowed. This repository itself is largely written with AI coding agents,
and `AGENTS.md` is their entry point. Two rules:

1. **Disclose it.** Say in the pull request description which tool you used and what it
   did, or add an `Assisted-by: <tool>` trailer to the commits it helped write. The same
   applies to issues and security reports.
2. **You own the result.** Read and understand every line before you submit it, and run
   the checks above yourself. Generated code, reports or review replies that nobody
   verified will be closed.
