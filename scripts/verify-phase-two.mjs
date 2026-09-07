// All SQL assertions run in one transaction and deliberately roll back on success.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
const { data: branches } = JSON.parse(execFileSync('npx', ['-y', '@insforge/cli', 'branch', 'list', '--json'], { encoding: 'utf8' }))
const branch = branches.find((entry) => entry.id === project.project_id)
assert(branch?.name === 'phase-2-kennel' && branch.branch_state === 'ready', 'Use the ready phase-2-kennel backend branch')
assert(branch.parent_project_id && branch.parent_project_id !== branch.id && branch.appkey !== 'bk8ptwjs', 'Refusing production')
assert.equal(project.oss_host, `https://${branch.appkey}.${branch.region}.insforge.app`)
const result = spawnSync('npx', ['-y', '@insforge/cli', 'db', 'query', readFileSync('tests/backend/phase-two.sql', 'utf8'), '--json'], {
  encoding: 'utf8', maxBuffer: 2 * 1024 * 1024,
})
const output = `${result.stdout}\n${result.stderr}`
assert(result.status !== 0 && output.includes('PHASE_TWO_ASSERTIONS_PASSED_ROLLED_BACK'),
  `Backend assertions failed: ${output}`)
console.log('Phase 2 backend transaction assertions passed; all test data rolled back.')
