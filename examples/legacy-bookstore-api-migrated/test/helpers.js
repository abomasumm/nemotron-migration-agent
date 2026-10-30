// Starts the API on a random port for each test file. Uses only start() and HTTP, so the tests don't
// depend on the web framework.
import { beforeAll, afterAll, beforeEach } from 'vitest';
import { start } from '../src/server';
import { reset } from '../src/store';

export function useServer() {
  const ctx = { url: '' };
  let srv;
  beforeAll(async () => { srv = await start(0); ctx.url = srv.url; });
  afterAll(async () => { await srv.close(); });
  beforeEach(() => reset());
  return ctx;
}

export async function call(ctx, method, path, body, headers = {}) {
  const res = await fetch(ctx.url + path, {
    method,
    headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body)
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch (e) { /* not JSON */ }
  return { status: res.status, headers: res.headers, json, text };
}
