import { expect, test } from '@playwright/test'

test.beforeEach(async ({ page }) => {
  const runtimeErrors: string[] = []
  page.on('pageerror', (error) => runtimeErrors.push(error.message))
  page.on('console', (message) => {
    if (message.type() === 'error') runtimeErrors.push(message.text())
  })
  ;(page as typeof page & { runtimeErrors?: string[] }).runtimeErrors = runtimeErrors
})

test.afterEach(async ({ page }) => {
  const runtimeErrors = (page as typeof page & { runtimeErrors?: string[] }).runtimeErrors ?? []
  expect(runtimeErrors, 'browser console and page errors').toEqual([])
})

test('guest joins and sees highlighted squares on a phone', async ({ page }) => {
  await page.goto('/')
  await page.getByLabel('Nickname').fill('Macca')
  await page.getByRole('button', { name: 'Enter The Kennel' }).click()
  await expect(page.getByRole('heading', { name: 'Grand Final Squares' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Macca 2 squares' })).toBeVisible()
  await expect(page.getByRole('gridcell', { name: /currently live/i })).toBeVisible()
  await expect(page.locator('.digit-header:not(.digit-header--row)')).toHaveText([
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
  ])
  await expect(page.locator('.digit-header--row')).toHaveText([
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
  ])
  await page.screenshot({ path: `/tmp/kennel-${test.info().project.name}-guest.png`, fullPage: true })
})

test('host can score and undo in the local demo', async ({ page }) => {
  await page.goto('/host')
  await page.getByLabel('Host PIN').fill('2468')
  await page.getByRole('button', { name: 'Open console' }).click()
  await page.getByRole('button', { name: 'Start Q1' }).click()
  await page.getByRole('button', { name: 'Home goal' }).click()
  await expect(page.getByText('1.0 (6)')).toBeVisible()
  await page.getByRole('button', { name: /Undo last score/ }).click()
  await expect(page.getByText('0.0 (0)')).toHaveCount(2)
})

test('projector and print routes render without authentication', async ({ page }) => {
  await page.goto('/screen')
  await expect(page.getByRole('heading', { name: 'Grand Final Squares' })).toBeVisible()
  await page.screenshot({ path: `/tmp/kennel-${test.info().project.name}-screen.png`, fullPage: true })
  await page.goto('/host/print')
  await expect(page.getByRole('button', { name: 'Print grid' })).toBeVisible()
})
