const { test, expect } = require('./support');

test('購入画面に価格と起動時の値を表示する', async ({ page }) => {
  await page.goto('/checkout');
  await expect(page.getByRole('heading', { name: 'Checkout', exact: true })).toBeVisible();
  await expect(page.locator('#price')).toBeVisible();
  await expect(page.locator('#price')).toHaveText('1200');
  await expect(page.locator('#banner')).toHaveText('ready');
});

test('ブラウザーで補足情報を開ける', async ({ page }) => {
  await page.goto('/checkout');
  await page.getByRole('button', { name: 'Details', exact: true }).click();
  await expect(page.locator('#details')).toHaveText('details ready');
});
