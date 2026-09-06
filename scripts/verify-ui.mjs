import { chromium } from '@playwright/test'

const appUrl = process.env.APP_URL ?? 'http://127.0.0.1:4173'
const hostPin = process.env.HOST_PIN

if (!hostPin) {
  throw new Error('Set HOST_PIN to verify the live host console')
}

const browser = await chromium.launch({ headless: true })
const errors = []

try {
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 1,
  })
  const page = await context.newPage()
  page.on('pageerror', (error) => errors.push(`page: ${error.message}`))
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(`console: ${message.text()}`)
  })

  const nickname = `Live${Date.now().toString().slice(-6)}`
  await page.goto(appUrl, { waitUntil: 'networkidle' })
  await page.getByLabel('Nickname').fill(nickname)
  await page.getByRole('button', { name: 'Enter The Kennel' }).click()
  await page.getByRole('button', { name: new RegExp(nickname) }).waitFor()
  await page.getByRole('heading', { name: 'Grand Final Squares' }).waitFor()
  await page.screenshot({ path: '/tmp/kennel-live-phone.png', fullPage: true })

  await context.clearCookies()
  await page.evaluate(() => localStorage.clear())
  await page.goto(`${appUrl}/host`, { waitUntil: 'networkidle' })
  await page.getByLabel('Host PIN').fill(hostPin)
  await page.getByRole('button', { name: 'Open console' }).click()
  await page.getByRole('heading', { name: 'Match control' }).waitFor()
  await page.getByRole('heading', { name: 'Score entry' }).waitFor()

  await page.setViewportSize({ width: 1440, height: 900 })
  await page.goto(`${appUrl}/screen`, { waitUntil: 'networkidle' })
  await page.getByRole('heading', { name: 'Grand Final Squares' }).waitFor()
  await page.screenshot({ path: '/tmp/kennel-live-screen.png', fullPage: true })

  if (errors.length > 0) {
    throw new Error(`Browser errors:\n${errors.join('\n')}`)
  }

  console.log('Live UI verification passed: guest join, host login, and projector view.')
} finally {
  await browser.close()
}
