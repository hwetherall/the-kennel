// Proves the Phase 3 lock-strategy migration WITHOUT applying it.
//
// The migration DDL and the assertions are sent as one statement batch, which
// Postgres runs in a single implicit transaction, and the suite ends by raising.
// Everything rolls back: no column, no trigger, no test row survives. That keeps
// the dress rehearsal on exactly the code that is live in production.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const MIGRATION = 'migrations/20260910221500_phase-3-lock-strategy.sql'
const ASSERTIONS = 'tests/backend/phase-three-lock-strategy.sql'
const MARKER = 'PHASE_THREE_LOCK_ASSERTIONS_PASSED_ROLLED_BACK'

const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
assert.equal(process.argv.length, 2, 'This verification takes no arguments')
const { data: branches } = JSON.parse(execFileSync('npx', ['-y', '@insforge/cli', 'branch', 'list', '--json'], { encoding: 'utf8' }))
const branch = branches.find((entry) => entry.id === project.project_id)
assert(branch?.branch_state === 'ready', 'Switch to a ready development backend branch')
assert(branch.parent_project_id && branch.parent_project_id !== branch.id && branch.appkey !== 'bk8ptwjs', 'Refusing production')
assert.equal(project.oss_host, `https://${branch.appkey}.${branch.region}.insforge.app`)

// Refuse to run if the migration has already landed: the DDL would fail on the
// duplicate column and the failure would look like an assertion failure.
const applied = spawnSync('npx', ['-y', '@insforge/cli', 'db', 'query', '--json', '--',
  "SELECT count(*) AS present FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'markets' AND column_name = 'lock_strategy'"],
  { encoding: 'utf8' })
const present = Number(JSON.parse(applied.stdout).rows?.[0]?.present ?? 0)
assert.equal(present, 0, 'lock_strategy is already applied; this script only verifies the unapplied migration')

const migration = readFileSync(MIGRATION, 'utf8')

function runSuite(suitePath, expected) {
  const result = spawnSync('npx', ['-y', '@insforge/cli', 'db', 'query', '--json', '--',
    `${migration}\n${readFileSync(suitePath, 'utf8')}`], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 })
  // The CLI may echo SQL in diagnostic context; finding the marker anywhere in
  // that context would falsely pass a failing test. Inspect only the error field.
  let errorMessage
  for (const output of [result.stderr, result.stdout]) {
    try { errorMessage ??= JSON.parse(output).error } catch { /* not JSON output */ }
  }
  assert(result.status !== 0 && errorMessage === expected,
    `${suitePath} failed against the migrated schema: ${JSON.stringify(errorMessage ?? { stdout: result.stdout, stderr: result.stderr })}`)
}

runSuite(ASSERTIONS, MARKER)

// Phase 3 must not disturb Phase 2. Re-run both Phase 2 suites — including the
// five goal-undo recovery scenarios — against the migrated schema, unchanged.
for (const suite of ['tests/backend/phase-two.sql', 'tests/backend/phase-two-undo-recovery.sql']) {
  runSuite(suite, 'PHASE_TWO_ASSERTIONS_PASSED_ROLLED_BACK')
}

// The rollback is the whole point, so prove it rather than trust it.
const after = spawnSync('npx', ['-y', '@insforge/cli', 'db', 'query', '--json', '--',
  "SELECT count(*) AS present FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'markets' AND column_name = 'lock_strategy'"],
  { encoding: 'utf8' })
assert.equal(Number(JSON.parse(after.stdout).rows?.[0]?.present ?? -1), 0, 'The migration did not roll back')

console.log("Phase 3 lock-strategy assertions passed, Phase 2 suites still pass on the migrated schema; all rolled back.")
