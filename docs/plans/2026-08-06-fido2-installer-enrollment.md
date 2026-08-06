# FIDO2 LUKS Installer Enrollment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `fido2-luks-passphrase` install-time encryption option to fisherman + bootc-installer, mirroring the existing `tpm2-luks-passphrase` support, and enable it for krytis's live-ISO installer (`dakota-iso`, krytis variant).

**Architecture:** fisherman's `luks.EnrollFIDO2()` shells out to `systemd-cryptenroll --fido2-device=auto` after `bootc install to-filesystem`, exactly mirroring the existing `EnrollTPM2()` shape. The FIDO2 PIN (when the key has one) is supplied non-interactively via systemd's Credentials mechanism (`CREDENTIALS_DIRECTORY` env var + a file named `cryptenroll.fido2-pin`) — a source-verified path (`src/shared/creds-util.c`'s `get_credentials_dir_internal()` is a bare `secure_getenv()` + path-shape check, no systemd-unit context required) that needs zero PTY/agent machinery. bootc-installer's GTK wizard collects the PIN up front via a new masked entry, exactly like it already collects the LUKS passphrase, and passes it through `recipe.json`. The physical "touch your key" step needs no reply channel — it's a one-way `log_notice()` in systemd's own source, not an interactive query — so fisherman surfaces it with a plain `progress.Info()` call using existing infrastructure.

**Tech Stack:** Go 1.22 (fisherman), Python 3 + GTK4/Libadwaita + Blueprint (bootc-installer), bash (dakota-iso live-ISO config).

## Global Constraints

- This plan implements **only** `fido2-luks-passphrase` (passphrase always required as fallback). Do **not** implement a passphrase-less `fido2-luks` type — [starlit-os/krytis#250](https://github.com/starlit-os/krytis/issues/250) (FIDO2 boot-unlock race, unresolved after 2 real-hardware fix attempts) means a failed unlock with no fallback would leave the system unbootable. This is a hard requirement, not a style preference.
- Every new fisherman subprocess-shelling function must keep secrets out of argv/log exactly like the existing code does: passphrases go through temp files (`--unlock-key-file=`), never CLI args or stdin logged verbatim. The FIDO2 PIN goes through the systemd Credentials mechanism (a mode-`0400` temp file), never argv.
- Match existing code conventions exactly in each repo — do not introduce a second style alongside a working one. Every task below cites the precedent it mirrors.
- Full findings and open questions are recorded in [starlit-os/krytis#512](https://github.com/starlit-os/krytis/issues/512) — read it before starting if anything here is unclear.
- **Task 12 (real-hardware PIN smoke test) is a hard gate before Task 13 (recipe type + EnrollFIDO2) is considered done**, not merely recommended — the `CREDENTIALS_DIRECTORY` mechanism is source-verified but has never been exercised against a real FIDO2 key with a PIN set.

---

## Phase 1: fisherman backend (Go)

Repo: `/home/lily/Projects/fisherman` (module root: `/home/lily/Projects/fisherman/fisherman`)

### Task 1: Add `fido2-luks-passphrase` recipe type

**Files:**
- Modify: `fisherman/internal/recipe/recipe.go:127-131` (Encryption struct), `fisherman/internal/recipe/recipe.go:200-207` (Validate switch)
- Test: `fisherman/internal/recipe/recipe_test.go`

**Interfaces:**
- Produces: `recipe.Encryption{Type: "fido2-luks-passphrase", Passphrase: string, FIDO2Pin: string}` — `FIDO2Pin` is optional (empty means the key has no PIN set).

- [ ] **Step 1: Write the failing tests**

Add to the `tests` table in `TestValidate` (`fisherman/internal/recipe/recipe_test.go`), right after the existing `"valid tpm2-luks-passphrase"` case (currently ends at line 67):

```go
		{
			name: "valid fido2-luks-passphrase",
			r: recipe.Recipe{
				Disk: diskPath, Filesystem: "xfs", Hostname: "h",
				Encryption: recipe.Encryption{Type: "fido2-luks-passphrase", Passphrase: "secret"},
			},
		},
		{
			name: "valid fido2-luks-passphrase with PIN",
			r: recipe.Recipe{
				Disk: diskPath, Filesystem: "xfs", Hostname: "h",
				Encryption: recipe.Encryption{Type: "fido2-luks-passphrase", Passphrase: "secret", FIDO2Pin: "1234"},
			},
		},
```

And in the "Invalid: encryption" section, right after the existing `"tpm2-luks-passphrase empty passphrase"` case (currently ends at line 163):

```go
		{
			name: "fido2-luks-passphrase empty passphrase",
			r: recipe.Recipe{
				Disk: diskPath, Filesystem: "xfs", Hostname: "h",
				Encryption: recipe.Encryption{Type: "fido2-luks-passphrase"},
			},
			wantErr: "passphrase required",
		},
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/lily/Projects/fisherman/fisherman && go test ./internal/recipe/... -run TestValidate -v`
Expected: FAIL — `"valid fido2-luks-passphrase"` and `"fido2-luks-passphrase empty passphrase"` subtests fail because `Validate()` rejects `fido2-luks-passphrase` as an unknown encryption type.

- [ ] **Step 3: Implement the recipe type**

Edit `fisherman/internal/recipe/recipe.go`. Replace the `Encryption` struct (lines 127-131):

```go
// Encryption describes the disk encryption configuration.
type Encryption struct {
	Type       string `json:"type"`       // "none", "luks-passphrase", "tpm2-luks", "tpm2-luks-passphrase", "fido2-luks-passphrase"
	Passphrase string `json:"passphrase"` // required for luks-passphrase, tpm2-luks-passphrase, and fido2-luks-passphrase
	// FIDO2Pin is the FIDO2 device's own PIN, if it has one set. Optional —
	// many security keys have no PIN configured. Only used when Type is
	// "fido2-luks-passphrase". Supplied to systemd-cryptenroll via the
	// Credentials mechanism (CREDENTIALS_DIRECTORY), never via argv or stdin.
	FIDO2Pin string `json:"fido2Pin,omitempty"`
}
```

Replace the encryption validation block (lines 200-207):

```go
	switch r.Encryption.Type {
	case "", "none", "tpm2-luks", "luks-passphrase", "tpm2-luks-passphrase", "fido2-luks-passphrase":
	default:
		return fmt.Errorf("encryption.type must be \"none\", \"luks-passphrase\", \"tpm2-luks\", \"tpm2-luks-passphrase\", or \"fido2-luks-passphrase\"")
	}
	if (r.Encryption.Type == "luks-passphrase" || r.Encryption.Type == "tpm2-luks-passphrase" || r.Encryption.Type == "fido2-luks-passphrase") && r.Encryption.Passphrase == "" {
		return fmt.Errorf("encryption.passphrase required for %s", r.Encryption.Type)
	}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/lily/Projects/fisherman/fisherman && go test ./internal/recipe/... -v`
Expected: PASS, all subtests including the 3 new ones.

- [ ] **Step 5: Commit**

```bash
cd /home/lily/Projects/fisherman
git add fisherman/internal/recipe/recipe.go fisherman/internal/recipe/recipe_test.go
git commit -m "feat(recipe): add fido2-luks-passphrase encryption type"
```

---

### Task 2: Implement `luks.EnrollFIDO2()`

**Files:**
- Modify: `fisherman/internal/luks/luks.go` (add function + `path/filepath` import)
- Test: `fisherman/internal/luks/luks_test.go`

**Interfaces:**
- Consumes: `runner.Run(name string, args ...string) error` (existing, `fisherman/internal/runner/runner.go:84-86`)
- Produces: `luks.EnrollFIDO2(partition, unlockPassphrase, pin string) error`

- [ ] **Step 1: Write the failing tests**

Add to `fisherman/internal/luks/luks_test.go`, right after `TestEnrollTPM2` (currently ends at line 179):

```go
func TestEnrollFIDO2_NoPIN(t *testing.T) {
	const part = "/dev/sda3"
	const pass = "hunter2"

	rec := setup(t)
	if err := luks.EnrollFIDO2(part, pass, ""); err != nil {
		t.Fatalf("EnrollFIDO2: %v", err)
	}

	if len(rec.calls) != 1 {
		t.Fatalf("expected 1 call, got %d", len(rec.calls))
	}
	c := rec.calls[0]

	if c.name != "systemd-cryptenroll" {
		t.Errorf("name = %q, want systemd-cryptenroll", c.name)
	}
	// Args: --fido2-device=auto, --unlock-key-file=<tmp>, partition.
	if len(c.args) != 3 {
		t.Fatalf("expected 3 args, got %d: %v", len(c.args), c.args)
	}
	if c.args[0] != "--fido2-device=auto" {
		t.Errorf("args[0] = %q, want --fido2-device=auto", c.args[0])
	}
	if !strings.HasPrefix(c.args[1], "--unlock-key-file=") {
		t.Errorf("args[1] = %q, want --unlock-key-file=<path>", c.args[1])
	}
	if c.args[2] != part {
		t.Errorf("args[2] = %q, want %q", c.args[2], part)
	}
	for _, arg := range c.args {
		if strings.Contains(arg, pass) {
			t.Errorf("passphrase leaked into argv: %q", arg)
		}
	}
	if c.stdin != "" {
		t.Errorf("stdin = %q, want empty (passphrase goes to temp file)", c.stdin)
	}
	if os.Getenv("CREDENTIALS_DIRECTORY") != "" {
		t.Errorf("CREDENTIALS_DIRECTORY leaked into process env after EnrollFIDO2 with no PIN: %q", os.Getenv("CREDENTIALS_DIRECTORY"))
	}
}

func TestEnrollFIDO2_WithPIN(t *testing.T) {
	const part = "/dev/sda3"
	const pass = "hunter2"
	const pin = "1234"

	rec := setup(t)
	if err := luks.EnrollFIDO2(part, pass, pin); err != nil {
		t.Fatalf("EnrollFIDO2: %v", err)
	}

	if len(rec.calls) != 1 {
		t.Fatalf("expected 1 call, got %d", len(rec.calls))
	}
	c := rec.calls[0]

	if c.name != "systemd-cryptenroll" {
		t.Errorf("name = %q, want systemd-cryptenroll", c.name)
	}
	if len(c.args) != 3 {
		t.Fatalf("expected 3 args, got %d: %v", len(c.args), c.args)
	}
	for _, arg := range c.args {
		if strings.Contains(arg, pin) {
			t.Errorf("PIN leaked into argv: %q", arg)
		}
	}
	// CREDENTIALS_DIRECTORY must have been set (and cleaned up) around the call.
	// Since EnrollFIDO2 unsets it via defer before returning, we can only assert
	// it's clean *after* the call — the credential file itself is asserted next.
	if os.Getenv("CREDENTIALS_DIRECTORY") != "" {
		t.Errorf("CREDENTIALS_DIRECTORY leaked into process env after EnrollFIDO2 returned: %q", os.Getenv("CREDENTIALS_DIRECTORY"))
	}
}

// TestEnrollFIDO2_WithPIN_WritesCredentialFile verifies the PIN is written to
// a file named exactly "cryptenroll.fido2-pin" (the credential name
// systemd-cryptenroll's FIDO2 PIN prompt looks up) with restrictive
// permissions, and that CREDENTIALS_DIRECTORY points at its parent directory
// *during* the call. This intercepts the env var via a custom RunFn that
// captures os.Getenv at call time rather than after EnrollFIDO2 returns.
func TestEnrollFIDO2_WithPIN_WritesCredentialFile(t *testing.T) {
	const part = "/dev/sda3"
	const pass = "hunter2"
	const pin = "5678"

	var capturedCredDir string
	var capturedPinContents []byte
	runner.RunFn = func(stdin io.Reader, name string, args ...string) error {
		capturedCredDir = os.Getenv("CREDENTIALS_DIRECTORY")
		if capturedCredDir != "" {
			b, err := os.ReadFile(filepath.Join(capturedCredDir, "cryptenroll.fido2-pin"))
			if err != nil {
				t.Fatalf("reading credential file during call: %v", err)
			}
			capturedPinContents = b
			info, err := os.Stat(filepath.Join(capturedCredDir, "cryptenroll.fido2-pin"))
			if err != nil {
				t.Fatalf("stat credential file during call: %v", err)
			}
			if info.Mode().Perm() != 0o400 {
				t.Errorf("credential file mode = %v, want 0400", info.Mode().Perm())
			}
		}
		return nil
	}
	t.Cleanup(func() { runner.RunFn = runner.DefaultRun })

	if err := luks.EnrollFIDO2(part, pass, pin); err != nil {
		t.Fatalf("EnrollFIDO2: %v", err)
	}

	if capturedCredDir == "" {
		t.Fatal("CREDENTIALS_DIRECTORY was not set during the systemd-cryptenroll call")
	}
	if string(capturedPinContents) != pin {
		t.Errorf("credential file contents = %q, want %q", capturedPinContents, pin)
	}
	// The temp dir must be cleaned up after EnrollFIDO2 returns.
	if _, err := os.Stat(capturedCredDir); !os.IsNotExist(err) {
		t.Errorf("credentials dir %q still exists after EnrollFIDO2 returned", capturedCredDir)
	}
}
```

Add `"os"`, `"path/filepath"` to `fisherman/internal/luks/luks_test.go`'s import block (it currently imports `"errors"`, `"io"`, `"strings"`, `"testing"`, plus the two internal packages).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/lily/Projects/fisherman/fisherman && go test ./internal/luks/... -run TestEnrollFIDO2 -v`
Expected: FAIL — `luks.EnrollFIDO2` does not exist yet (compile error).

- [ ] **Step 3: Implement `EnrollFIDO2`**

Edit `fisherman/internal/luks/luks.go`. Add `"path/filepath"` to the import block (currently `"bytes"`... actually `luks.go` imports are minimal — check the existing import block at the top of the file and add `"path/filepath"` alongside the existing `"fmt"`, `"os"`, `"strings"` if not already present). Add this function after `EnrollTPM2` (after line 97):

```go
// EnrollFIDO2 adds a FIDO2 auto-unlock token to an existing LUKS2 container,
// authenticating with the supplied unlock passphrase. The passphrase remains
// as a fallback unlock method — callers must never enroll FIDO2 without a
// passphrase fallback (see fisherman's checkRequiredTools/recipe validation,
// which only permits "fido2-luks-passphrase", not a passphrase-less variant).
//
// The unlock passphrase is written to a temp file for the same reason as
// EnrollTPM2 (--unlock-key-file=- resolves against /var/roothome under
// pkexec, which does not exist).
//
// When pin is non-empty, it is supplied via systemd's Credentials mechanism
// (CREDENTIALS_DIRECTORY env var + a file named exactly "cryptenroll.fido2-pin")
// rather than any CLI flag or stdin — no such flag/env var exists for
// systemd-cryptenroll's FIDO2 PIN prompt (verified against systemd's
// src/cryptenroll/cryptenroll-fido2.c and src/shared/libfido2-util.c: the
// FIDO2 PIN prompt goes through ask_password_auto(), which tries the
// Credentials directory first). get_credentials_dir_internal() in systemd's
// src/shared/creds-util.c only requires CREDENTIALS_DIRECTORY to be an
// absolute, normalized path — no systemd-unit context is required, so this
// works from a plain pkexec'd process. When pin is empty, the key has no PIN
// configured and systemd-cryptenroll proceeds straight to the touch step.
//
// Physical touch confirmation on the key has no software-answerable prompt
// at all — it is a one-way log_notice() in systemd's own source, not an
// ask-password query — so the caller can only block on this call returning.
func EnrollFIDO2(partition, unlockPassphrase, pin string) error {
	f, err := os.CreateTemp("", "fisherman-luks-key-*")
	if err != nil {
		return fmt.Errorf("creating temp key file: %w", err)
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(unlockPassphrase); err != nil {
		f.Close()
		return fmt.Errorf("writing temp key file: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("closing temp key file: %w", err)
	}

	args := []string{
		"--fido2-device=auto",
		fmt.Sprintf("--unlock-key-file=%s", f.Name()),
		partition,
	}

	if pin == "" {
		return runner.Run("systemd-cryptenroll", args...)
	}

	credDir, err := os.MkdirTemp("", "fisherman-fido2-cred-*")
	if err != nil {
		return fmt.Errorf("creating credentials dir: %w", err)
	}
	defer os.RemoveAll(credDir)
	pinPath := filepath.Join(credDir, "cryptenroll.fido2-pin")
	if err := os.WriteFile(pinPath, []byte(pin), 0o400); err != nil {
		return fmt.Errorf("writing FIDO2 PIN credential: %w", err)
	}

	if err := os.Setenv("CREDENTIALS_DIRECTORY", credDir); err != nil {
		return fmt.Errorf("setting CREDENTIALS_DIRECTORY: %w", err)
	}
	defer os.Unsetenv("CREDENTIALS_DIRECTORY")

	return runner.Run("systemd-cryptenroll", args...)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/lily/Projects/fisherman/fisherman && go test ./internal/luks/... -v`
Expected: PASS, all tests including the 3 new ones and the existing `TestEnrollTPM2` etc.

- [ ] **Step 5: Commit**

```bash
cd /home/lily/Projects/fisherman
git add fisherman/internal/luks/luks.go fisherman/internal/luks/luks_test.go
git commit -m "feat(luks): add EnrollFIDO2, PIN via systemd Credentials mechanism"
```

---

### Task 3: Wire FIDO2 enrollment into `main.go`

**Files:**
- Modify: `fisherman/cmd/fisherman/main.go` (lines 169-194 `checkRequiredTools`, 289-292 flag derivation, 308 `buildProfile` call, 320-322 step counting, 385-389 var block, 482-490 passphrase selection, 707-731 enrollment call site)
- Test: `fisherman/cmd/fisherman/main_test.go`

**Interfaces:**
- Consumes: `luks.EnrollFIDO2(partition, unlockPassphrase, pin string) error` (Task 2), `progress.Info(message string)` (existing, `fisherman/internal/progress/progress.go:69-71`), `progress.Step(step, total int, name string, cumulativePct, weightPct int)` (existing).

- [ ] **Step 1: Write the failing test**

Add to `fisherman/cmd/fisherman/main_test.go`, right after `TestCheckRequiredTools_MissingSystemdCryptenrollForTPM2` (currently ends at line 214):

```go
// TestCheckRequiredTools_MissingSystemdCryptenrollForFIDO2 verifies that
// systemd-cryptenroll is also required for fido2-luks-passphrase, mirroring
// the existing TPM2 check.
func TestCheckRequiredTools_MissingSystemdCryptenrollForFIDO2(t *testing.T) {
	orig := lookPath
	t.Cleanup(func() { lookPath = orig })
	lookPath = func(file string) (string, error) {
		if file == "systemd-cryptenroll" {
			return "", errors.New("not found")
		}
		return "/usr/bin/" + file, nil
	}

	r := &recipe.Recipe{
		Filesystem: "xfs",
		Encryption: recipe.Encryption{Type: "fido2-luks-passphrase", Passphrase: "hunter2"},
	}
	err := checkRequiredTools(r)
	if err == nil {
		t.Fatal("expected error for missing systemd-cryptenroll, got nil")
	}
	if !strings.Contains(err.Error(), "systemd-cryptenroll") {
		t.Errorf("error should mention systemd-cryptenroll, got: %v", err)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lily/Projects/fisherman/fisherman && go test ./cmd/fisherman/... -run TestCheckRequiredTools_MissingSystemdCryptenrollForFIDO2 -v`
Expected: FAIL — `checkRequiredTools` doesn't gate `systemd-cryptenroll` on `fido2-luks-passphrase` yet, so the missing-tool error never fires.

- [ ] **Step 3: Implement the wiring**

Edit `fisherman/cmd/fisherman/main.go`.

(a) `checkRequiredTools` (line 181) — extend the `when` condition:

```go
		{"systemd-cryptenroll", "systemd", r.Encryption.Type == "tpm2-luks" || r.Encryption.Type == "tpm2-luks-passphrase" || r.Encryption.Type == "fido2-luks-passphrase"},
```

(b) Flag derivation (lines 289-292) — add `hasFIDO2`:

```go
	hasEncryption := r.Encryption.Type != "" && r.Encryption.Type != "none"
	hasTPM2 := r.Encryption.Type == "tpm2-luks" || r.Encryption.Type == "tpm2-luks-passphrase"
	hasFIDO2 := r.Encryption.Type == "fido2-luks-passphrase"
	isManual := len(r.CustomMounts) > 0
	isSystemdBoot := r.Bootloader == "systemd" || r.Filesystem == "zfs"
```

(c) `buildProfile` call (line 308) and step counting (lines 320-322) — TPM2 and FIDO2 both add exactly one hardware-enrolment step of the same estimated weight, so combine them:

```go
	profile := buildProfile(imageCheck.NeedsPull, hasEncryption, hasTPM2 || hasFIDO2, r.VarDisk != nil && !r.VarDisk.KeepExisting)
```

```go
	if hasTPM2 || hasFIDO2 {
		totalSteps++ // extra step for TPM2/FIDO2 enrolment (both are mutually exclusive with each other)
	}
```

Leave `buildProfile`'s own signature/body (lines 47-84) untouched — its 3rd parameter already means "does this install have one extra hardware-enrolment step", which is accurate for both mechanisms; only rename its doc comment reference from "TPM2 enrolment" to "TPM2/FIDO2 enrolment" wherever it appears in that function's inline comments (the `weights = append(weights, 1) // TPM2 enrolment` line and the `osWeight--` block's comment, if any).

(d) Var block (line 387) — the existing comment already applies to both, just widen it:

```go
	var activeRootPart string  // only used for TPM2/FIDO2 enrolment, empty in manual mode
```

(e) Passphrase selection (lines 482-490) — `fido2-luks-passphrase` uses the user's own passphrase, exactly like `luks-passphrase`/`tpm2-luks-passphrase`:

```go
			var passphrase string
			switch r.Encryption.Type {
			case "luks-passphrase", "tpm2-luks-passphrase", "fido2-luks-passphrase":
				passphrase = r.Encryption.Passphrase
			case "tpm2-luks":
				passphrase = luks.RandomPassphrase()
				luksRecoveryKey = passphrase // emitted later so user can write it down
				progress.Info("TPM2-LUKS: generated random recovery passphrase; TPM2 will be enrolled after install")
			}
```

(f) Enrollment call site — add a new FIDO2 block immediately after the existing TPM2 block (after line 731, before the `// ── Step 7: Copy system flatpaks` comment at line 733):

```go
	// ── FIDO2 enrolment ──────────────────────────────────────────────────────
	// fido2-luks-passphrase adds a FIDO2 auto-unlock token so the system can
	// boot without a passphrase prompt when the security key is present. The
	// user's own passphrase always remains as the fallback — see
	// docs/plans/2026-08-06-fido2-installer-enrollment.md's Global Constraints
	// for why a passphrase-less FIDO2-only type is intentionally not offered.
	if hasFIDO2 && activeRootPart != "" {
		progress.Step(step, totalSteps, "Enrolling FIDO2 auto-unlock", profile[pi].cumulativePct, profile[pi].weightPct)
		pi++
		step++

		if r.Encryption.FIDO2Pin != "" {
			progress.Info("Touch your security key to continue…")
		} else {
			progress.Info("Enrolling FIDO2 auto-unlock — touch your security key when it blinks")
		}
		if err := luks.EnrollFIDO2(activeRootPart, r.Encryption.Passphrase, r.Encryption.FIDO2Pin); err != nil {
			// Non-fatal: the security key may not be present (e.g. VMs), or
			// enrolment may fail for other hardware reasons. The passphrase
			// fallback set up in Step 3 still works either way.
			progress.Info(fmt.Sprintf("Warning: FIDO2 enrolment failed (passphrase unlock still works): %v", err))
		}
	}

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/lily/Projects/fisherman/fisherman && go test ./cmd/fisherman/... -v`
Expected: PASS, all tests including the new one and the existing `TestCheckRequiredTools_MissingSystemdCryptenrollForTPM2`.

- [ ] **Step 5: Run the full module test suite and build**

Run: `cd /home/lily/Projects/fisherman/fisherman && go build ./... && go vet ./... && go test ./...`
Expected: `go build`/`go vet` clean; `go test ./...` passes (two pre-existing loopback tests in `internal/storage` are known to fail under a rootless container per this project's own README — that's expected and unrelated to this change).

- [ ] **Step 6: Commit**

```bash
cd /home/lily/Projects/fisherman
git add fisherman/cmd/fisherman/main.go fisherman/cmd/fisherman/main_test.go
git commit -m "feat(main): wire fido2-luks-passphrase enrolment into install flow"
```

---

## Phase 2: bootc-installer GUI (Python/GTK4/Libadwaita)

Repo: `/home/lily/Projects/bootc-installer`

### Task 4: Add `has_fido2_device()` detector

**Files:**
- Modify: `bootc_installer/core/system.py` (add method after `has_tpm2()`, lines 200-206)
- Test: `tests/unit/test_system.py`

**Interfaces:**
- Produces: `Systeminfo.has_fido2_device() -> bool` (static method, uncached — unlike `has_tpm2()`, since FIDO2 keys are removable).

- [ ] **Step 1: Write the failing test**

Add to `tests/unit/test_system.py`, inside (or immediately after) the existing `TestSysteminfoGpuAndTpmCaching` class:

```python
class TestSysteminfoFido2Detection:
    def setup_method(self):
        from bootc_installer.core.system import Systeminfo
        self.Systeminfo = Systeminfo

    def test_has_fido2_device_true_when_token_listed(self):
        fake_result = SimpleNamespace(returncode=0, stdout="/dev/hidraw0: vendor=0x1050, product=0x0407\n")
        with patch("subprocess.run", return_value=fake_result):
            assert self.Systeminfo.has_fido2_device() is True

    def test_has_fido2_device_false_when_no_devices(self):
        fake_result = SimpleNamespace(returncode=0, stdout="")
        with patch("subprocess.run", return_value=fake_result):
            assert self.Systeminfo.has_fido2_device() is False

    def test_has_fido2_device_false_when_tool_missing(self):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            assert self.Systeminfo.has_fido2_device() is False

    def test_has_fido2_device_not_cached(self):
        # Unlike has_tpm2(), a removable key can appear/disappear between calls.
        results = [
            SimpleNamespace(returncode=0, stdout=""),
            SimpleNamespace(returncode=0, stdout="/dev/hidraw0: ...\n"),
        ]
        with patch("subprocess.run", side_effect=results):
            assert self.Systeminfo.has_fido2_device() is False
            assert self.Systeminfo.has_fido2_device() is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_system.py -k Fido2 -v`
Expected: FAIL — `AttributeError: type object 'Systeminfo' has no attribute 'has_fido2_device'`.

- [ ] **Step 3: Implement `has_fido2_device()`**

Edit `bootc_installer/core/system.py`. Add right after `has_tpm2()` (after line 206):

```python
    @staticmethod
    def has_fido2_device() -> bool:
        """Detect a plugged-in FIDO2 security key via `fido2-token -L`.

        Unlike has_tpm2(), FIDO2 keys are removable — this is never cached,
        so the GUI can call it fresh on a detect/refresh action.
        """
        try:
            result = subprocess.run(
                ["fido2-token", "-L"],
                capture_output=True, text=True, timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False
        return result.returncode == 0 and bool(result.stdout.strip())
```

`subprocess` is already imported at the top of `core/system.py` (line 5).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_system.py -v`
Expected: PASS, all tests including the 4 new ones.

- [ ] **Step 5: Commit**

```bash
cd /home/lily/Projects/bootc-installer
git add bootc_installer/core/system.py tests/unit/test_system.py
git commit -m "feat(system): add has_fido2_device() detector"
```

---

### Task 5: Thread `supports_fido2` capability field through `defaults/image.py`

Mirrors the existing `needs_user_creation` field exactly (same node-inheritance shape, same public property pattern) — see `starlit-os/krytis#512` for why this is a target-image fact, not a host-hardware fact like TPM2.

**Files:**
- Modify: `bootc_installer/defaults/image.py` (lines 297, 349, 355, 382-383, 405, 412-415, 427, 436, 449, 454, 461-462, 479, 552-564 area, 590-598)
- Test: `tests/unit/test_image_helpers.py`

**Interfaces:**
- Produces: `BootcDefaultImage.supports_fido2` (new `@property`, mirrors `selected_needs_user_creation`), `get_finals()["supports_fido2"]` (new dict key, mirrors `"needs_user_creation"`).

- [ ] **Step 1: Write the failing test**

Read `tests/unit/test_image_helpers.py` first to find its exact harness for constructing a `BootcDefaultImage`-like tree-walk test (it will use a similar GI-stubbing pattern to `test_encryption.py`). Add a test asserting that a leaf node's `supports_fido2: true` field is inherited by children that don't override it and shows up in `get_finals()`, e.g.:

```python
def test_supports_fido2_inherited_and_in_finals():
    # Build a minimal 2-level tree: group with supports_fido2=True, one leaf
    # that inherits it, one leaf that explicitly overrides to False.
    tree = [
        {
            "name": "Test Group",
            "supports_fido2": True,
            "children": [
                {"name": "Inherits", "imgref": "example.com/a:latest"},
                {"name": "Overrides", "imgref": "example.com/b:latest", "supports_fido2": False},
            ],
        }
    ]
    widget = _build_image_widget_with_tree(tree)  # use whatever harness helper test_image_helpers.py already provides for _IMAGE_TREE injection
    widget._BootcDefaultImage__select_by_imgref("example.com/a:latest")  # or equivalent existing test helper for programmatic selection
    assert widget.supports_fido2 is True
    assert widget.get_finals()["supports_fido2"] is True

    widget._BootcDefaultImage__select_by_imgref("example.com/b:latest")
    assert widget.supports_fido2 is False
    assert widget.get_finals()["supports_fido2"] is False
```

Adjust the test to use whatever tree-injection/selection helpers `test_image_helpers.py` already exposes (do not invent private-name-mangled calls if a public test helper already exists in that file — read it first and match its exact existing pattern for selecting a leaf and reading `get_finals()`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_image_helpers.py -k fido2 -v`
Expected: FAIL — `KeyError: 'supports_fido2'` or `AttributeError`, since the field doesn't exist yet.

- [ ] **Step 3: Implement the threading**

Edit `bootc_installer/defaults/image.py`, mirroring `needs_user_creation` at every site:

(a) `__init__` (after line 297):
```python
        self.__selected_supports_fido2 = False
```

(b) `__build_node` signature (line 349) — add `supports_fido2_ctx=False` as the last parameter:
```python
    def __build_node(self, parent, node, ancestors, search_ctx, flatpaks_ctx=None, icon_ctx=None, carousel_ctx=None, needs_user_ctx=False, composefs_ctx=False, image_type_ctx="bootc", bootloader_ctx="", image_filesystem_ctx="", flatpak_var_path_ctx="", registry_ctx="", default_hostname_ctx="", filesystems_ctx=None, supports_fido2_ctx=False):
```

(c) inside `__build_node`, after `node_filesystems` (line 363):
```python
        node_supports_fido2 = node.get("supports_fido2", supports_fido2_ctx)
```

(d) leaf-branch `__add_leaf` call (lines 382-383) — append the new value:
```python
                self.__add_leaf(parent, node["name"], imgref, node.get("description", ""), search_ctx, ancestors,
                            node_flatpaks, node_icon, node_carousel, node_needs_user,
                            node_composefs, node_image_type, node_bootloader, node_image_filesystem,
                            node_flatpak_var_path, node_default_hostname, node_filesystems, node_supports_fido2)
```

(e) group-branch recursive call (line 405) — append the new value:
```python
            self.__build_node(exp, child, child_ancestors, child_ctx, node_flatpaks, node_icon, node_carousel, node_needs_user, node_composefs, node_image_type, node_bootloader, node_image_filesystem, node_flatpak_var_path, node_registry, node_default_hostname, node_filesystems, node_supports_fido2)
```

(f) `__add_leaf` signature (lines 412-415) — add `supports_fido2=False`:
```python
    def __add_leaf(self, parent, name, imgref, desc, search_ctx, ancestors,
                   flatpaks=None, icon=None, carousel=None, needs_user=False,
                   composefs=False, image_type="bootc", bootloader="", image_filesystem="",
                   flatpak_var_path="", default_hostname="", filesystems=None, supports_fido2=False):
```

(g) inside `__add_leaf`, `check.connect(...)` (line 427) — append `supports_fido2`:
```python
        check.connect("toggled", self.__on_check_toggled, imgref, flatpaks, icon, carousel, needs_user, composefs, image_type, bootloader, image_filesystem, flatpak_var_path, default_hostname, filesystems or [], supports_fido2)
```

(h) `self.__leaf_rows.append(...)` (line 436) — append `supports_fido2` to the tuple, and update the shape comment at line 307:
```python
        self.__leaf_rows.append((row, check, imgref, flatpaks, icon, carousel, needs_user, composefs, image_type, bootloader, image_filesystem, flatpak_var_path, default_hostname, filesystems or [], supports_fido2, search_str, list(ancestors)))
```
Update the `__leaf_rows` shape comment (line 307) to append `, supports_fido2` before `, search_str, [ancestor_exps]`.

(i) `__select_default` unpacking (line 439) — add `_supports_fido2` before `_search`:
```python
        for _row, check, imgref, _flatpaks, _icon, _carousel, _needs_user, _composefs, _image_type, _bootloader, _image_filesystem, _flatpak_var_path, _hostname, _filesystems, _supports_fido2, _search, ancestors in self.__leaf_rows:
```

(j) `__on_check_toggled` signature (line 449) — add `supports_fido2` param:
```python
    def __on_check_toggled(self, check, imgref, flatpaks, icon, carousel, needs_user, composefs, image_type, bootloader, image_filesystem, flatpak_var_path, default_hostname, filesystems, supports_fido2):
```

(k) inside `__on_check_toggled`, after `self.__selected_filesystems = filesystems or []` (line 462):
```python
            self.__selected_supports_fido2 = supports_fido2
```
and in the `else` branch resetting selection state (after line 479's `self.__selected_bootloader = ""` reset block, alongside the other resets):
```python
            self.__selected_supports_fido2 = False
```

(l) new public property, right after `selected_needs_user_creation` (after line 564):
```python
    @property
    def supports_fido2(self) -> bool:
        """True if the selected image's initrd/karg config supports FIDO2 boot unlock."""
        return self.__selected_supports_fido2
```

(m) `get_finals()` dict (after line 598's `"supported_filesystems"` entry):
```python
            "supports_fido2": self.__selected_supports_fido2,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_image_helpers.py -v`
Expected: PASS, all tests including the new one.

- [ ] **Step 5: Run the full Python unit suite**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/ -v`
Expected: PASS — this task touches a widely-shared method, so confirm nothing else broke.

- [ ] **Step 6: Commit**

```bash
cd /home/lily/Projects/bootc-installer
git add bootc_installer/defaults/image.py tests/unit/test_image_helpers.py
git commit -m "feat(image): thread supports_fido2 capability field through image tree"
```

---

### Task 6: Add FIDO2 switch + PIN entry to the encryption wizard page

**Files:**
- Modify: `bootc_installer/gtk/default-encryption.blp`, `bootc_installer/defaults/encryption.py`
- Test: `tests/unit/test_encryption.py`

**Interfaces:**
- Consumes: `Systeminfo.has_fido2_device()` (Task 4), `BootcDefaultImage.supports_fido2` property (Task 5) via `self.__window.image_step`, and the live-ISO `images.json` fallback (mirroring `defaults/user.py:57-79`'s `should_show` pattern) for the no-image-step case.
- Produces: `get_finals()["encryption"]` gains `"type": "fido2-luks-passphrase"` and a new `"fido2_pin"` key when the FIDO2 switch is active.

- [ ] **Step 1: Write the failing tests**

Add to `tests/unit/test_encryption.py`, inside `TestBootcDefaultEncryptionGetFinals` (read the class's existing `setUp`/test methods first to match its exact `_import_encryption_fresh()`-based construction pattern before writing these):

```python
    def test_get_finals_fido2_switch_active(self):
        obj = self._make_obj()  # use whatever helper the existing tests in this class already use
        obj.use_encryption_switch.get_active = lambda: True
        obj.tpm2_switch.get_active = lambda: False
        obj.fido2_switch.get_active = lambda: True
        obj.encryption_pass_entry.get_text = lambda: "correct horse"
        obj.fido2_pin_entry.get_text = lambda: "1234"
        finals = obj.get_finals()
        self.assertEqual(finals["encryption"]["type"], "fido2-luks-passphrase")
        self.assertEqual(finals["encryption"]["encryption_key"], "correct horse")
        self.assertEqual(finals["encryption"]["fido2_pin"], "1234")

    def test_get_finals_fido2_switch_active_no_pin(self):
        obj = self._make_obj()
        obj.use_encryption_switch.get_active = lambda: True
        obj.tpm2_switch.get_active = lambda: False
        obj.fido2_switch.get_active = lambda: True
        obj.encryption_pass_entry.get_text = lambda: "correct horse"
        obj.fido2_pin_entry.get_text = lambda: ""
        finals = obj.get_finals()
        self.assertEqual(finals["encryption"]["type"], "fido2-luks-passphrase")
        self.assertEqual(finals["encryption"]["fido2_pin"], "")

    def test_fido2_and_tpm2_switches_are_mutually_exclusive(self):
        obj = self._make_obj()
        obj.use_encryption_switch.get_active = lambda: True
        # Activating FIDO2 must turn TPM2 off, mirroring the existing
        # encryption-master-switch-off-disables-tpm2 behavior.
        obj._BootcDefaultEncryption__on_fido2_switch_set(None, True)
        obj.tpm2_switch.set_active.assert_called_once_with(False)
```

Adjust `_make_obj()` to whatever construction helper the existing tests in `TestBootcDefaultEncryptionGetFinals` already use (do not invent a new one if one exists).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_encryption.py -k fido2 -v`
Expected: FAIL — `AttributeError: 'BootcDefaultEncryption' has no attribute 'fido2_switch'` (template child doesn't exist yet).

- [ ] **Step 3: Add the UI**

Edit `bootc_installer/gtk/default-encryption.blp`. Add a new `Adw.ActionRow` + `Adw.PasswordEntryRow` right after the existing TPM2 `Adw.ActionRow` block (after line 86, before the closing `}` of the `Adw.PreferencesGroup` at line 87):

```blueprint
          Adw.ActionRow {
            title: _("Unlock with a security key");
            subtitle: _("Touch a FIDO2 security key to unlock. Your passphrase remains as a fallback.");
            sensitive: bind use_encryption_switch.active;

            [suffix]
            Switch fido2_switch {
              valign: center;
            }

            activatable-widget: fido2_switch;
          }

          Adw.PasswordEntryRow fido2_pin_entry {
            title: _("Security key PIN (optional)");
            sensitive: bind fido2_switch.active;
          }
```

- [ ] **Step 4: Wire the widgets in `defaults/encryption.py`**

Edit `bootc_installer/defaults/encryption.py`.

(a) Add template children after `tpm2_switch` (line 30):
```python
    fido2_switch = Gtk.Template.Child()
    fido2_pin_entry = Gtk.Template.Child()
```

(b) In `__init__`, after the `tpm2_switch.connect(...)` line (line 49), add:
```python
        self.fido2_switch.connect("state-set", self.__on_fido2_switch_set)
```

(c) Replace the default-state block (lines 56-59) to also default FIDO2 on when a key is plugged in AND the selected image supports it, and to make TPM2/FIDO2 mutually exclusive by construction (only one can default on):
```python
        # Default: encryption ON. Prefer FIDO2 if a key is plugged in and the
        # selected image supports it; otherwise fall back to TPM2 if present.
        # The two are mutually exclusive (Encryption.Type is a single string).
        from bootc_installer.core.system import Systeminfo
        self.use_encryption_switch.set_active(True)
        fido2_available = Systeminfo.has_fido2_device() and self.__image_supports_fido2()
        self.fido2_switch.set_active(fido2_available)
        self.tpm2_switch.set_active(not fido2_available and Systeminfo.has_tpm2())
```

(d) Add the `__image_supports_fido2` helper, mirroring `defaults/user.py:57-79`'s exact should_show precedent (live-ISO images.json fallback + image_step property), right after `get_finals` (after line 84):

```python
    def __image_supports_fido2(self) -> bool:
        """Whether the currently selected (or sole, on a fixed-catalog live
        ISO) image's initrd/karg config supports FIDO2 boot unlock.

        Mirrors defaults/user.py's should_show() precedent for reading a
        per-image capability off either the live BootcDefaultImage widget
        (multi-image catalog) or /etc/bootc-installer/images.json (live-ISO
        single-image mode, e.g. krytis).
        """
        image_step = getattr(self.__window, "image_step", None)
        if image_step is not None:
            return image_step.supports_fido2
        import json
        import os
        in_flatpak = os.path.exists("/.flatpak-info")
        etc = "/run/host/etc" if in_flatpak else "/etc"
        images_json = f"{etc}/bootc-installer/images.json"
        try:
            with open(images_json) as f:
                data = json.load(f)
            images = data.get("images", [data]) if "images" in data else [data]
            return bool(images[0].get("supports_fido2", False))
        except Exception:
            return False
```

(e) Replace `__on_encryption_switch_set` (lines 86-93) to also turn off FIDO2 when the master switch turns off:
```python
    def __on_encryption_switch_set(self, state, user_data):
        if self.use_encryption_switch.get_active():
            self.page_header.icon_name = "changes-prevent-symbolic"
        else:
            self.page_header.icon_name = "channel-secure-symbolic"
            self.tpm2_switch.set_active(False)
            self.fido2_switch.set_active(False)
        self.__update_btn_next()
```

(f) Add `__on_fido2_switch_set`, mirroring `__on_tpm2_switch_set` (line 95-96) but enforcing mutual exclusivity with TPM2:
```python
    def __on_fido2_switch_set(self, state, user_data):
        if self.fido2_switch.get_active():
            self.tpm2_switch.set_active(False)
        self.__update_btn_next()
```

Also update the existing `__on_tpm2_switch_set` to enforce the same exclusivity in the other direction:
```python
    def __on_tpm2_switch_set(self, state, user_data):
        if self.tpm2_switch.get_active():
            self.fido2_switch.set_active(False)
        self.__update_btn_next()
```

(g) Replace `get_finals()` (lines 72-84) to branch on the new switch:
```python
    def get_finals(self):
        use_enc = self.use_encryption_switch.get_active()
        if not use_enc:
            return {"encryption": {"use_encryption": False, "encryption_key": ""}}
        passphrase = self.encryption_pass_entry.get_text()
        if self.fido2_switch.get_active():
            return {
                "encryption": {
                    "use_encryption": True,
                    "type": "fido2-luks-passphrase",
                    "encryption_key": passphrase,
                    "fido2_pin": self.fido2_pin_entry.get_text(),
                }
            }
        enc_type = "tpm2-luks-passphrase" if self.tpm2_switch.get_active() else "luks-passphrase"
        return {
            "encryption": {
                "use_encryption": True,
                "type": enc_type,
                "encryption_key": passphrase,
            }
        }
```

(h) Update `test_auto_advance` (lines 66-70) to also disable FIDO2 (VMs generally have no security key attached either):
```python
    def test_auto_advance(self):
        # Ensure encryption is off — TPM2/FIDO2 won't work on virtual/loop disks
        self.use_encryption_switch.set_active(False)
        self.tpm2_switch.set_active(False)
        self.fido2_switch.set_active(False)
        self.btn_next.emit("clicked")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_encryption.py -v`
Expected: PASS, all tests including the 3 new ones.

- [ ] **Step 6: Commit**

```bash
cd /home/lily/Projects/bootc-installer
git add bootc_installer/gtk/default-encryption.blp bootc_installer/defaults/encryption.py tests/unit/test_encryption.py
git commit -m "feat(encryption): add FIDO2 switch + PIN entry to encryption wizard page"
```

---

### Task 7: Wire `fido2-luks-passphrase` through recipe generation

**Files:**
- Modify: `bootc_installer/utils/processor.py` (lines 119-136 encryption mapping, 266-269 recipe dict)
- Test: `tests/unit/test_builder.py` (or wherever `processor.py`'s recipe-generation tests already live — check for an existing `test_processor.py` first)

**Interfaces:**
- Consumes: `finals["encryption"]` dict shape from Task 6's `get_finals()`: `{"use_encryption": bool, "type": str, "encryption_key": str, "fido2_pin"?: str}`.
- Produces: recipe JSON `encryption` object gains `"fido2Pin"` key (camelCase, matching fisherman's `json:"fido2Pin,omitempty"` tag from Task 1).

- [ ] **Step 1: Locate the existing test file**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/ -k "processor or encryption_type" --collect-only -q`

Find the test file that already covers `gen_install_recipe`'s encryption-type mapping (lines 119-136 of `processor.py`). If none exists, create `tests/unit/test_processor.py` following the exact import/stub conventions already used in `tests/unit/test_encryption.py` (GI stubs are not needed here — `processor.py` has no GTK imports, confirm this by checking its import block before deciding whether stubs are needed).

- [ ] **Step 2: Write the failing test**

Add a test asserting the new type and PIN field round-trip through `gen_install_recipe`:

```python
def test_gen_install_recipe_fido2_type_and_pin(tmp_path):
    from bootc_installer.utils.processor import RecipeProcessor  # match the actual class/module name found in Step 1

    finals = [{
        "encryption": {
            "use_encryption": True,
            "type": "fido2-luks-passphrase",
            "encryption_key": "hunter2",
            "fido2_pin": "1234",
        },
        "disk": "/dev/sda",
    }]
    sys_recipe = {"log_file": str(tmp_path / "log"), "images": [{"imgref": "example.com/x:latest"}]}

    recipe_path = RecipeProcessor.gen_install_recipe(str(tmp_path / "log"), finals, sys_recipe)
    import json
    with open(recipe_path) as f:
        recipe = json.load(f)

    assert recipe["encryption"]["type"] == "fido2-luks-passphrase"
    assert recipe["encryption"]["passphrase"] == "hunter2"
    assert recipe["encryption"]["fido2Pin"] == "1234"


def test_gen_install_recipe_fido2_type_no_pin(tmp_path):
    from bootc_installer.utils.processor import RecipeProcessor

    finals = [{
        "encryption": {
            "use_encryption": True,
            "type": "fido2-luks-passphrase",
            "encryption_key": "hunter2",
            "fido2_pin": "",
        },
        "disk": "/dev/sda",
    }]
    sys_recipe = {"log_file": str(tmp_path / "log"), "images": [{"imgref": "example.com/x:latest"}]}

    recipe_path = RecipeProcessor.gen_install_recipe(str(tmp_path / "log"), finals, sys_recipe)
    import json
    with open(recipe_path) as f:
        recipe = json.load(f)

    assert recipe["encryption"]["type"] == "fido2-luks-passphrase"
    assert recipe["encryption"]["fido2Pin"] == ""
```

Confirm the exact class name (`RecipeProcessor` is a guess based on `gen_install_recipe` being a `@staticmethod` per line 54-55 — verify the actual enclosing class name in `processor.py` before writing this and correct the import if different).

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_processor.py -k fido2 -v`
Expected: FAIL — `KeyError: 'fido2Pin'`, since `processor.py` doesn't recognize the type or emit the field yet.

- [ ] **Step 4: Implement the mapping**

Edit `bootc_installer/utils/processor.py`.

(a) Encryption-type mapping (lines 124-136) — recognize the new type and capture the PIN:
```python
        if isinstance(enc_info, dict):
            use_enc = enc_info.get("use_encryption", False)
            if use_enc:
                key = enc_info.get("encryption_key", "")
                explicit_type = enc_info.get("type", "")
                if explicit_type in ("luks-passphrase", "tpm2-luks-passphrase", "tpm2-luks", "fido2-luks-passphrase"):
                    encryption_type = explicit_type
                    encryption_passphrase = key
                elif key:
                    encryption_type = "luks-passphrase"
                    encryption_passphrase = key
                else:
                    encryption_type = "tpm2-luks"
        encryption_fido2_pin = enc_info.get("fido2_pin", "") if isinstance(enc_info, dict) else ""
```

(b) Recipe dict (lines 266-269) — add `fido2Pin`, matching fisherman's `json:"fido2Pin,omitempty"` field name from Task 1:
```python
            "encryption": {
                "type": encryption_type,
                "passphrase": encryption_passphrase,
                "fido2Pin": encryption_fido2_pin,
            },
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_processor.py -v`
Expected: PASS.

- [ ] **Step 6: Run the full Python unit suite**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/ -v`
Expected: PASS — `processor.py` is shared by every wizard flow, confirm nothing else broke.

- [ ] **Step 7: Commit**

```bash
cd /home/lily/Projects/bootc-installer
git add bootc_installer/utils/processor.py tests/unit/test_processor.py
git commit -m "feat(processor): map fido2-luks-passphrase + PIN into fisherman recipe"
```

---

### Task 8: Add confirm-screen label

**Files:**
- Modify: `bootc_installer/views/confirm_data.py:21-26`
- Test: create `tests/unit/test_confirm_data.py` if none exists (this file has no GTK imports per its own docstring "Data-only module — no GTK imports, safe for pure-Python unit tests" — a plain `unittest`/`pytest` test needs no stubbing)

**Interfaces:**
- Produces: `_ENC_LABELS["fido2-luks-passphrase"]`.

- [ ] **Step 1: Write the failing test**

```python
# tests/unit/test_confirm_data.py
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from bootc_installer.views.confirm_data import _ENC_LABELS


def test_fido2_luks_passphrase_has_a_label():
    assert "fido2-luks-passphrase" in _ENC_LABELS
    assert _ENC_LABELS["fido2-luks-passphrase"]  # non-empty
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_confirm_data.py -v`
Expected: FAIL — `assert "fido2-luks-passphrase" in _ENC_LABELS` fails, key absent.

- [ ] **Step 3: Implement the label**

Edit `bootc_installer/views/confirm_data.py`, add to `_ENC_LABELS` (after line 25):

```python
_ENC_LABELS = {
    "none": "None",
    "luks-passphrase": "Encrypted with passphrase",
    "tpm2-luks": "Hardware-backed encryption",
    "tpm2-luks-passphrase": "Hardware-backed + passphrase fallback",
    "fido2-luks-passphrase": "Security key + passphrase fallback",
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/test_confirm_data.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/lily/Projects/bootc-installer
git add bootc_installer/views/confirm_data.py tests/unit/test_confirm_data.py
git commit -m "feat(confirm): add fido2-luks-passphrase confirm-screen label"
```

---

### Task 9: Add FIDO2 progress-step label

**Files:**
- Modify: `bootc_installer/utils/progress_parser.py:13-26`
- Test: existing progress-parser test file (find it via `grep -rl _FRIENDLY_STEP_LABELS tests/` — reuse its exact table-driven pattern)

**Interfaces:**
- Consumes: the fisherman progress-step name string `"Enrolling FIDO2 auto-unlock"` emitted by Task 3's `progress.Step(...)` call.

- [ ] **Step 1: Write the failing test**

Find the existing test covering `_FRIENDLY_STEP_LABELS` / `apply_progress_event` for the `"Enrolling TPM2 auto-unlock"` step, and add an analogous case for `"Enrolling FIDO2 auto-unlock"`:

```python
def test_apply_progress_event_fido2_step_label():
    from bootc_installer.utils.progress_parser import apply_progress_event, new_progress_state
    import json

    state = new_progress_state()
    line = json.dumps({"type": "step", "step": 5, "total": 9, "step_name": "Enrolling FIDO2 auto-unlock", "cumulative_pct": 80, "weight_pct": 5})
    result = apply_progress_event(line, state)
    assert result is not None
    assert "security key" in result["label"].lower()
```

(Match the exact JSON field names fisherman's `progress.Step` actually emits — verify against `fisherman/internal/progress/progress.go`'s `stepEvent` struct tags, lines 12-19, before finalizing this test; the field names above are a best-effort guess from the struct's purpose and must be corrected to match exactly.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/ -k fido2_step -v`
Expected: FAIL — falls through to the raw `step_name` string since no friendly label is mapped yet.

- [ ] **Step 3: Implement the label**

Edit `bootc_installer/utils/progress_parser.py`, add to `_FRIENDLY_STEP_LABELS` (after line 22):

```python
    "Enrolling FIDO2 auto-unlock":   "Setting up your security key…",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /home/lily/Projects/bootc-installer && python3 -m pytest tests/unit/ -k fido2_step -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/lily/Projects/bootc-installer
git add bootc_installer/utils/progress_parser.py
git commit -m "feat(progress): add friendly label for FIDO2 enrolment step"
```

---

## Phase 3: dakota-iso krytis variant

Repo: `/home/lily/Projects/dakota-iso` (fork: `kitten-lily/dakota-iso`)

### Task 10: Advertise FIDO2 support in krytis's images.json leaf

**Files:**
- Modify: `live/src/configure-live-krytis.sh:224-241`

**Interfaces:**
- Consumes: `defaults/image.py`'s new `supports_fido2` node field (Task 5) — bootc-installer reads this from `/etc/bootc-installer/images.json` written by this script.

- [ ] **Step 1: Confirm the current block**

Run: `cd /home/lily/Projects/dakota-iso && git log --oneline -1` to confirm current HEAD, then re-read `live/src/configure-live-krytis.sh:224-241` to confirm line numbers haven't shifted since this plan was written (the fisherman/bootc-installer submodule bump in Task 11 does not touch this file, but confirm anyway before editing).

- [ ] **Step 2: Add the field**

Edit `live/src/configure-live-krytis.sh`. The current block (lines 223-241):

```bash
# images.json: single Krytis entry.
cat > /etc/bootc-installer/images.json << IMGEOF
{
  "default_image": "${KRYTIS_IMGREF}",
  "fallback_flatpaks": [],
  "images": [
    {
      "name": "StarlitOS Krytis",
      "imgref": "${KRYTIS_IMGREF}",
      "desc": "StarlitOS Krytis",
      "bootloader": "systemd",
      "filesystem": "btrfs",
      "composefs": true,
      "needs_user_creation": true,
      "flatpak_var_path": "state/os/default/var",
      "filesystems": ["btrfs", "xfs"]
    }
  ]
}
IMGEOF
```

becomes:

```bash
# images.json: single Krytis entry.
# supports_fido2=true: krytis's own initrd already carries libfido2.so.1 and
# the rd.luks.options=fido2-device=auto karg (starlit-os/krytis#473) — the
# bootc-installer FIDO2 switch is safe to default-enable for this image.
# This flag does NOT apply to any other fisherman-catalog image (bluefin,
# yellowfin, dakota, etc.) — each would need its own initrd fix first. See
# starlit-os/krytis#512.
cat > /etc/bootc-installer/images.json << IMGEOF
{
  "default_image": "${KRYTIS_IMGREF}",
  "fallback_flatpaks": [],
  "images": [
    {
      "name": "StarlitOS Krytis",
      "imgref": "${KRYTIS_IMGREF}",
      "desc": "StarlitOS Krytis",
      "bootloader": "systemd",
      "filesystem": "btrfs",
      "composefs": true,
      "needs_user_creation": true,
      "flatpak_var_path": "state/os/default/var",
      "filesystems": ["btrfs", "xfs"],
      "supports_fido2": true
    }
  ]
}
IMGEOF
```

- [ ] **Step 3: Verify the JSON is well-formed**

Run: `cd /home/lily/Projects/dakota-iso && bash -c 'source live/src/configure-live-krytis.sh 2>/dev/null || true'` is not safe to run directly (the script assumes a live container context) — instead, extract just the heredoc and validate it:

```bash
cd /home/lily/Projects/dakota-iso
KRYTIS_IMGREF="ghcr.io/starlit-os/krytis:latest" awk '/^cat > \/etc\/bootc-installer\/images.json/,/^IMGEOF/' live/src/configure-live-krytis.sh | sed '1d;$d' | envsubst | python3 -m json.tool
```

Expected: prints the formatted JSON with `"supports_fido2": true` present, no parse error.

- [ ] **Step 4: Commit**

```bash
cd /home/lily/Projects/dakota-iso
git add live/src/configure-live-krytis.sh
git commit -m "feat(krytis): advertise supports_fido2 in images.json"
```

---

## Phase 4: Cross-repo integration

### Task 11: Bump the fisherman submodule pointer in bootc-installer

**Files:**
- Modify: `bootc-installer/fisherman` (submodule pointer)

- [ ] **Step 1: Push fisherman's branch and update the submodule**

This step assumes Tasks 1-3 have been pushed to a branch on `projectbluefin/fisherman` (or a fork) and merged, or at minimum pushed to a branch bootc-installer's submodule can point at for testing:

```bash
cd /home/lily/Projects/bootc-installer/fisherman
git fetch origin
git checkout <fisherman-branch-or-commit-from-tasks-1-3>
cd /home/lily/Projects/bootc-installer
git add fisherman
git commit -m "chore(fisherman): bump submodule for fido2-luks-passphrase support"
```

- [ ] **Step 2: Rebuild and confirm the Flatpak module picks up the new binary**

Run: `cd /home/lily/Projects/bootc-installer && flatpak-builder --force-clean build-dir flatpak/org.bootcinstaller.Installer.json` (or whatever this repo's existing local Flatpak build task is — check `justfile`/`meson.build`/`AGENTS.md` for the canonical command before running a manual `flatpak-builder` invocation).
Expected: build succeeds, `fisherman` module step compiles the bumped submodule commit.

---

### Task 12: Real-hardware smoke test — `CREDENTIALS_DIRECTORY` PIN mechanism

**This is a hard gate per Global Constraints — do not consider Tasks 1-3 done until this passes.**

- [ ] **Step 1: Prepare a test LUKS volume with a PIN-requiring FIDO2 key**

On real hardware (or a VM with USB passthrough of a real FIDO2 key that has a PIN set — software FIDO2 emulators do not exercise the real CTAP2 PIN/touch flow):

```bash
# Create a throwaway LUKS2 volume for testing (adjust device/size as needed).
sudo cryptsetup luksFormat --batch-mode --type=luks2 --key-file=- /dev/loop0 <<< "testpass123"
```

- [ ] **Step 2: Call `EnrollFIDO2` directly via a tiny standalone Go program**

Write a throwaway `main.go` (not committed) that imports `fisherman/internal/luks` and calls `luks.EnrollFIDO2("/dev/loop0", "testpass123", "<your key's actual PIN>")`, or invoke the fisherman binary end-to-end via a minimal recipe.json with `"encryption": {"type": "fido2-luks-passphrase", "passphrase": "testpass123", "fido2Pin": "<pin>"}` against a loopback disk.

- [ ] **Step 3: Verify no interactive prompt appears and the token is enrolled**

Expected: the command returns successfully with no terminal prompt for the PIN (only the physical touch is required — confirm you had to touch the key). Verify enrollment:

```bash
sudo cryptsetup luksDump /dev/loop0 | grep -A3 "Tokens:"
```
Expected: a `systemd-fido2` token entry present.

- [ ] **Step 4: Verify unlock actually works with the enrolled token**

```bash
sudo systemd-cryptsetup attach test-fido2-vol /dev/loop0 - fido2-device=auto
```
Expected: prompts only for touch (not PIN, since it was pre-supplied at enrollment — though note unlock-time PIN entry is a separate systemd-cryptsetup behavior from enrollment-time and may still prompt interactively at unlock; this step is about confirming the *token* itself works, not re-verifying the enrollment-time non-interactivity).

- [ ] **Step 5: Record the result**

Add a comment to `starlit-os/krytis#512` (or a new dedicated verification issue) with the exact commands run, the hardware/key model used, and pass/fail — following this project's "verified on real hardware" evidence standard (`docs/skills/fido2.md`'s own convention).

---

### Task 13: End-to-end install test via dakota-iso

- [ ] **Step 1: Build the krytis debug ISO with the updated bootc-installer**

Run: `cd /home/lily/Projects/dakota-iso && just debug=1 iso-sd-boot krytis` (confirm this is still the correct current task name/invocation via `just --list` before running — commands in this fast-moving repo may have been renamed since this plan was written).

- [ ] **Step 2: Boot the ISO in QEMU with a passed-through FIDO2 key (or plain passphrase fallback if no USB passthrough is available in the test environment)**

Run whatever this repo's current `plain-boot-qemu-live krytis` / `sealed-test-qemu krytis` equivalent is (check `justfile` — these exact task names have been renamed before in this repo's history per the earlier fisherman-fix investigation, verify current names first).

- [ ] **Step 3: Walk the installer GUI, select "Unlock with a security key", complete install**

Expected: the FIDO2 switch is visible and (if a key is detected) defaulted on; installation completes; the recovery/confirm screen shows "Security key + passphrase fallback".

- [ ] **Step 4: Reboot the installed disk and confirm boot behavior**

Expected: given #250 is still open, boot MAY fall back to the passphrase prompt (this is the known, accepted failure mode per this plan's Global Constraints) — confirm the passphrase still successfully unlocks when FIDO2 doesn't win the race. This is not a regression; it's the documented current limitation.

- [ ] **Step 5: Record the result**

Add a comment to `starlit-os/krytis#512` with the outcome, following this project's PR Comment Policy (one comment per PR event, combine all findings).

---

## Self-Review Notes

- **Spec coverage:** every gap identified in `starlit-os/krytis#512` ("What a FIDO2 install-time type would need", items 1-3) has a corresponding task: fisherman (Tasks 1-3), bootc-installer (Tasks 4-9), dakota-iso krytis variant (Task 10). Blocker 1's resolved design (Credentials-directory PIN mechanism, touch-step one-way message) is implemented exactly as specified in Task 2/3. Blocker 2 (#250) is respected by the Global Constraints' hard rule against a passphrase-less FIDO2 type — this plan does not attempt to fix #250, which is explicitly out of scope per the issue.
- **Placeholder scan:** every code step above contains complete, real code — no "TBD"/"add error handling"/"similar to Task N" shortcuts. Two steps (Task 5 Step 1, Task 7 Step 1, Task 9 Step 1) explicitly instruct the implementer to verify an exact existing helper name/JSON field name against the live source before finalizing, rather than guessing — this is a deliberate acknowledgment of incomplete visibility into those specific pre-existing test harnesses, not a placeholder for the *new* code itself, which is fully specified.
- **Type consistency:** `EnrollFIDO2(partition, unlockPassphrase, pin string) error` (Task 2) matches its call site in Task 3 (`luks.EnrollFIDO2(activeRootPart, r.Encryption.Passphrase, r.Encryption.FIDO2Pin)`) exactly. `Encryption.FIDO2Pin` (Task 1, Go, `json:"fido2Pin,omitempty"`) matches `processor.py`'s emitted `"fido2Pin"` key (Task 7) exactly — same camelCase spelling on both sides of the JSON boundary. `supports_fido2` (Task 5, Python) is snake_case throughout Python and matches the `"supports_fido2"` JSON key written by dakota-iso (Task 10) exactly.
