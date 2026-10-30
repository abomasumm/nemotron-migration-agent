// Characterization tests for src/routes/orders.js: pin the HTTP behaviour exactly as it is
// today, including pricing rounding, stock reservation, validation order and the
// partial-reservation quirk, so the migration cannot change it.
import { describe, it, expect } from 'vitest';
import { useServer, call } from './helpers';

const ctx = useServer();

const MISSING = { error: { code: 'unauthorized', message: 'Missing x-api-key header' } };
const FORBIDDEN = { error: { code: 'forbidden', message: 'Invalid API key' } };

describe('POST /orders auth', () => {
  it('401s without a key, before validation', async () => {
    const r = await call(ctx, 'POST', '/orders', {});
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('403s with an invalid key, before validation', async () => {
    const r = await call(ctx, 'POST', '/orders', {}, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it('rejects an invalid body with an invalid key with 403, not 422', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [] }, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });
});

describe('POST /orders validation', () => {
  it('422s for an empty body with the exact envelope', async () => {
    const r = await call(ctx, 'POST', '/orders', {}, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'items must be a non-empty array' } });
  });

  it('422s for qty 0 with the exact envelope', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '1', qty: 0 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'items[0].qty must be a positive integer' } });
  });

  it('joins multiple item errors with "; "', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ qty: 0 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({
      error: { code: 'invalid', message: 'items[0].bookId is required; items[0].qty must be a positive integer' }
    });
  });

  it('422s for an unknown book with the exact envelope', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '999', qty: 1 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'Unknown book 999' } });
  });
});

describe('POST /orders stock checks', () => {
  it('409s for a stock-0 book with the exact envelope', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '3', qty: 1 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(409);
    expect(r.json).toEqual({
      error: { code: 'out_of_stock', message: 'Only 0 left of Working Effectively with Legacy Code' }
    });
  });
});

describe('POST /orders partial-reservation quirk', () => {
  // Both duplicate lines pass the per-line stock check against the pre-order stock (3 >= 2), but
  // reservation happens line by line, so the second line fails with the raw store error message
  // "insufficient stock" (not the "Only N left of ..." wording) and the first line's reservation
  // is NOT rolled back. No order is saved and the order-id counter is not consumed.
  it('decrements the first line, 409s on the second, and leaves no order behind', async () => {
    const before = await call(ctx, 'GET', '/books/2');
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '2', qty: 2 }, { bookId: '2', qty: 2 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(409);
    expect(r.json).toEqual({ error: { code: 'out_of_stock', message: 'insufficient stock' } });

    // The first reservation sticks: stock dropped by the reserved line only.
    const after = await call(ctx, 'GET', '/books/2');
    expect(after.json.stock).toBe(before.json.stock - 2);

    const gone = await call(ctx, 'GET', '/orders/ORD-1000', undefined, { 'x-api-key': 'dev-key' });
    expect(gone.status).toBe(404);
    expect(gone.json).toEqual({ error: { code: 'not_found', message: 'Order ORD-1000 not found' } });

    // The failed attempt did not consume the next id.
    const next = await call(ctx, 'POST', '/orders', { items: [{ bookId: '1', qty: 1 }] }, { 'x-api-key': 'dev-key' });
    expect(next.status).toBe(201);
    expect(next.json.id).toBe('ORD-1000');
  });
});

describe('POST /orders pricing', () => {
  it('charges full price below the bulk threshold: qty 9 has no discount', async () => {
    // A fresh book keeps the stock check independent of earlier tests in this file (state
    // persists here because reset() does not reach the server's store instance).
    const book = await call(ctx, 'POST', '/books', { title: 'Threshold Below', author: 'A', price: 100, stock: 9 }, { 'x-api-key': 'dev-key' });
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: book.json.id, qty: 9 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    expect(r.json.subtotal).toBe(900);
    expect(r.json.discount).toBe(0);
    expect(r.json.tax).toBe(72);
    expect(r.json.total).toBe(972);
  });

  it('applies the 5% discount at qty 10 and rounds discount, tax and total to 2 decimals', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '4', qty: 10 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    expect(r.headers.get('location')).toBe('/orders/' + r.json.id);
    expect(r.json).toEqual({
      id: r.json.id,
      createdAt: '2024-01-01T00:00:00.000Z',
      lines: [{ bookId: '4', title: 'Patterns of Enterprise Application Architecture', qty: 10, unitPrice: 59.95, lineTotal: 599.5 }],
      subtotal: 599.5,
      discount: 29.98,
      tax: 45.56,
      total: 615.08
    });

    const stock = await call(ctx, 'GET', '/books/4');
    expect(stock.json.stock).toBe(2);
  });

  it('charges no discount for a single unit: subtotal 59.95, tax 4.8, total 64.75', async () => {
    const before = await call(ctx, 'GET', '/books/4');
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '4', qty: 1 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(201);
    expect(r.json.lines).toEqual([{ bookId: '4', title: 'Patterns of Enterprise Application Architecture', qty: 1, unitPrice: 59.95, lineTotal: 59.95 }]);
    expect(r.json.subtotal).toBe(59.95);
    expect(r.json.discount).toBe(0);
    expect(r.json.tax).toBe(4.8);
    expect(r.json.total).toBe(64.75);

    const stock = await call(ctx, 'GET', '/books/4');
    expect(stock.json.stock).toBe(before.json.stock - 1);
  });
});

describe('GET /orders/:id', () => {
  it('401s without a key', async () => {
    const r = await call(ctx, 'GET', '/orders/ORD-1001');
    expect(r.status).toBe(401);
    expect(r.json).toEqual(MISSING);
  });

  it('403s with an invalid key', async () => {
    const r = await call(ctx, 'GET', '/orders/ORD-1001', undefined, { 'x-api-key': 'nope' });
    expect(r.status).toBe(403);
    expect(r.json).toEqual(FORBIDDEN);
  });

  it('404s for an unknown order with the exact envelope', async () => {
    const r = await call(ctx, 'GET', '/orders/ORD-9999', undefined, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(404);
    expect(r.json).toEqual({ error: { code: 'not_found', message: 'Order ORD-9999 not found' } });
  });

  it('returns the saved order exactly as POST returned it', async () => {
    const created = await call(ctx, 'POST', '/orders', { items: [{ bookId: '1', qty: 2 }] }, { 'x-api-key': 'dev-key' });
    expect(created.status).toBe(201);
    const read = await call(ctx, 'GET', '/orders/' + created.json.id, undefined, { 'x-api-key': 'dev-key' });
    expect(read.status).toBe(200);
    expect(read.json).toEqual(created.json);
    expect(read.json.lines).toEqual([{ bookId: '1', title: 'The Pragmatic Programmer', qty: 2, unitPrice: 42.5, lineTotal: 85 }]);
  });
});
