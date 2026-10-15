# GitHub Issues & Projects v2 — Reference

Load when filing or triaging krytis issues (effort labels), or when creating or
managing the GitHub Project board, milestones, or issue hierarchies.

**Project board:** https://github.com/orgs/starlit-os/projects/1 (project #1, org: starlit-os)

---

## Prerequisites

Projects v2 requires the `project` OAuth scope. The default `gh auth login`
token does not include it. Add it once:

```bash
gh auth refresh -s project
```

Without this, `createProjectV2` / `addProjectV2ItemById` mutations fail
with `INSUFFICIENT_SCOPES` — and so does *reading* the board: a plain
`organization(login:"starlit-os"){ projectV2(number:1) }` query is rejected field-by-field
with `requires one of the following scopes: ['read:project']`. Confirmed 2026-09-24 against
a token holding `gist, read:org, repo, workflow`. Assume every field ID in § Krytis project
field IDs is unverifiable until the scope is added.

**Sub-issue linking is the exception**: both the REST endpoint and the GraphQL
`addSubIssue` mutation need only `repo`. See § Link native sub-issues. Do not burn a
scope refresh on parenting alone.

---

## Effort labels

Every open issue carries **exactly one** `effort:*` label, or `tracking` and no effort
label. The label set (names, colours, descriptions) is defined in
`mise/tasks/labels-sync`; that file is the source of truth, and this section is the rule
for choosing one.

| Label | Hands-on work once the issue is unblocked |
|---|---|
| `effort:XS` | Under an hour: a comment, a decision write-up, a doc fix, or a one-liner. No image build. |
| `effort:S` | About half a day: one element, task or doc section, with at most one build and `boot-test`. |
| `effort:M` | One to three days: several elements, or a new mechanism (task + CI job + docs), with repeated build/`boot-test` rounds. |
| `effort:L` | More than three days or more than one PR: a design to settle first, a large rebuild (dozens of elements), or a stack of dependent PRs. |
| `tracking` | Umbrella or watch list whose work lives in sub-issues or other issues. No effort label. |

```shell
mise run labels-sync           # create the labels, or update colour/description after editing the task
mise run labels-sync --check   # list open issues with zero or several effort labels, or effort on a tracking issue; exit 1 if any
```

**Effort measures the work, not the wait.** A Design, Security, Breakage or Upstream gate,
an owner decision, an upstream release, hardware access or a date all go in the comment,
never into the size. An XS blocked on a Security decision is still XS, and becomes
low-hanging the moment the decision exists. A hardware run counts like a `boot-test`;
getting to the hardware is a blocker, not effort.

**Rules:**

- **Label at filing.** Whoever files the issue, agent or human, sizes it. If the work
  can't be sized yet, size the investigation that would size it; that is what
  `Investigate …` issues are.
- **Between two sizes, take the larger.** #1056 used "S–M"; the labels have no ranges.
- **One sizing comment** goes with the first label: what the work is, what blocks it, the
  next step (format below). It replaces the central triage list #1056 used to keep.
- **Re-size in the open.** When scope changes, swap the label and add a comment naming what
  changed. A label changed without a comment looks like the original estimate.
- **`tracking` is for umbrellas only.** A `Track <thing> upstream` issue that ends in a
  krytis action (drop a workaround, bump a pin, delete an override) is not tracking: size
  that action and keep the existing `upstream` label for the wait. #483, #479 and #641 are
  tracking; #545 and #1041 are not.
- **Split a cheap piece out of a large issue** as a sub-issue (§ Link native sub-issues)
  so it shows up in an XS/S query. #1074 and #1075 came out of #1034 and #1035 this way and
  shipped while their parents stayed blocked.
- **Blocked by another krytis issue → set the native link** (§ Link blocking
  dependencies), not only the sentence in the comment. GitHub then shows "Blocked by" on
  the issue and in search (`is:blocked`), and the link survives the comment going stale.

Sizing comment format, one comment per issue:

```markdown
**Effort: S.** <one sentence: what the hands-on work is.>

**Blocked on:** <gate / owner decision / linked upstream item "as of YYYY-MM-DD" / hardware>, or nothing — ready.

**Next step:** <one concrete action.>
```

Finding work:

```shell
gh issue list --label effort:XS                          # AND across --label flags, so one size per call
gh issue list --search 'label:effort:XS,effort:S -label:upstream'   # comma is OR inside one label: qualifier
```

Neither query knows about gates; read the sizing comment before picking an issue up.

**Why labels instead of a triage issue.** #1056 held the whole triage in one issue body
for two weeks (2026-10-01 to 2026-10-15). It needed a full re-inventory after ten days,
because the PR that changed an item never touched the list describing it, which is the
same rot mechanism AGENTS.md § Skill files rot too describes for open issue bodies. A
label and a comment live on the issue the fixing PR closes or links. **Why not a Projects
field:** the board needs the `project` token scope (§ Prerequisites); labels need only
`repo` and filter from `gh issue list`.

