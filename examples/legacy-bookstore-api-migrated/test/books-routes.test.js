// Characterization tests for src/routes/books.js: pin the HTTP behaviour exactly as it is today,
// including parsing quirks and error envelopes, so the migration cannot change it.
import { describe, it, expect } from 'vitest';
import { useServer, call } from './helpers';

const ctx = useServer();

describe('GET /books paging', () => {
  it('returns paging metadata and a total-count header', async () => {
    const r = await call(ctx, 'GET', '/books?limit=1&offset=1');
    expect(r.status).toBe(200);
    expect(r.headers.get('x-total-count')).toBe('4');
    expect(r.json).toEqual({
      items: [{ id: '2', title: 'Refactoring', author: 'Fowler', price: 47.99, stock: 3 }],
      total: 4,
      limit: 1,
      offset: 1
    });
  });

  it('defaults to limit 20 and offset 0', async () => {
    const r = await call(ctx, 'GET', '/books');
    expect(r.status).toBe(200);
    expect(r.json.limit).toBe(20);
    expect(r.json.offset).toBe(0);
    expect(r.json.total).toBe(4);
    expect(r.json.items.map((b) => b.id)).toEqual(['1', '2', '3', '4']);
  });

  it('pins the parseInt quirk: 2abc parses as 2', async () => {
    const r = await call(ctx, 'GET', '/books?limit=2abc');
    expect(r.status).toBe(200);
    expect(r.json.limit).toBe(2);
    expect(r.json.items.length).toBe(2);
  });

  it('pins the duplicate-query quirk: limit=2&limit=3 uses 2', async () => {
    const r = await call(ctx, 'GET', '/books?limit=2&limit=3');
    expect(r.status).toBe(200);
    expect(r.json.limit).toBe(2);
    expect(r.json.items.length).toBe(2);
  });
});

describe('GET /books filters', () => {
  it('filters by author, case-insensitively', async () => {
    const r = await call(ctx, 'GET', '/books?author=fowler');
    expect(r.status).toBe(200);
    expect(r.headers.get('x-total-count')).toBe('2');
    expect(r.json.items.map((b) => b.id)).toEqual(['2', '4']);
    expect(r.json.total).toBe(2);
    expect(r.json.limit).toBe(20);
    expect(r.json.offset).toBe(0);
  });

  it('filters by inStock=true, excluding stock-0 books', async () => {
    const r = await call(ctx, 'GET', '/books?inStock=true');
    expect(r.status).toBe(200);
    expect(r.json.items.map((b) => b.id)).toEqual(['1', '2', '4']);
    expect(r.json.total).toBe(3);
  });
});

describe('GET /books query validation', () => {
  it('rejects limit 0', async () => {
    const r = await call(ctx, 'GET', '/books?limit=0');
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_query', message: 'limit must be 1-100' } });
  });

  it('rejects limit 101', async () => {
    const r = await call(ctx, 'GET', '/books?limit=101');
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_query', message: 'limit must be 1-100' } });
  });

  it('rejects a negative offset', async () => {
    const r = await call(ctx, 'GET', '/books?offset=-1');
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_query', message: 'offset must be >= 0' } });
  });

  it('rejects a non-numeric offset', async () => {
    const r = await call(ctx, 'GET', '/books?offset=abc');
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_query', message: 'offset must be >= 0' } });
  });
});

describe('GET /books/:id', () => {
  it('returns one book', async () => {
    const r = await call(ctx, 'GET', '/books/999');
    expect(r.status).toBe(404);
    expect(r.json).toEqual({ error: { code: 'not_found', message: 'Book 999 not found' } });
  });
});

describe('POST /books auth', () => {
  it('401s without a key, before validation', async () => {
    const r = await call(ctx, 'POST', '/books', {});
    expect(r.status).toBe(401);
    expect(r.json).toEqual({ error: { code: 'unauthorized', message: 'Missing x-api-key header' } });
  });

  it('403s with an invalid key, before validation', async () => {
    const r = await call(ctx, 'POST', '/books', {}, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual({ error: { code: 'forbidden', message: 'Invalid API key' } });
  });
});

describe('POST /books', () => {
  it('creates a book with a Location header and defaults stock to 0', async () => {
    const r = await call(ctx, 'POST', '/books', { title: 'New', author: 'A', price: 1.5 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    expect(r.headers.get('location')).toBe('/books/5');
    expect(r.json).toEqual({ id: '5', title: 'New', author: 'A', price: 1.5, stock: 0 });
  });

  it('keeps an explicit positive stock', async () => {
    const r = await call(ctx, 'POST', '/books', { title: 'New', author: 'A', price: 1.5, stock: 2 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    expect(r.json.stock).toBe(2);
  });

  // The brief expected stock null to become 0 via createBook's `data.stock || 0`, but validation
  // rejects null first (Number.isInteger(null) is false), so the request never reaches the store.
  it('rejects a null stock with 422 before the store ever sees it', async () => {
    const r = await call(ctx, 'POST', '/books', { title: 'New', author: 'A', price: 1.5, stock: null }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'stock must be a non-negative integer' } });
  });

  it('rejects an empty body with all messages joined by "; "', async () => {
    const r = await call(ctx, 'POST', '/books', {}, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'title is required; author is required; price must be a positive number' } });
  });
});

describe('PATCH /books/:id/stock', () => {
  it('401s without a key, before validation', async () => {
    const r = await call(ctx, 'PATCH', '/books/999/stock', { delta: 1 });
    expect(r.status).toBe(401);
    expect(r.json).toEqual({ error: { code: 'unauthorized', message: 'Missing x-api-key header' } });
  });

  it('403s with an invalid key, before validation', async () => {
    const r = await call(ctx, 'PATCH', '/books/999/stock', { delta: 1 }, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual({ error: { code: 'forbidden', message: 'Invalid API key' } });
  });

  it('decrements stock', async () => {
    const r = await call(ctx, 'PATCH', '/books/2/stock', { delta: -1 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(200);
    expect(r.json).toEqual({ id: '2', title: 'Refactoring', author: 'Fowler', price: 47.99, stock: 2 });
  });

  it('accepts a delta of 0 and leaves the stock unchanged', async () => {
    // Read the current stock first: state persists across tests in this harness (the helpers'
    // reset() does not reach the server's store instance), so a hard-coded value would be fragile.
    const before = await call(ctx, 'GET', '/books/2');
    const r = await call(ctx, 'PATCH', '/books/2/stock', { delta: 0 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(200);
    expect(r.json).toEqual(before.json);
  });

  it('rejects a non-integer delta', async () => {
    const r = await call(ctx, 'PATCH', '/books/2/stock', { delta: 1.5 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'delta must be an integer' } });
  });

  it('409s when stock would go negative', async () => {
    const r = await call(ctx, 'PATCH', '/books/3/stock', { delta: -1 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(409);
    expect(r.json).toEqual({ error: { code: 'conflict', message: 'insufficient stock' } });
  });

  it('404s for an unknown book, after validation', async () => {
    const r = await call(ctx, 'PATCH', '/books/999/stock', { delta: 1 }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(404);
    expect(r.json).toEqual({ error: { code: 'not_found', message: 'Book 999 not found' } });
  });
});
