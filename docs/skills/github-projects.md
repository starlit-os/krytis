# GitHub Projects v2 — API Reference

Load when creating or managing the GitHub Project board, milestones, or issue
hierarchies for krytis.

**Project board:** https://github.com/orgs/starlit-os/projects/1 (project #1, org: starlit-os)

---

## Prerequisites

Projects v2 requires the `project` OAuth scope. The default `gh auth login`
token does not include it. Add it once:

```bash
gh auth refresh -s project
```

Without this, all `createProjectV2` / `addProjectV2ItemById` / `addSubIssue`
mutations fail with `INSUFFICIENT_SCOPES`.

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
