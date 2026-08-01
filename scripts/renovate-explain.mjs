// Resolve every packageRule in .github/renovate.json5 to its effective
// enabled/automerge decision, per package and update type.
//
// Why this exists: `renovate --dry-run` prints extraction and lookup results
// but stops before branch materialisation, so it never shows whether a rule
// actually turned automerge off for a given dependency. This calls Renovate's
// own applyPackageRules() — the same function the bot uses — so the answer is
// the bot's, not a reading of the docs.
//
// Run it via `mise run renovate-check --explain`; it expects Renovate's own
// container image (modules under /usr/local/renovate).
//
// Subjects are derived from the config itself: every name in a rule's
// matchPackageNames and every depType in matchDepTypes is probed, so adding a
// rule automatically adds coverage. One synthetic name per enabled manager
// probes the fall-through case (no rule matches it).

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const RENOVATE_HOME = process.env.RENOVATE_HOME ?? '/usr/local/renovate/';
const require = createRequire(RENOVATE_HOME);
const { applyPackageRules } = require(`${RENOVATE_HOME}dist/util/package-rules/index.js`);
const JSON5 = require('json5');
// applyPackageRules() logs through Renovate's logger, which prints a
// "logger has not yet been initialized" notice to stderr when used outside a
// real run. init() takes no arguments — it reads LOG_LEVEL from the env.
process.env.LOG_LEVEL = 'fatal';
await require(`${RENOVATE_HOME}dist/logger/index.js`).init();

const configFile = process.argv[2] ?? '.github/renovate.json5';
const config = JSON5.parse(readFileSync(configFile, 'utf8'));
const managers = config.enabledManagers ?? ['npm'];
const rules = config.packageRules ?? [];
const updateTypes = ['digest', 'pin', 'patch', 'minor', 'major'];

// A package can only be matched by a rule that names its manager (or names
// none), so probing every listed name against every manager it could belong to
// keeps the matrix honest without hardcoding which file a dep came from.
const subjects = [];
const seen = new Set();
const add = (manager, packageName, depType) => {
  const key = `${manager}\0${packageName}\0${depType}`;
  if (seen.has(key)) return;
  seen.add(key);
  subjects.push({ manager, packageName, depType });
};

for (const rule of rules) {
  const ruleManagers = rule.matchManagers ?? managers;
  for (const manager of ruleManagers) {
    for (const packageName of rule.matchPackageNames ?? []) {
      add(manager, packageName, rule.matchDepTypes?.[0] ?? 'project.dependencies');
    }
    for (const depType of rule.matchDepTypes ?? []) {
      add(manager, depType === 'requires-python' ? 'python' : `any-${depType}`, depType);
    }
  }
}
for (const manager of managers) {
  add(manager, '(any other package)', 'project.dependencies');
}

// Group the rows by manager for display; sort is stable, so the order rules
// were declared in survives within each group.
subjects.sort((a, b) => managers.indexOf(a.manager) - managers.indexOf(b.manager));

const verdict = (result) => {
  if (result.enabled === false) return 'off ';
  return result.automerge ? 'AUTO' : 'hold';
};

const width = Math.max(...subjects.map((s) => s.packageName.length));
console.log(`==> ${configFile}: off = no PR, AUTO = auto-merged, hold = PR awaits a human\n`);
let manager = null;
for (const subject of subjects) {
  if (subject.manager !== manager) {
    manager = subject.manager;
    console.log(`  ${manager}`);
  }
  const cells = [];
  for (const updateType of updateTypes) {
    const result = await applyPackageRules({ ...config, ...subject, updateType }, 'lookup');
    cells.push(`${updateType}=${verdict(result)}`);
  }
  console.log(`    ${subject.packageName.padEnd(width)}  ${cells.join('  ')}`);
}
