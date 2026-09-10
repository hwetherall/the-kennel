// Seed only the isolated Phase 2 backend, then switch local frontend configuration.
// Run after `insforge branch create phase-2-kennel --mode schema-only`.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const cli = (...args) => execFileSync('npx', ['-y', '@insforge/cli', ...args], { encoding: 'utf8' })
const project = JSON.parse(readFileSync('.insforge/project.json', 'utf8'))
const { data: branches } = JSON.parse(cli('branch', 'list', '--json'))
const branch = branches.find((entry) => entry.id === project.project_id)
assert(branch?.name === 'phase-2-kennel', 'Switch to phase-2-kennel before running setup')
assert(branch.branch_state === 'ready', 'Phase 2 backend must be ready')
assert(branch.branch_metadata.mode === 'schema-only', 'Expected a schema-only branch')
assert(branch.parent_project_id && branch.parent_project_id !== branch.id, 'Refusing a production parent')
const branchUrl = `https://${branch.appkey}.${branch.region}.insforge.app`
assert.equal(project.oss_host, branchUrl, 'Linked backend URL does not match the branch')
assert.notEqual(branch.appkey, 'bk8ptwjs', 'Refusing production')

cli('db', 'query', `DO $$
BEGIN
  INSERT INTO public.event_config (
    id, event_name, event_code, venue, starts_at, timezone, home_team, away_team, zeffy_url
  ) VALUES (
    1, 'Phase 2 rehearsal', 'DOGS26', 'Development backend',
    '2026-09-26T04:30:00Z', 'America/Denver', 'Home', 'Away', NULL
  ) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.grid_config (id, row_digits, col_digits)
  VALUES (1, ARRAY[0,1,2,3,4,5,6,7,8,9], ARRAY[0,1,2,3,4,5,6,7,8,9])
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.game_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.squares (id, row_index, col_index)
  SELECT value, (value - 1) / 10, (value - 1) % 10 FROM generate_series(1, 100) AS value
  ON CONFLICT (id) DO NOTHING;
END
$$`, '--json')

const functionUrl = `https://${branch.appkey}.function2.insforge.app/kennel-api`
const response = await fetch(functionUrl, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ action: 'public_snapshot' }),
  signal: AbortSignal.timeout(30_000),
})
assert(response.ok, `Deploy kennel-api on the branch first (HTTP ${response.status})`)
const { data: snapshot } = await response.json()
assert.equal(snapshot?.squares?.length, 100, 'Branch API must return the complete Squares board')
assert(snapshot.serverNow && snapshot.event && snapshot.grid && snapshot.game, 'Incomplete branch snapshot')

const original = existsSync('.env.local') ? readFileSync('.env.local', 'utf8') : ''
if (!existsSync('.env.phase-one.local')) writeFileSync('.env.phase-one.local', original, { mode: 0o600 })
const replacements = {
  VITE_INSFORGE_URL: branchUrl,
  VITE_INSFORGE_ANON_KEY: '',
  VITE_DEMO_MODE: 'false',
  INSFORGE_URL: branchUrl,
  INSFORGE_API_KEY: project.api_key,
  KENNEL_FUNCTION_URL: functionUrl,
}
let updated = original
for (const [key, value] of Object.entries(replacements)) {
  const line = `${key}=${value}`
  const pattern = new RegExp(`^${key}=.*$`, 'm')
  updated = pattern.test(updated) ? updated.replace(pattern, () => line) : `${updated.trimEnd()}\n${line}\n`
}
writeFileSync('.env.local', updated, { mode: 0o600 })
console.log(JSON.stringify({ branch: branch.name, functionUrl, publicSquares: snapshot.squares.length,
  localEnvironment: 'configured; restart any existing dev server' }, null, 2))
