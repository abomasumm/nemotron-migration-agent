// Characterization tests for the validation messages in src/validate.js, pinned both directly and
// through the 422 responses the routes produce. Pins what the code does today, before the Fastify
// migration. Messages and their order must stay exactly as they are here.
import { describe, it, expect } from 'vitest';
import { bookErrors, orderErrors } from '../src/validate';
import { useServer, call } from './helpers';

const ctx = useServer();

describe('bookErrors', () => {
  it('rejects a missing or non-object body with a single message', () => {
    expect(bookErrors(null)).toEqual(['body must be an object']);
    expect(bookErrors(undefined)).toEqual(['body must be an object']);
    expect(bookErrors(5)).toEqual(['body must be an object']);
  });

  it('requires title, author and price, in that order', () => {
    expect(bookErrors({})).toEqual(['title is required', 'author is required', 'price must be a positive number']);
  });

  it('reports all four messages in order title, author, price, stock', () => {
    expect(bookErrors({ title: ' ', author: ' ', price: 0, stock: -1 })).toEqual([
      'title is required',
      'author is required',
      'price must be a positive number',
      'stock must be a non-negative integer'
    ]);
  });

  it('accepts a missing stock and stock 0', () => {
    expect(bookErrors({ title: 'T', author: 'A', price: 1 })).toEqual([]);
    expect(bookErrors({ title: 'T', author: 'A', price: 1, stock: 0 })).toEqual([]);
  });

  it('rejects stock null, 1.5 and -1 with the non-negative-integer message', () => {
    const message = 'stock must be a non-negative integer';
    expect(bookErrors({ title: 'T', author: 'A', price: 1, stock: null })).toEqual([message]);
    expect(bookErrors({ title: 'T', author: 'A', price: 1, stock: 1.5 })).toEqual([message]);
    expect(bookErrors({ title: 'T', author: 'A', price: 1, stock: -1 })).toEqual([message]);
  });

  it('rejects a non-positive price but accepts positive fractional prices', () => {
    expect(bookErrors({ title: 'T', author: 'A', price: 0 })).toEqual(['price must be a positive number']);
    expect(bookErrors({ title: 'T', author: 'A', price: -1 })).toEqual(['price must be a positive number']);
    expect(bookErrors({ title: 'T', author: 'A', price: 0.01 })).toEqual([]);
  });

  it('treats blank-string titles and authors as missing, but any non-empty string passes', () => {
    expect(bookErrors({ title: ' ', author: 'A', price: 1 })).toEqual(['title is required']);
    expect(bookErrors({ title: 'T', author: '  ', price: 1 })).toEqual(['author is required']);
    expect(bookErrors({ title: ' T ', author: ' A ', price: 1 })).toEqual([]);
  });

  it('accepts an array body (typeof "object") and fails it on the fields', () => {
    expect(bookErrors([])).toEqual(['title is required', 'author is required', 'price must be a positive number']);
  });
});

describe('orderErrors', () => {
  it('rejects a missing, malformed or empty items array with a single message', () => {
    const message = ['items must be a non-empty array'];
    expect(orderErrors({})).toEqual(message);
    expect(orderErrors(null)).toEqual(message);
    expect(orderErrors({ items: [] })).toEqual(message);
    expect(orderErrors({ items: 'nope' })).toEqual(message);
  });

  it('requires a string bookId and a positive integer qty per item, in item order', () => {
    expect(orderErrors({ items: [{ bookId: 1, qty: 0 }, { bookId: '1', qty: 0 }] })).toEqual([
      'items[0].bookId is required',
      'items[0].qty must be a positive integer',
      'items[1].qty must be a positive integer'
    ]);
  });

  it('accepts valid items', () => {
    expect(orderErrors({ items: [{ bookId: '1', qty: 2 }] })).toEqual([]);
  });

  it('reports messages per item with the index in the message', () => {
    expect(orderErrors({ items: [null] })).toEqual([
      'items[0].bookId is required',
      'items[0].qty must be a positive integer'
    ]);
    expect(orderErrors({ items: [{ bookId: '1', qty: 1 }, { bookId: 2, qty: 0.5 }] })).toEqual([
      'items[1].bookId is required',
      'items[1].qty must be a positive integer'
    ]);
  });
});

describe('validation messages over HTTP', () => {
  it('POST /books returns a 422 with all book messages joined by "; "', async () => {
    const r = await call(ctx, 'POST', '/books', {}, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({
      error: {
        code: 'invalid',
        message: 'title is required; author is required; price must be a positive number'
      }
    });
  });

  it('POST /books with no body treats it as {} and 422s with the field messages', async () => {
    const r = await call(ctx, 'POST', '/books', undefined, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({
      error: {
        code: 'invalid',
        message: 'title is required; author is required; price must be a positive number'
      }
    });
  });

  it('POST /books can never reach the body-must-be-an-object branch over HTTP: JSON strings and null are 400 bad_json, not 422', async () => {
    const asString = await call(ctx, 'POST', '/books', 'nope', { 'x-api-key': 'dev-key' });
    expect(asString.status).toBe(400);
    expect(asString.json).toEqual({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });

    const asNull = await call(ctx, 'POST', '/books', null, { 'x-api-key': 'dev-key' });
    expect(asNull.status).toBe(400);
    expect(asNull.json).toEqual({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });
  });

  it('POST /orders returns a 422 with the first failing item message joined by "; "', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: '1', qty: 0 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'items[0].qty must be a positive integer' } });
  });

  it('POST /orders joins multiple item messages with "; " in item order', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [{ bookId: 1, qty: 0 }] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({
      error: {
        code: 'invalid',
        message: 'items[0].bookId is required; items[0].qty must be a positive integer'
      }
    });
  });

  it('POST /orders returns a 422 for an empty items array', async () => {
    const r = await call(ctx, 'POST', '/orders', { items: [] }, { 'x-api-key': 'dev-key' });
    expect(r.status).toBe(422);
    expect(r.json).toEqual({ error: { code: 'invalid', message: 'items must be a non-empty array' } });
  });
});
