# Plan: Runner Follow-up (post-validation)

Follow-up work deferred from the initial self-hosted runner setup
(`feat/self-hosted-runner`). Do these after the runner has been validated
end-to-end against `cache-warm`.

---

## 1. Migrate cache-warm.yml to self-hosted runner

**File:** `.github/workflows/cache-warm.yml`

Change:
```yaml
runs-on: blacksmith-8vcpu-ubuntu-2404
```
to:
```yaml
runs-on: [self-hosted, linux, x64]
```

The label set `[self-hosted, linux, x64]` matches `RUNNER_LABELS` in `mise.toml`.

**Before merging:** confirm the runner is registered and idle in
repo Settings → Actions → Runners. Run the workflow once via `workflow_dispatch`
on the feature branch and verify it picks up the self-hosted runner (not Blacksmith)
and the build completes successfully.

**Rollback:** revert `runs-on` to `blacksmith-8vcpu-ubuntu-2404` if the
self-hosted runner proves unreliable.

---

## 2. Systemd user service for persistent runner

Keep the runner running across reboots without requiring manual `mise run runner:start`.
Use a **user** service (not a system service) so it runs under the user's session
and has access to the user's podman socket and secrets.

**File:** `files/runner/krytis-runner.service`

```ini
[Unit]
Description=Krytis self-hosted GitHub Actions runner
After=network-online.target

[Service]
Type=simple
ExecStartPre=mise run runner:start
ExecStop=mise run runner:stop
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
```

**Install:**
```bash
mkdir -p ~/.config/systemd/user/
cp files/runner/krytis-runner.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now krytis-runner
```

**Notes:**
- Requires lingering enabled (`loginctl enable-linger $USER`) if you want it to
  start before login.
- `ExecStartPre` runs `mise run runner:start` which handles token refresh and
  secret prompting — on first install the service may need an interactive run to
  store the PAT.
- Consider a `runner:secret-reset` task (`podman secret rm gh-token`) for rotating
  the PAT without reinstalling the service.

---

## 3. Renovate tracking for RUNNER_VERSION

`RUNNER_VERSION` in `mise.toml` is currently a manually pinned string. Wire it
into Renovate so version bumps arrive as PRs.

**Option A — regex manager** (add to `renovate.json5`):
```json5
{
  "regexManagers": [
    {
      "fileMatch": ["^mise\\.toml$"],
      "matchStrings": [
        "RUNNER_VERSION = \\{ default = \"(?<currentValue>[^\"]+)\" \\}"
      ],
      "depNameTemplate": "actions/runner",
      "datasourceTemplate": "github-releases"
    }
  ]
}
```

**Option B — mise manager**: if Renovate's `mise` manager gains support for
arbitrary `[env]` variables, use that instead; remove the regex manager.

Verify the Renovate regex picks up the correct field by running
`renovate --dry-run` locally or checking the Renovate dashboard after merging.
