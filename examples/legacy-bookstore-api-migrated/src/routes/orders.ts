import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import * as store from '../store';
import * as validate from '../validate';
import { requireKey } from '../auth';
import { HttpError } from '../errors';

const TAX_RATE = 0.08;
const BULK_QTY = 10; // 10 or more items in one order: 5% off the subtotal
const BULK_DISCOUNT = 0.05;

interface OrderItem {
  bookId: string;
  qty: number;
}

interface OrderParams {
  id: string;
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

// POST /orders { "items": [{ "bookId": "1", "qty": 2 }] }
async function createOrder(request: FastifyRequest, reply: FastifyReply): Promise<unknown> {
  const body = (request.body || {}) as { items?: OrderItem[] };
  const errs = validate.orderErrors(body);
  if (errs.length) throw new HttpError(422, 'invalid', errs.join('; '));
  const items = body.items as OrderItem[];
  const lines: store.OrderLine[] = [];

  // look up every book first, then reserve stock line by line (matching the old driver order)
  for (const it of items) {
    const book = await store.getBook(it.bookId);
    if (!book) throw new HttpError(422, 'invalid', 'Unknown book ' + it.bookId);
    if (book.stock < it.qty) throw new HttpError(409, 'out_of_stock', 'Only ' + book.stock + ' left of ' + book.title);
    lines.push({ bookId: book.id, title: book.title, qty: it.qty, unitPrice: book.price, lineTotal: round2(book.price * it.qty) });
  }

  for (const line of lines) {
    try {
      await store.adjustStock(line.bookId, -line.qty);
    } catch (err) {
      throw new HttpError(409, 'out_of_stock', (err as Error).message);
    }
  }

  const qty = lines.reduce((s, l) => s + l.qty, 0);
  const subtotal = round2(lines.reduce((s, l) => s + l.lineTotal, 0));
  const discount = qty >= BULK_QTY ? round2(subtotal * BULK_DISCOUNT) : 0;
  const tax = round2((subtotal - discount) * TAX_RATE);
  const order = await store.saveOrder({ lines: lines, subtotal: subtotal, discount: discount, tax: tax, total: round2(subtotal - discount + tax) });
  reply.status(201).header('location', '/orders/' + order.id);
  return order;
}

async function getOrder(request: FastifyRequest<{ Params: OrderParams }>, _reply: FastifyReply): Promise<unknown> {
  const order = await store.getOrder(request.params.id);
  if (!order) throw new HttpError(404, 'not_found', 'Order ' + request.params.id + ' not found');
  return order;
}

export default async function ordersRoutes(app: FastifyInstance): Promise<void> {
  app.post('/', { preHandler: requireKey }, createOrder);
  app.get<{ Params: OrderParams }>('/:id', { preHandler: requireKey }, getOrder);
}
