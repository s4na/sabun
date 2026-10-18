const { test: base, expect } = require('@playwright/test');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

async function control(url, token, action, id, identity) {
  const response = await fetch(`${url.replace(/\/$/, '')}/__sabun__/control`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ action, id, identity }),
  });
  if (!response.ok) throw new Error(`sabun ${action}: HTTP ${response.status} ${await response.text()}`);
  return response.json();
}

const test = base.extend({
  sabunTracking: [async ({ page }, use, testInfo) => {
    const token = process.env.SABUN_E2E_TOKEN;
    const template = process.env.SABUN_E2E_URL_TEMPLATE;
    const output = process.env.SABUN_RECORD_FILE;
    const expected = process.env.SABUN_EXPECTED_IDENTITY;
    if (!output && !expected) {
      await use();
      return;
    }
    if (!expected) throw new Error('sabun requires an expected worker identity from the CLI');
    const identity = JSON.parse(expected);
    if (!token || !template) throw new Error('sabun E2E recording requires TOKEN and URL_TEMPLATE');
    const url = template.replaceAll('{parallelIndex}', String(testInfo.parallelIndex));
    const id = `${process.pid}-${testInfo.workerIndex}-${testInfo.retry}-${crypto.randomUUID()}`;
    const rel = path.relative(process.env.SABUN_ROOT || process.cwd(), testInfo.file).replaceAll('\\', '/');
    const unit = `${rel}::${testInfo.project.name}`;
    await control(url, token, 'start', id, identity);
    let result;
    try {
      await use();
    } finally {
      result = await control(url, token, 'finish', id, identity);
      if (output) {
        const dir = `${output}.d`;
        fs.mkdirSync(dir, { recursive: true });
        const filename = path.join(dir, `${crypto.randomUUID()}.json`);
        fs.writeFileSync(filename, JSON.stringify({ unit, test_id: testInfo.testId, complete: testInfo.status === 'passed', dependencies: result.dependencies, identity: result.identity, worker_id: result.worker_id }));
      }
    }
  }, { auto: true }],
});
module.exports = { test, expect };
