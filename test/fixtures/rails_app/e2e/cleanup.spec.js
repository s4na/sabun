const { test, expect } = require('./support');

test('suite cleanup has a Rails endpoint', async ({ page }) => {
  await page.goto('/health');
  await expect(page.locator('body')).toHaveText('ok');
});

test.afterAll(async () => {
  const response = await fetch(`${process.env.SABUN_E2E_URL_TEMPLATE}/__fixture__/cleanup`);
  if (!response.ok) throw new Error(`cleanup request failed: ${response.status}`);
  await response.text();
});
