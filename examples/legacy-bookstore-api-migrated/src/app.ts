import Fastify, { type FastifyInstance, type FastifyReply, type FastifyRequest } from 'fastify';
import { HttpError } from './errors';
import booksRoutes from './routes/books';
import ordersRoutes from './routes/orders';

const BODY_LIMIT = 100 * 1024;

let requestCounter = 0;

interface ParseFailedError {
  type?: unknown;
  code?: unknown;
}

function isParseFailedError(err: unknown): err is ParseFailedError {
  if (typeof err !== 'object' || err === null) return false;
  const candidate = err as ParseFailedError;
  return candidate.type === 'entity.parse.failed' || candidate.code === 'FST_ERR_CTP_INVALID_JSON_BODY';
}

function parseFailedError(): Error {
  const err = new Error('Request body is not valid JSON') as Error & { type: string };
  err.type = 'entity.parse.failed';
  return err;
}

function requestPath(url: string): string {
  const queryIndex = url.indexOf('?');
  return queryIndex === -1 ? url : url.slice(0, queryIndex);
}

export function createApp(): FastifyInstance {
  const app = Fastify({
    bodyLimit: BODY_LIMIT,
    routerOptions: { ignoreTrailingSlash: true },
    logger: false
  });

  app.removeAllContentTypeParsers();
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (_request, body, done) => {
    const text = typeof body === 'string' ? body : body.toString('utf8');
    if (text.length === 0) {
      done(null, {});
      return;
    }
    const first = text.match(/\S/);
    if (!first || (first[0] !== '{' && first[0] !== '[')) {
      done(parseFailedError(), undefined);
      return;
    }
    try {
      done(null, JSON.parse(text));
    } catch {
      done(parseFailedError(), undefined);
    }
  });
  // Express only parsed application/json; any other content type was treated as an empty body.
  app.addContentTypeParser('*', { parseAs: 'string' }, (_request, _body, done) => {
    done(null, {});
  });

  app.addHook('onRequest', async (request: FastifyRequest, reply: FastifyReply) => {
    const supplied = request.headers['x-request-id'];
    const value = Array.isArray(supplied) ? supplied[0] : supplied;
    reply.header('x-request-id', value || 'req-' + ++requestCounter);
  });

  app.get('/health', async () => ({ status: 'ok' }));

  app.register(booksRoutes, { prefix: '/books' });
  app.register(ordersRoutes, { prefix: '/orders' });

  app.setNotFoundHandler((request, reply) => {
    reply.status(404).send({
      error: { code: 'not_found', message: 'No route for ' + request.method + ' ' + requestPath(request.url) }
    });
  });

  app.setErrorHandler((err, _request, reply) => {
    if (err instanceof HttpError) {
      reply.status(err.status).send({ error: { code: err.code, message: err.message } });
      return;
    }
    if (isParseFailedError(err)) {
      reply.status(400).send({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });
      return;
    }
    reply.status(500).send({ error: { code: 'internal', message: 'Something went wrong' } });
  });

  return app;
}