---

## Milestones

`gh milestone` is not a valid command. Use the REST API:

```bash
gh api repos/starlit-os/krytis/milestones \
  -f title="v0.1 — bootable baseline" \
  -f description="..." \
  -f state="open" | jq .number
```

---

## Create a project

```graphql
mutation {
  createProjectV2(input: {
    ownerId: "O_kgDOCsrkFw"   # starlit-os org node ID
    title: "Krytis"
  }) {
    projectV2 { id number url }
  }
}
```

After creating, go to **Project Settings → Default repository** and set it to `starlit-os/krytis`. This makes new issues created from the project board land in the right repo automatically. Not settable via the GraphQL API as of June 2026 — UI only.


---

## Add issues to the project

```bash
gh api graphql -f query='
mutation {
  addProjectV2ItemById(input: {
    projectId: "PVT_kwDOCsrkF84BbD8k"
    contentId: "<issue-node-id>"
  }) {
    item { id }
  }
}'
```

Get issue node IDs in bulk:

```bash
gh api graphql -f query='
{
  repository(owner: "starlit-os", name: "krytis") {
    issues(first: 40, orderBy: {field: CREATED_AT, direction: ASC}) {
      nodes { id number }
    }
  }
}'
```

---

## Link native sub-issues

**Prefer REST — it works with the default `repo` scope**, so no `gh auth refresh`
and no device-code round trip:

```bash
child=$(gh api repos/starlit-os/krytis/issues/<child> --jq .id)   # numeric id, NOT the node id
gh api -X POST repos/starlit-os/krytis/issues/<parent>/sub_issues -F sub_issue_id="$child"
```

`sub_issue_id` takes the REST **numeric** `id` (a 10-digit integer such as
`5304894712`), not the `number` and not the GraphQL node id. `-F` rather than
`-f`, or it is sent as a string and rejected.

The GraphQL mutation below does the same thing, and it also works with only the `repo`
scope: on 2026-10-14 it linked #1232 under #483 with a token holding
`gist, read:org, repo, workflow`, while `addProjectV2ItemById` on the same token failed
with `INSUFFICIENT_SCOPES`. Only board operations need `project`:

```graphql
mutation {
  addSubIssue(input: {
    issueId: "<parent-node-id>"
    subIssueId: "<child-node-id>"
  }) {
    issue { number }
    subIssue { number }
  }
}
```

Run in parallel (background `&` + `wait`) for bulk linking.

---

## Link blocking dependencies

Same shape as sub-issues: REST, numeric `id`, default `repo` scope is enough (verified
2026-10-15 linking #1034 as blocked by #1033 with `gist, read:org, repo, workflow`):

```bash
blocker=$(gh api repos/starlit-os/krytis/issues/<blocker> --jq .id)   # numeric id, NOT the number
gh api -X POST repos/starlit-os/krytis/issues/<blocked>/dependencies/blocked_by -F issue_id="$blocker"
gh api repos/starlit-os/krytis/issues/<blocked>/dependencies/blocked_by --jq '.[].number'   # read back
gh api repos/starlit-os/krytis/issues/<blocker>/dependencies/blocking --jq '.[].number'     # other side
```

One POST sets both directions. Remove with
`gh api -X DELETE repos/starlit-os/krytis/issues/<blocked>/dependencies/blocked_by/<blocker-id>`.
Use it only for krytis-to-krytis blocks; an upstream wait stays in the sizing comment with
the `upstream` label.

---

## Status field (single-select)

The `Milestone` field is **built-in** to Projects v2 — do not try to create it
with `createProjectV2Field`. It auto-populates from the milestone set on each issue.

To add or modify Status options, use `updateProjectV2Field` — note: no `projectId`
argument (only `fieldId`):

```graphql
mutation {
  updateProjectV2Field(input: {
    fieldId: "PVTSSF_lADOCsrkF84BbD8kzhV3JIg"
    singleSelectOptions: [
      { name: "Todo",       color: GRAY,   description: "" }
      { name: "In Progress", color: YELLOW, description: "" }
      { name: "In Review",  color: BLUE,   description: "" }
      { name: "Done",       color: GREEN,  description: "" }
    ]
  }) {
    projectV2Field {
      ... on ProjectV2SingleSelectField { options { id name } }
    }
  }
}
```

Passing `projectId` here causes `argumentNotAccepted` — it is not a valid input field.

---

## Krytis project field IDs (for reference)

| Field | ID |
|---|---|
| Status (single-select) | `PVTSSF_lADOCsrkF84BbD8kzhV3JIg` |
| Milestone (built-in) | `PVTF_lADOCsrkF84BbD8kzhV3JIs` |
| Parent issue | `PVTF_lADOCsrkF84BbD8kzhV3JI8` |
| Sub-issues progress | `PVTF_lADOCsrkF84BbD8kzhV3JJA` |
| Project node ID | `PVT_kwDOCsrkF84BbD8k` |
| Org node ID | `O_kgDOCsrkFw` |
