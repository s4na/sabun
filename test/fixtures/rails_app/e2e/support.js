const { spawn } = require('node:child_process');
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const { test: base, expect } = require(path.join(process.env.SABUN_SOURCE, 'playwright/sabun.js'));

async function unusedPort(parallelIndex) {
  // Give each concurrent Playwright slot a disjoint range. Port 0 can be
  // reused after the probe socket closes but before the Rails child binds it.
  const firstPort = 30000 + parallelIndex * 100;
  for (let offset = 0; offset < 100; offset += 1) {
    const socket = net.createServer();
    const port = firstPort + offset;
    const available = await new Promise(resolve => {
      socket.once('error', () => resolve(false));
      socket.listen(port, '127.0.0.1', () => resolve(true));
    });
    if (!available) continue;
    await new Promise(resolve => socket.close(resolve));
    return port;
  }
  throw new Error(`No free Rails fixture port for Playwright slot ${parallelIndex}`);
}

async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise(resolve => child.once('exit', resolve));
  child.kill('SIGTERM');
  const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
  try { await exited; } finally { clearTimeout(timer); }
}

const test = base.extend({
  fixtureServer: [async ({}, use, workerInfo) => {
    const root = process.cwd();
    const serverRoot = process.env.SABUN_FIXTURE_SERVER_ROOT || root;
    fs.mkdirSync(path.join(root, 'tmp'), { recursive: true });
    const port = await unusedPort(workerInfo.parallelIndex);
    const url = `http://127.0.0.1:${port}`;
    const log = path.join(root, 'tmp', `rails-worker-${workerInfo.workerIndex}.log`);
    const child = spawn(process.env.SABUN_RUBY, ['server.rb'], {
      cwd: serverRoot,
      env: {
        ...process.env,
        PORT: String(port),
        SABUN_ROOT: serverRoot,
        SABUN_CONFIG_PATH: path.join(serverRoot, 'sabun.json'),
        SABUN_FIXTURE_DATABASE: path.join(root, 'tmp', `worker-${workerInfo.workerIndex}.sqlite3`),
        SABUN_E2E_JOBS_SYNC: '1',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    let spawnError;
    child.on('error', error => { spawnError = error; });
    for (const stream of [child.stdout, child.stderr]) {
      stream.on('data', data => { output += data.toString(); fs.appendFileSync(log, data); });
    }
    const kill = () => child.kill('SIGKILL');
    process.once('exit', kill);
    const previous = process.env.SABUN_E2E_URL_TEMPLATE;
    try {
      const deadline = Date.now() + 30000;
      let ready = false;
      while (Date.now() < deadline) {
        if (spawnError) throw spawnError;
        if (child.exitCode !== null) throw new Error(`Rails exited: ${output}`);
        try {
          const response = await fetch(`${url}/health`, { signal: AbortSignal.timeout(500) });
          if (response.ok) { await response.text(); ready = true; break; }
        } catch { /* サーバー起動前の接続拒否は、期限付きで再確認する。 */ }
        await delay(50);
      }
      if (!ready) throw new Error(`Rails did not start: ${output}`);
      process.env.SABUN_E2E_URL_TEMPLATE = url;
      fs.appendFileSync(path.join(root, 'tmp', 'workers.jsonl'), JSON.stringify({
        worker: workerInfo.workerIndex, slot: workerInfo.parallelIndex, pid: child.pid, url,
      }) + '\n');
      await use(url);
    } finally {
      if (previous === undefined) delete process.env.SABUN_E2E_URL_TEMPLATE;
      else process.env.SABUN_E2E_URL_TEMPLATE = previous;
      await stop(child);
      process.removeListener('exit', kill);
    }
  }, { scope: 'worker', auto: true, timeout: 45000 }],
  baseURL: async ({ fixtureServer }, use) => { await use(fixtureServer); },
});

test.beforeEach(async ({ request }) => {
  const response = await request.post('/__fixture__/reset');
  expect(response.status()).toBe(204);
});

module.exports = { test, expect };
