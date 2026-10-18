const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Reporter = require('../playwright/reporter');

function withRecording(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sabun-reporter-'));
  const previous = process.env.SABUN_RECORD_FILE;
  const output = path.join(root, 'record');
  process.env.SABUN_RECORD_FILE = output;
  try {
    const reporter = new Reporter();
    run(reporter);
    return JSON.parse(fs.readFileSync(`${output}.manifest.json`, 'utf8'));
  } finally {
    if (previous === undefined) delete process.env.SABUN_RECORD_FILE;
    else process.env.SABUN_RECORD_FILE = previous;
    fs.rmSync(root, { recursive: true, force: true });
  }
}
const example = { id: 'example-1', expectedStatus: 'passed' };
const suite = { allTests: () => [example] };

test('実Reporter APIのonBegin(config, suite)で完全なマップを作れる', () => {
  const manifest = withRecording(reporter => {
    reporter.onBegin({ projects: [] }, suite);
    reporter.onTestEnd(example, { status: 'passed' });
    reporter.onEnd({ status: 'passed' });
  });
  assert.equal(manifest.complete, true);
  assert.deepEqual(manifest.tests, ['example-1']);
});

test('retryで最後に成功しても部分的な観測を昇格しない', () => {
  const manifest = withRecording(reporter => {
    reporter.onBegin({}, suite);
    reporter.onTestEnd(example, { status: 'failed' });
    reporter.onTestEnd(example, { status: 'passed' });
    reporter.onEnd({ status: 'passed' });
  });
  assert.equal(manifest.complete, false);
});

test('グローバルエラーがあれば成功結果でも昇格しない', () => {
  const manifest = withRecording(reporter => {
    reporter.onBegin({}, suite);
    reporter.onTestEnd(example, { status: 'passed' });
    reporter.onError(new Error('worker disappeared'));
    reporter.onEnd({ status: 'passed' });
  });
  assert.equal(manifest.complete, false);
});

test('onBeginを受け取れていない場合を空の正常マップにしない', () => {
  const manifest = withRecording(reporter => { reporter.onEnd({ status: 'passed' }); });
  assert.equal(manifest.complete, false);
});
