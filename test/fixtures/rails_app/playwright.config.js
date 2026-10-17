const path = require('node:path');
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  workers: 2,
  retries: process.env.SABUN_FIXTURE_RETRY ? 1 : 0,
  forbidOnly: true,
  timeout: 15000,
  expect: { timeout: 1500 },
  use: { screenshot: 'only-on-failure' },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
  reporter: [
    [path.join(process.env.SABUN_SOURCE, 'playwright/reporter.js')],
    ['json', { outputFile: 'tmp/playwright-result.json' }],
  ],
});
