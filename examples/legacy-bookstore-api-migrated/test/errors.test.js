import { describe, it, expect } from 'vitest';
import { HttpError } from '../src/errors';
import { useServer, call } from './helpers';

const ctx = useServer();

describe('HttpError', () => {
  it('classifies as HttpError and Error with status, code and message', () => {
    const err = new HttpError(400, 'bad_query', 'x');
    expect(err instanceof HttpError).toBe(true);
    expect(err instanceof Error).toBe(true);
    expect(err.status).toBe(400);
    expect(err.code).toBe('bad_query');
    expect(err.message).toBe('x');
  });
});

describe('error envelope over HTTP', () => {
  it('404s unknown routes with the not_found envelope', async () => {
    const r = await call(ctx, 'GET', '/nope');
    expect(r.status).toBe(404);
    expect(r.json).toEqual({ error: { code: 'not_found', message: 'No route for GET /nope' } });
  });

  it('rejects malformed JSON bodies with the bad_json envelope', async () => {
    const r = await call(ctx, 'POST', '/books', '{');
    expect(r.status).toBe(400);
    expect(r.json).toEqual({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });
  });
});
