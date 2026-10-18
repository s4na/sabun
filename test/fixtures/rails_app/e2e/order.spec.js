const { test, expect } = require('./support');

test('注文からinlineジョブのDB更新まで完了する', async ({ page }, testInfo) => {
  // 初回失敗→worker再起動→成功の経路も、品質ゲートから明示的に実行する。
  if (process.env.SABUN_FIXTURE_RETRY && testInfo.retry === 0) {
    expect('first-attempt').toBe('retry-required');
  }
  await page.goto('/checkout');
  await page.getByRole('button', { name: 'Buy', exact: true }).click();
  await expect(page.locator('#status')).toHaveText('paid');
});
