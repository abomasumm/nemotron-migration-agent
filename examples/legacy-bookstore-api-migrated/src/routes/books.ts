import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import * as store from '../store';
import * as validate from '../validate';
import { requireKey } from '../auth';
import { HttpError } from '../errors';

interface BooksQuerystring {
  author?: string;
  inStock?: string;
  limit?: string | string[];
  offset?: string | string[];
}

interface BookParams {
  id: string;
}

async function listBooks(request: FastifyRequest<{ Querystring: BooksQuerystring }>, reply: FastifyReply): Promise<unknown> {
  const limit = request.query.limit === undefined ? 20 : parseInt(String(request.query.limit), 10);
  const offset = request.query.offset === undefined ? 0 : parseInt(String(request.query.offset), 10);
  if (isNaN(limit) || limit < 1 || limit > 100) throw new HttpError(400, 'bad_query', 'limit must be 1-100');
  if (isNaN(offset) || offset < 0) throw new HttpError(400, 'bad_query', 'offset must be >= 0');
  const all = await store.listBooks({ author: request.query.author, inStock: request.query.inStock === 'true' });
  reply.header('x-total-count', String(all.length));
  return { items: all.slice(offset, offset + limit), total: all.length, limit: limit, offset: offset };
}

async function getBook(request: FastifyRequest<{ Params: BookParams }>, _reply: FastifyReply): Promise<unknown> {
  const book = await store.getBook(request.params.id);
  if (!book) throw new HttpError(404, 'not_found', 'Book ' + request.params.id + ' not found');
  return book;
}

async function createBook(request: FastifyRequest, reply: FastifyReply): Promise<unknown> {
  const body = (request.body || {}) as Record<string, unknown>;
  const errs = validate.bookErrors(body);
  if (errs.length) throw new HttpError(422, 'invalid', errs.join('; '));
  const book = await store.createBook(body as unknown as store.NewBook);
  reply.status(201).header('location', '/books/' + book.id);
  return book;
}

async function adjustStock(request: FastifyRequest<{ Params: BookParams }>, _reply: FastifyReply): Promise<unknown> {
  const body = request.body as { delta?: unknown } | null | undefined;
  const delta = body && body.delta;
  if (!Number.isInteger(delta)) throw new HttpError(422, 'invalid', 'delta must be an integer');
  let book: store.Book | null;
  try {
    book = await store.adjustStock(request.params.id, delta as number);
  } catch (err) {
    throw new HttpError(409, 'conflict', (err as Error).message);
  }
  if (!book) throw new HttpError(404, 'not_found', 'Book ' + request.params.id + ' not found');
  return book;
}

export default async function booksRoutes(app: FastifyInstance): Promise<void> {
  // GET /books?author=Fowler&inStock=true&limit=10&offset=0
  app.get<{ Querystring: BooksQuerystring }>('/', listBooks);
  app.get<{ Params: BookParams }>('/:id', getBook);
  app.post('/', { preHandler: requireKey }, createBook);
  // PATCH /books/:id/stock  { "delta": -2 }
  app.patch<{ Params: BookParams }>('/:id/stock', { preHandler: requireKey }, adjustStock);
}
