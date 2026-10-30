// Pins the side-effect entrypoint src/index.js: it starts the API on PORT and logs the listening
// URL. The child is spawned through the project's tsx binary — the same runtime as `npm start` —
// and never imported into this process, so this keeps passing once the entrypoint becomes
// src/index.ts (tsx resolves a `.js` specifier to the `.ts` file).
import { describe, it, expect, afterAll } from 'vitest';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import net from 'node:net';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const tsxCli = require.resolve('tsx/cli');
const root = fileURLToPath(new URL('..', import.meta.url));

const live = [];

afterAll(() => {
  for (const child of live) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  }
});

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

function spawnEntrypoint(port) {
  const child = spawn(process.execPath, [tsxCli, 'src/index.js'], {
    cwd: root,
    env: { ...process.env, PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  live.push(child);
  let out = '';
  let err = '';
  child.stdout.on('data', (chunk) => { out += chunk; });
  child.stderr.on('data', (chunk) => { err += chunk; });
  return { child, stdout: () => out, stderr: () => err };
}

async function waitForLine(child, getStdout, getStderr, line, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (getStdout().split('\n').includes(line)) return;
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(`child exited before printing ${JSON.stringify(line)}; stdout: ${JSON.stringify(getStdout())}, stderr: ${JSON.stringify(getStderr())}`);
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  throw new Error(`timed out waiting for stdout line ${JSON.stringify(line)}; stdout so far: ${JSON.stringify(getStdout())}`);
}

async function canConnect(port) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port });
    sock.once('connect', () => { sock.destroy(); resolve(true); });
    sock.once('error', () => resolve(false));
  });
}

describe('src/index entrypoint', () => {
  it('starts on PORT and logs "bookstore api on <url>", and /health answers {"status":"ok"}', async () => {
    const port = await getFreePort();
    const url = `http://127.0.0.1:${port}`;
    const { child, stdout, stderr } = spawnEntrypoint(port);
    try {
      await waitForLine(child, stdout, stderr, `bookstore api on ${url}`, 10000);
      const res = await fetch(url + '/health');
      const text = await res.text();
      expect(res.status).toBe(200);
      expect(text).toBe('{"status":"ok"}');
    } finally {
      child.kill('SIGKILL');
      await once(child, 'exit').catch(() => {});
    }
  });

  it('exits on SIGTERM within a few seconds and releases the port', async () => {
    const port = await getFreePort();
    const { child } = spawnEntrypoint(port);
    try {
      child.kill('SIGTERM');
      const exit = await Promise.race([
        once(child, 'exit').then(() => true),
        new Promise((r) => setTimeout(() => r(false), 5000))
      ]);
      if (!exit) {
        child.kill('SIGKILL');
        throw new Error('child did not exit within 5s of SIGTERM');
      }
      const deadline = Date.now() + 2000;
      while (await canConnect(port) && Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 50));
      }
      expect(await canConnect(port)).toBe(false);
    } finally {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill('SIGKILL');
        await once(child, 'exit').catch(() => {});
      }
    }
  });
});
