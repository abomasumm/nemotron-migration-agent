import { describe, it, expect } from 'vitest';
import { useServer, call } from './helpers';

const ctx = useServer();

describe('GET /books', () => {
  it('lists books with paging metadata and a total-count header', async () => {
    const r = await call(ctx, 'GET', '/books?limit=2');
    expect(r.status).toBe(200);
    expect(r.json.total).toBe(4);
    expect(r.json.items.map((b) => b.id)).toEqual(['1', '2']);
    expect(r.json.limit).toBe(2);
    expect(r.json.offset).toBe(0);
    expect(r.headers.get('x-total-count')).toBe('4');
  });

  it('filters by author, case-insensitively', async () => {
    const r = await call(ctx, 'GET', '/books?author=fowler');
    expect(r.json.items.map((b) => b.title)).toEqual(['Refactoring', 'Patterns of Enterprise Application Architecture']);
  });

  it('rejects a bad limit', async () => {
    const r = await call(ctx, 'GET', '/books?limit=0');
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_query', message: 'limit must be 1-100' } });
  });
});

describe('GET /books/:id', () => {
  it('returns one book', async () => {
    const r = await call(ctx, 'GET', '/books/2');
    expect(r.json).toEqual({ id: '2', title: 'Refactoring', author: 'Fowler', price: 47.99, stock: 3 });
  });

  it('404s with the API error format', async () => {
    const r = await call(ctx, 'GET', '/books/99');
    expect(r.status).toBe(404);
    expect(r.json).toEqual({ error: { code: 'not_found', message: 'Book 99 not found' } });
  });
});
