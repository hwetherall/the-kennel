// All SQL assertions run in one transaction and deliberately roll back on success.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
const recovery = process.argv.includes('--undo-recovery')
assert(process.argv.slice(2).every((arg) => arg === '--undo-recovery'), 'Unknown verification argument')
const { data: branches } = JSON.parse(execFileSync('npx', ['-y', '@insforge/cli', 'branch', 'list', '--json'], { encoding: 'utf8' }))
const branch = branches.find((entry) => entry.id === project.project_id)
assert(branch?.branch_state === 'ready', 'Switch to a ready development backend branch')
assert(branch.parent_project_id && branch.parent_project_id !== branch.id && branch.appkey !== 'bk8ptwjs', 'Refusing production')
assert.equal(project.oss_host, `https://${branch.appkey}.${branch.region}.insforge.app`)
const sqlFile = recovery ? 'tests/backend/phase-two-undo-recovery.sql' : 'tests/backend/phase-two.sql'
const result = spawnSync('npx', ['-y', '@insforge/cli', 'db', 'query', '--json', '--', readFileSync(sqlFile, 'utf8')], {
  encoding: 'utf8', maxBuffer: 2 * 1024 * 1024,
})
// The CLI may echo SQL in diagnostic context; finding our marker anywhere in
// that context would falsely pass a failing test. Inspect only the error field.
let errorMessage
for (const output of [result.stderr, result.stdout]) {
  try { errorMessage ??= JSON.parse(output).error } catch { /* not JSON output */ }
}
assert(result.status !== 0 && errorMessage === 'PHASE_TWO_ASSERTIONS_PASSED_ROLLED_BACK',
  `Backend assertions failed: ${JSON.stringify(errorMessage ?? { stdout: result.stdout, stderr: result.stderr })}`)
console.log(`Phase 2 ${recovery ? 'undo recovery' : 'backend transaction'} assertions passed; all test data rolled back.`)
