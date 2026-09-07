// Invoked by the guarded rehearsal with synthetic sessions; never creates untracked fixtures.
import { chromium, expect } from '@playwright/test'
export async function verifyPreview({ appUrl, guest, opponent, hostSession }) {
  const browser = await chromium.launch({ headless: true })
  const errors = []
  try {
    const context = await browser.newContext({ viewport: { width: 360, height: 800 } })
    context.on('page', (page) => page.on('pageerror', (e) => errors.push(e.message)))
    const page = await context.newPage()
    await page.addInitScript((session) => localStorage.setItem('kennel.player-session.v1', JSON.stringify(session)), guest)
    await page.goto(appUrl)
    await expect(page.getByRole('heading', { name: 'Grand Final Squares' })).toBeVisible()
    await page.getByRole('button', { name: 'The Kennel', exact: true }).click()
    await page.getByRole('button', { name: 'Home', exact: true }).click()
    await page.getByRole('button', { name: '+50', exact: true }).click()
    await expect(page.getByText(/Your position: Home · 50 Bones/)).toBeVisible()
    const secondContext = await browser.newContext({ viewport: { width: 390, height: 844 } })
    const second = await secondContext.newPage()
    await second.addInitScript((session) => localStorage.setItem('kennel.player-session.v1', JSON.stringify(session)), opponent)
    await second.goto(appUrl); await second.getByRole('button', { name: 'The Kennel', exact: true }).click()
    await second.getByRole('button', { name: 'Away', exact: true }).click()
    await second.getByRole('button', { name: '+100', exact: true }).click()
    await expect(second.getByText(/Your position: Away · 100 Bones/)).toBeVisible()
    const host = await context.newPage()
    await host.addInitScript((session) => sessionStorage.setItem('kennel.host-session.v1', JSON.stringify(session)), hostSession)
    await host.goto(`${appUrl}/host`)
    await expect(host.getByRole('heading', { name: 'Match control' })).toBeVisible()
    const balance = Number((await page.locator('.bones-card > strong').textContent()).replaceAll(',', ''))
    await host.getByRole('button', { name: 'Home goal', exact: false }).click()
    await expect(page.locator('.bones-card > strong')).toHaveText((balance + 150).toLocaleString(), { timeout: 15000 })
    // Lost HTTP response after commit: browser must retry the original key, even after a reload.
    let originalKey
    let retriedKey
    await page.route('**/kennel-api', async (route) => {
      if (route.request().method() !== 'POST') return route.continue()
      const body = route.request().postDataJSON()
      if (body.action !== 'place_bet') return route.continue()
      if (!originalKey) {
        originalKey = route.request().headers()['idempotency-key']
        await route.fetch() // Commit on the real branch, then lose the response.
        await route.abort('failed')
      } else {
        retriedKey = route.request().headers()['idempotency-key']; await route.continue()
      }
    })
    await page.getByRole('button', { name: 'Home', exact: true }).click()
    await page.getByRole('button', { name: '+25', exact: true }).click()
    await expect(page.getByRole('button', { name: 'Retry original request' })).toBeEnabled()
    await page.reload(); await page.getByRole('button', { name: 'The Kennel', exact: true }).click()
    await page.getByRole('button', { name: 'Retry original request' }).click()
    await expect(page.getByText(/Your position: Home · 25 Bones/)).toBeVisible()
    expect(retriedKey).toBe(originalKey)
    await host.getByRole('button', { name: /Undo last score/ }).click()
    await expect(page.locator('.bones-card > strong')).toHaveText(balance.toLocaleString(), { timeout: 15000 })
    await context.setOffline(true)
    await expect(page.getByRole('button', { name: '+25', exact: true })).toBeDisabled()
    await context.setOffline(false)
    await expect(page.getByRole('button', { name: '+25', exact: true })).toBeEnabled({ timeout: 15000 })
    await page.evaluate(() => window.scrollTo(0, 0))
    await page.screenshot({ path: '/tmp/kennel-phase-two-live-phone.png', fullPage: true })
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await host.setViewportSize({ width: 1440, height: 900 })
    await host.screenshot({ path: '/tmp/kennel-phase-two-live-host.png', fullPage: true })
    await host.getByRole('button', { name: 'Sound Q2 siren' }).click()
    const projector = await context.newPage(); await projector.setViewportSize({ width: 1920, height: 1080 })
    await projector.goto(`${appUrl}/screen`)
    await expect(projector.getByText('Q2 winning square')).toBeVisible()
    await projector.screenshot({ path: '/tmp/kennel-phase-two-live-projector.png', fullPage: true })
    expect(await projector.evaluate(() => document.documentElement.scrollWidth <= innerWidth && document.documentElement.scrollHeight <= innerHeight)).toBe(true)
    await projector.goto(`${appUrl}/host/print`)
    await expect(projector.getByRole('button', { name: 'Print grid' })).toBeVisible()
    expect(errors).toEqual([])
    console.log('Live preview passed: two guests, goal, lost-response original-key retry, undo, offline/reconnect, siren, phone/host/projector/print.')
  } finally { await browser.close() }
}
