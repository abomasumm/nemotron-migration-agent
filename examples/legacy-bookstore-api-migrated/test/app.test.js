// Characterization tests for src/app.js: pin the HTTP-level wiring exactly as it is today —
// health, request ids, headers, JSON parsing and its quirks — so the Express-to-Fastify
// migration cannot change any observable result.
import { describe, it, expect } from 'vitest';
import { useServer, call } from './helpers';

const ctx = useServer();

describe('GET /health', () => {
  it('returns 200 with exactly {"status":"ok"}', async () => {
    const r = await call(ctx, 'GET', '/health');
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ status: 'ok' });
    expect(r.text).toBe('{"status":"ok"}');
  });

  it('also matches a trailing slash (strict routing off)', async () => {
    const r = await call(ctx, 'GET', '/health/');
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ status: 'ok' });
  });
});

describe('trailing slash on /books', () => {
  it('GET /books/ behaves like GET /books', async () => {
    const r = await call(ctx, 'GET', '/books/');
    expect(r.status).toBe(200);
    expect(r.json.total).toBe(4);
    expect(r.headers.get('x-total-count')).toBe('4');
    expect(r.json.items.map((b) => b.id)).toEqual(['1', '2', '3', '4']);
  });
});

describe('x-request-id', () => {
  it('echoes the request-supplied value', async () => {
    const r = await call(ctx, 'GET', '/health', undefined, { 'x-request-id': 'my-id-42' });
    expect(r.headers.get('x-request-id')).toBe('my-id-42');
  });

  it('generates req-<number> when absent', async () => {
    const r = await call(ctx, 'GET', '/health');
    expect(r.headers.get('x-request-id')).toMatch(/^req-\d+$/);
  });

  it('is present on a 404 response too', async () => {
    const r = await call(ctx, 'GET', '/nope');
    expect(r.status).toBe(404);
    expect(r.headers.get('x-request-id')).toMatch(/^req-\d+$/);
  });
});

describe('headers', () => {
  it('does not expose x-powered-by', async () => {
    const r = await call(ctx, 'GET', '/health');
    expect(r.headers.get('x-powered-by')).toBeNull();
  });
});

describe('unknown routes', () => {
  it('404s with the API error envelope', async () => {
    const r = await call(ctx, 'GET', '/nope');
    expect(r.status).toBe(404);
    expect(r.json).toEqual({ error: { code: 'not_found', message: 'No route for GET /nope' } });
  });
});

describe('JSON parsing', () => {
  it('rejects malformed JSON with 400 bad_json', async () => {
    const r = await call(ctx, 'POST', '/books', '{"title": broken}', { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });
  });

  it('treats a non-JSON content-type as an empty body: 422, not 415', async () => {
    // body-parser only parses application/json, so a text/plain body is ignored and the
    // handler sees an empty object; it is never rejected with 415.
    const r = await call(ctx, 'POST', '/books', '{"title": "New", "author": "A", "price": 1.5}', {
      'content-type': 'text/plain',
      'x-api-key': 'dev-key'
    });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({
      error: { code: 'invalid', message: 'title is required; author is required; price must be a positive number' }
    });
  });

  it('rejects a body over 100kb with 500 internal (the limit maps to the generic error)', async () => {
    // The 100kb body-parser limit throws entity.too.large, which the error handler does not
    // special-case, so it falls through to the 500 internal envelope. Pinned as-is.
    const big = { title: 'x'.repeat(110 * 1024), author: 'A', price: 1.5 };
    const r = await call(ctx, 'POST', '/books', big, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(500);
    expect(r.json).toEqual({ error: { code: 'internal', message: 'Something went wrong' } });
  });
});
