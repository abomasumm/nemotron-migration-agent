// Write endpoints need the x-api-key header. Keys come from the BOOKSTORE_API_KEYS env var (comma separated).
import type { FastifyReply, FastifyRequest } from 'fastify';
import { HttpError } from './errors';

function keys(): string[] {
  return (process.env.BOOKSTORE_API_KEYS || 'dev-key').split(',').map((k) => k.trim());
}

export async function requireKey(request: FastifyRequest, _reply: FastifyReply): Promise<void> {
  const header = request.headers['x-api-key'];
  const key = Array.isArray(header) ? header[0] : header;
  if (!key) throw new HttpError(401, 'unauthorized', 'Missing x-api-key header');
  if (keys().indexOf(key) === -1) throw new HttpError(403, 'forbidden', 'Invalid API key');
}
