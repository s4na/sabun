const { test } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');

test('normal Playwright runs do not require recording environment', async () => {
  const original = Module._load;
  let fixtures;
  try {
    Module._load = function (name, ...args) {
      if (name === '@playwright/test') return {
        test: { extend: (value) => { fixtures = value; return value; } },
        expect: () => {}
      };
      return original.call(this, name, ...args);
    };
    require('../playwright/sabun');
  } finally {
    Module._load = original;
  }
  const previous = process.env.SABUN_RECORD_FILE;
  delete process.env.SABUN_RECORD_FILE;
  let invoked = false;
  try {
    await fixtures.sabunTracking[0]({ page: {} }, async () => { invoked = true; }, {});
  } finally {
    if (previous === undefined) delete process.env.SABUN_RECORD_FILE;
    else process.env.SABUN_RECORD_FILE = previous;
  }
  assert.equal(invoked, true);
});
