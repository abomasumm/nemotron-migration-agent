// Characterization tests for requireKey (src/auth.js), exercised over HTTP through the routes
// that use it. Pins what the code does today, before the Fastify migration.
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { useServer, call } from './helpers';

const ctx = useServer();

const ENV_NAME = 'BOOKSTORE_API_KEYS';
let savedValue;

beforeEach(() => {
  savedValue = process.env[ENV_NAME];
});

afterEach(() => {
  if (savedValue === undefined) delete process.env[ENV_NAME];
  else process.env[ENV_NAME] = savedValue;
});

const MISSING = { error: { code: 'unauthorized', message: 'Missing x-api-key header' } };
const FORBIDDEN = { error: { code: 'forbidden', message: 'Invalid API key' } };

const validBook = { title: 'Clean Code', author: 'Martin', price: 29.99, stock: 5 };
const validOrder = { items: [{ bookId: '1', qty: 2 }] };

async function createOrder() {
  // The tests talk HTTP only, so make an order to read via POST /orders first.
  const r = await call(ctx, 'POST', '/orders', validOrder, { 'x-api-key': 'dev-key' });
  expect(r.status).toBe(201);
  return r.json.id;
}

describe('POST /books authentication', () => {
  it('401s with the exact unauthorized envelope when x-api-key is missing', async () => {
    const r = await call(ctx, 'POST', '/books', validBook);
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('403s with the exact forbidden envelope for an unknown key', async () => {
    const r = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it('accepts the default dev-key when BOOKSTORE_API_KEYS is unset', async () => {
    delete process.env[ENV_NAME];
    const r = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    // reset() seeds books 1-4, so the first created book gets id 5
    expect(r.headers.get('location')).toBe('/books/5');
    expect(r.json).toEqual({ id: '5', title: 'Clean Code', author: 'Martin', price: 29.99, stock: 5 });
  });

  it('rejects an invalid body without a key with 401, not 422', async () => {
    const r = await call(ctx, 'POST', '/books', { price: -1 });
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('runs authentication before validation with an invalid key too', async () => {
    const r = await call(ctx, 'POST', '/books', { price: -1 }, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });
});

describe('PATCH /books/:id/stock authentication', () => {
  it('401s when x-api-key is missing', async () => {
    const r = await call(ctx, 'PATCH', '/books/1/stock', { delta: -1 });
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('403s for an invalid key', async () => {
    const r = await call(ctx, 'PATCH', '/books/1/stock', { delta: -1 }, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it('succeeds with dev-key (auth runs before the 404 for unknown books too)', async () => {
    const ok = await call(ctx, 'PATCH', '/books/1/stock', { delta: -1 }, { 'x-api-key': 'dev-key' });
    expect(ok.status).toBe(200);
    expect(ok.json.stock).toBe(6);

    const missing = await call(ctx, 'PATCH', '/books/999/stock', { delta: -1 }, { 'x-api-key': 'dev-key' });
    expect(missing.status).toBe(404);
    expect(missing.json).toEqual({ error: { code: 'not_found', message: 'Book 999 not found' } });
  });

  it('rejects an invalid delta without a key with 401, not 422', async () => {
    const r = await call(ctx, 'PATCH', '/books/1/stock', { delta: 'x' });
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });
});

describe('POST /orders authentication', () => {
  it('401s when x-api-key is missing', async () => {
    const r = await call(ctx, 'POST', '/orders', validOrder);
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('403s for an invalid key', async () => {
    const r = await call(ctx, 'POST', '/orders', validOrder, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it('succeeds with dev-key', async () => {
    const r = await call(ctx, 'POST', '/orders', validOrder, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    expect(r.headers.get('location')).toBe('/orders/ORD-1000');
    expect(r.json.id).toBe('ORD-1000');
  });

  it('rejects an invalid body without a key with 401, not 422', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [] });
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });
});

describe('GET /orders/:id authentication', () => {
  it('401s when x-api-key is missing, even for an unknown order', async () => {
    const r = await call(ctx, 'GET', '/orders/ORD-9999');
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('403s for an invalid key', async () => {
    const r = await call(ctx, 'GET', '/orders/ORD-9999', undefined, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it('reads an existing order with dev-key and 404s unknown orders with a valid key', async () => {
    const id = await createOrder();
    const ok = await call(ctx, 'GET', '/orders/' + id, undefined, { 'x-api-key': 'dev-key' });
    expect(ok.status).toBe(200);
    expect(ok.json.id).toBe(id);

    const missing = await call(ctx, 'GET', '/orders/ORD-9999', undefined, { 'x-api-key': 'dev-key' });
    expect(missing.status).toBe(404);
    expect(missing.json).toEqual({ error: { code: 'not_found', message: 'Order ORD-9999 not found' } });
  });
});

describe('BOOKSTORE_API_KEYS configuration', () => {
  it("keys are comma separated and trimmed: ' k1 , k2 ' accepts k1 and k2", async () => {
    process.env[ENV_NAME] = ' k1 , k2 ';
    const a = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'k1' });
    expect(a.status).toBe(201);
    const b = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'k2' });
    expect(b.status).toBe(201);
  });

  it("matching is case sensitive: ' k1 , k2 ' rejects K1", async () => {
    process.env[ENV_NAME] = ' k1 , k2 ';
    const r = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'K1' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it("the header value ' k1 ' is accepted: HTTP trims header whitespace before requireKey sees it", async () => {
    // The brief expected ' k1 ' to be rejected, but undici strips leading/trailing whitespace from
    // header values per the HTTP spec, so the middleware receives 'k1' and accepts it. Pinned as-is.
    process.env[ENV_NAME] = ' k1 , k2 ';
    const r = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': ' k1 ' });
    expect(r.status).toBe(201);
  });

  it('dev-key stops working once BOOKSTORE_API_KEYS is set without it', async () => {
    delete process.env[ENV_NAME];
    const before = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'dev-key' });
    expect(before.status).toBe(201);

    process.env[ENV_NAME] = 'other-key';
    const after = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'dev-key' });
    expect(after.status).toBe(403);
    expect(after.json).toEqual(FORBIDDEN);
  });

  it('keys are read per request, so changing the env after start takes effect without a restart', async () => {
    process.env[ENV_NAME] = 'first';
    const first = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'first' });
    expect(first.status).toBe(201);

    process.env[ENV_NAME] = 'second';
    const stale = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'first' });
    expect(stale.status).toBe(403);
    const second = await call(ctx, 'POST', '/books', validBook, { 'x-api-key': 'second' });
    expect(second.status).toBe(201);
  });
});
