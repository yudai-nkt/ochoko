// Elk (self-hosted at elk.test) used as the client of ochoko, automating
// docs/elk-smoke-test.md. Mastodon (alice@mastodon.test) plays the remote
// account through its API. The steps share one signed-in page and run in
// order.

import {
  type APIRequestContext,
  expect,
  type Page,
  request,
  type Response,
  test,
} from '@playwright/test'
import { writeFileSync } from 'node:fs'

const ochokoHost = 'ochoko.ynkt.test'
const ochokoAcct = 'yudai@ynkt.test'
const aliceAcct = 'alice@mastodon.test'

test.describe.configure({ mode: 'serial' })

let page: Page
let mastodon: APIRequestContext
/** Requests to ochoko that Elk made and that answered 404 (checklist 10). */
const notFound = new Set<string>()
/** Requests to ochoko that answered 5xx; any one fails the run. */
const serverErrors: string[] = []

test.beforeAll(async ({ browser }) => {
  page = await browser.newPage()
  page.on('response', (r: Response) => {
    const url = new URL(r.url())
    if (url.host !== ochokoHost)
      return
    const call = `${r.request().method()} ${url.pathname}`
    if (r.status() === 404)
      notFound.add(call)
    if (r.status() >= 500)
      serverErrors.push(`${r.status()} ${call}`)
  })
  mastodon = await request.newContext({
    baseURL: 'https://mastodon.test',
    extraHTTPHeaders: { Authorization: `Bearer ${process.env.MASTODON_TOKEN}` },
  })
})

test.afterAll(async () => {
  const report = [...notFound].sort().join('\n')
  writeFileSync('test-results/ochoko-404.txt', report ? `${report}\n` : '')
  console.log(`ochoko endpoints that answered 404 to Elk:\n${report || '(none)'}`)
  await mastodon.dispose()
})

test.afterEach(() => {
  expect(serverErrors, 'ochoko answered 5xx').toEqual([])
})

test('1. signs in to ochoko through Elk', async () => {
  await page.goto('/')
  await page.getByRole('button', { name: 'Sign in' }).first().click()
  const server = page.locator('input[inputmode="url"]')
  await server.fill(ochokoHost)
  await server.press('Enter')
  // ochoko's own login page.
  await page.waitForURL(new RegExp(`^https://${ochokoHost}/oauth/authorize`))
  await page.getByLabel('Password').fill('e2e-password')
  await page.getByRole('button', { name: 'Authorize' }).click()
  await page.waitForURL(/^https:\/\/elk\.test\/home/)
})

test('12. Elk shows the handle with the account domain', async () => {
  await expect(page.getByText(`@${ochokoAcct}`).first()).toBeVisible()
  await expect(page.getByText(`@yudai@${ochokoHost}`)).toHaveCount(0)
})

test('2. home, notifications and own profile load', async () => {
  await expect(page.getByText('End of the list')).toBeVisible()
  await page.getByRole('link', { name: 'Notifications' }).first().click()
  await page.waitForURL(/\/notifications/)
  await expect(page.getByText(/error/i)).toHaveCount(0)
  await page.goto(`/${ochokoHost}/@yudai`)
  await expect(page.getByText(`@${ochokoAcct}`).first()).toBeVisible()
  await expect(page.getByText(/error/i)).toHaveCount(0)
})

test('3, 4. searches alice, follows, and the Accept arrives', async () => {
  await page.goto('/home')
  const search = page.getByPlaceholder('Search')
  await search.fill(`@${aliceAcct}`)
  await page.getByRole('link', { name: new RegExp(`@${aliceAcct}`) }).first().click()
  await page.waitForURL(new RegExp(`/@alice@mastodon\\.test`))
  const follow = page.getByRole('button', { name: 'Follow', exact: true })
  const following = page.getByRole('button', { name: /^(Following|Unfollow)$/ })
  await expect(follow.or(following)).toBeVisible()
  // Already following when the stack is reused (KEEP=1 runs).
  if (await follow.isVisible())
    await follow.click()
  // No streaming: reload until the relationship shows the Accept.
  await expect(async () => {
    await page.reload()
    await expect(page.getByRole('button', { name: /^(Following|Unfollow)$/ })).toBeVisible({ timeout: 2_000 })
  }).toPass({ timeout: 60_000 })
})

test('7. a follow from Mastodon shows up in Elk notifications', async () => {
  const yudai = await resolveOnMastodon(ochokoAcct)
  await mastodonPost(`/api/v1/accounts/${yudai.id}/follow`, {})
  // Until ochoko's Accept arrives Mastodon holds only a follow request and
  // drops our posts, so the next steps need the follow to be established.
  await expect.poll(() => mastodonFollowing(yudai.id), { timeout: 60_000 }).toBe(true)
  await page.goto('/notifications')
  await expect(async () => {
    await page.reload()
    await expect(page.getByText(/followed you/i).first()).toBeVisible({ timeout: 2_000 })
  }).toPass({ timeout: 60_000 })
})

