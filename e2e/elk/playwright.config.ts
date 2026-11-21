import { defineConfig, devices } from '@playwright/test'

// Runs inside the e2e Docker network (see ../compose.yaml); elk.test,
// ochoko.ynkt.test and mastodon.test resolve to the TLS proxy there.
export default defineConfig({
  testDir: './tests',
  outputDir: 'test-results/artifacts',
  // The steps share one logged-in session and build on each other.
  workers: 1,
  fullyParallel: false,
  timeout: 120_000,
  expect: { timeout: 30_000 },
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'test-results/report' }]],
  use: {
    ...devices['Desktop Chrome'],
    baseURL: 'https://elk.test',
    locale: 'en-US',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
})
