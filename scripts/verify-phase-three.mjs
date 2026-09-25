// Proves the Phase 3 lock-strategy migration WITHOUT applying it.
//
// The migration DDL and the assertions are sent as one statement batch, which
// Postgres runs in a single implicit transaction, and the suite ends by raising.
// Everything rolls back: no column, no trigger, no test row survives. That keeps
// the dress rehearsal on exactly the code that is live in production.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

// Applied in order: step 2 builds on the lock_strategy column step 1 adds.
const MIGRATIONS = [
  'migrations/20260910221500_phase-3-lock-strategy.sql',
  'migrations/20260916120000_phase-3-athletes-and-futures.sql',
  'migrations/20260916140000_phase-3-futures.sql',
  'migrations/20260924200000_grand-final-studs-and-board.sql',
  'migrations/20260924230000_score-feed.sql',
]
const SUITES = [
  ['tests/backend/phase-three-lock-strategy.sql', 'PHASE_THREE_LOCK_ASSERTIONS_PASSED_ROLLED_BACK'],
  ['tests/backend/phase-three-athletes-futures.sql', 'PHASE_THREE_ATHLETES_ASSERTIONS_PASSED_ROLLED_BACK'],
  ['tests/backend/phase-three-futures.sql', 'PHASE_THREE_FUTURES_ASSERTIONS_PASSED_ROLLED_BACK'],
  ['tests/backend/grand-final-studs.sql', 'GRAND_FINAL_STUDS_ASSERTIONS_PASSED_ROLLED_BACK'],
  ['tests/backend/score-feed.sql', 'SCORE_FEED_ASSERTIONS_PASSED_ROLLED_BACK'],
]

const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
// --applied runs the same suites against a branch that already carries the migrations.
const applied = process.argv.includes('--applied')
// --suite <path> runs one suite only, e.g. when other suites need an idle branch.
const only = process.argv.includes('--suite') ? process.argv[process.argv.indexOf('--suite') + 1] : null
assert(process.argv.slice(2).every((arg) => arg === '--applied' || arg === '--suite' || arg === only), 'Unknown verification argument')
const { data: branches } = JSON.parse(execFileSync('npx', ['-y', '@insforge/cli', 'branch', 'list', '--json'], { encoding: 'utf8' }))
const branch = branches.find((entry) => entry.id === project.project_id)
assert(branch?.branch_state === 'ready', 'Switch to a ready development backend branch')
assert(branch.parent_project_id && branch.parent_project_id !== branch.id && branch.appkey !== 'bk8ptwjs', 'Refusing production')
assert.equal(project.oss_host, `https://${branch.appkey}.${branch.region}.insforge.app`)

// Counts the objects both migrations create. Refuse to run if either has already
// landed: the DDL would fail on the duplicate and that failure would be
// indistinguishable from an assertion failure.
const PRESENCE_QUERY = `SELECT
  (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'markets' AND column_name = 'lock_strategy')
  + (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('athletes', 'studs_matchups')) AS present`

function presentCount() {
  const probe = spawnSync('npx', ['-y', '@insforge/cli', 'db', 'query', '--json', '--', PRESENCE_QUERY], { encoding: 'utf8' })
  return Number(JSON.parse(probe.stdout).rows?.[0]?.present ?? -1)
}

if (applied) assert.equal(presentCount(), 3, 'Apply every Phase 3 migration before running with --applied')
else assert.equal(presentCount(), 0, 'A Phase 3 migration is already applied; run with --applied')

const migration = applied ? '' : MIGRATIONS.map((path) => readFileSync(path, 'utf8')).join('\n')

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

for (const [suite, marker] of SUITES) if (!only || suite === only) runSuite(suite, marker)

// Phase 3 must not disturb Phase 2. Re-run both Phase 2 suites — including the
// five goal-undo recovery scenarios — against the migrated schema, unchanged.
for (const suite of only ? [] : ['tests/backend/phase-two.sql', 'tests/backend/phase-two-undo-recovery.sql']) {
  runSuite(suite, 'PHASE_TWO_ASSERTIONS_PASSED_ROLLED_BACK')
}

// The rollback is the whole point, so prove it rather than trust it.
if (!applied) assert.equal(presentCount(), 0, 'The migrations did not roll back')

console.log(only
  ? `${only} passed; rolled back.`
  : `Phase 3 assertions passed (${SUITES.length} suites), Phase 2 suites still pass on the migrated schema; all rolled back.`)