let publicText = ''

test('5, 6. public and unlisted posts from Elk reach Mastodon', async () => {
  publicText = marker('elk-public')
  const unlistedText = marker('elk-unlisted')
  await publish(publicText)
  // Elk labels Mastodon's unlisted visibility "Quiet public".
  await publish(unlistedText, 'Quiet public')
  await expect.poll(() => visibilityOnMastodon(publicText), { timeout: 60_000 }).toBe('public')
  await expect.poll(() => visibilityOnMastodon(unlistedText), { timeout: 60_000 }).toBe('unlisted')
})

test('11. without streaming, own posts appear after a reload', async () => {
  await page.goto('/home')
  await expect(async () => {
    await page.reload()
    await expect(page.getByText(publicText)).toBeVisible({ timeout: 2_000 })
  }).toPass({ timeout: 30_000 })
})

test('a Mastodon post appears in Elk home timeline', async () => {
  const text = marker('from-mastodon')
  await mastodonPost('/api/v1/statuses', { status: text, visibility: 'public' })
  await expect(async () => {
    await page.reload()
    await expect(page.getByText(text)).toBeVisible({ timeout: 2_000 })
  }).toPass({ timeout: 60_000 })
})

test('8. deleting in Elk removes the post from Mastodon', async () => {
  await page.goto('/home')
  // The closest ancestor of the text that holds the post's own "More" menu.
  const post = page.getByText(publicText)
    .locator('xpath=ancestor::*[.//button[@aria-label="More"]][1]')
  await post.getByRole('button', { name: 'More' }).click()
  await page.getByRole('button', { name: 'Delete', exact: true }).click()
  // The confirmation is not a dialog role; scope to the question's container.
  await page.getByText('Are you sure you want to delete this post?')
    .locator('xpath=..')
    .getByRole('button', { name: 'Delete', exact: true })
    .click()
  // Elk drops deleted posts from a timeline on streaming events; without
  // streaming the post goes away on the next load.
  await expect(async () => {
    await page.reload()
    await expect(page.getByText('End of the list')).toBeVisible({ timeout: 5_000 })
    await expect(page.getByText(publicText)).toHaveCount(0)
  }).toPass({ timeout: 30_000 })
  await expect.poll(() => visibilityOnMastodon(publicText), { timeout: 60_000 }).toBe(null)
})

// ----------------------------------------------------------------- helpers

function marker(label: string): string {
  return `e2e-${label}-${Math.floor(Math.random() * 1e9)}`
}

async function publish(text: string, visibility?: 'Quiet public'): Promise<void> {
  await page.goto('/compose')
  if (visibility) {
    await page.getByRole('button', { name: 'Change content visibility' }).click()
    await page.getByText(visibility, { exact: true }).click()
  }
  const editor = page.locator('[contenteditable="true"]').first()
  await editor.click()
  await editor.pressSequentially(text)
  await page.getByRole('button', { name: 'Publish', exact: true }).click()
  await expect(editor).toHaveText('')
}

async function mastodonPost(path: string, data: object): Promise<unknown> {
  const res = await mastodon.post(path, { data })
  expect(res.ok(), `${path}: ${res.status()} ${await res.text()}`).toBe(true)
  return res.json()
}

async function resolveOnMastodon(acct: string): Promise<{ id: string }> {
  const res = await mastodon.get('/api/v2/search', {
    params: { q: `@${acct}`, resolve: 'true', type: 'accounts' },
  })
  expect(res.ok()).toBe(true)
  const { accounts } = await res.json() as { accounts: { id: string, acct: string }[] }
  const account = accounts.find(a => a.acct === acct)
  expect(account, `${acct} not found on Mastodon`).toBeDefined()
  return account!
}

async function mastodonFollowing(id: string): Promise<boolean> {
  const res = await mastodon.get('/api/v1/accounts/relationships', { params: { 'id[]': id } })
  expect(res.ok()).toBe(true)
  const [relationship] = await res.json() as { following: boolean }[]
  return relationship?.following ?? false
}

/** The visibility of the post containing `text` in alice's home, or null. */
async function visibilityOnMastodon(text: string): Promise<string | null> {
  const res = await mastodon.get('/api/v1/timelines/home')
  expect(res.ok()).toBe(true)
  const statuses = await res.json() as { content: string, visibility: string, account: { acct: string } }[]
  const status = statuses.find(s => s.content.includes(text) && s.account.acct === ochokoAcct)
  return status?.visibility ?? null
}
