const { test, expect } = require('./support');

test('独立した配送画面を表示する', async ({ page }) => {
  await page.goto('/shipping');
  await expect(page.locator('body')).toHaveText('standard');
});
