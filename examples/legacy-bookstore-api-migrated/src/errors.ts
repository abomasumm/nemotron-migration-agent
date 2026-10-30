// One error format for the whole API: { "error": { "code": "...", "message": "..." } }

export class HttpError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

interface RequestLike {
  method: string;
  path: string;
}

interface ResponseLike {
  status(code: number): ResponseLike;
  json(body: unknown): unknown;
}

type NextFunction = (err?: unknown) => void;

interface ParseFailedError {
  type: string;
}

function isParseFailedError(err: unknown): err is ParseFailedError {
  return typeof err === 'object' && err !== null && 'type' in err && (err as ParseFailedError).type === 'entity.parse.failed';
}

export function notFound(req: RequestLike, res: ResponseLike): void {
  res.status(404).json({ error: { code: 'not_found', message: 'No route for ' + req.method + ' ' + req.path } });
}

export function errorHandler(err: unknown, _req: RequestLike, res: ResponseLike, _next: NextFunction): void {
  if (err instanceof HttpError) {
    res.status(err.status).json({ error: { code: err.code, message: err.message } });
    return;
  }
  if (isParseFailedError(err)) {
    res.status(400).json({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });
    return;
  }
  res.status(500).json({ error: { code: 'internal', message: 'Something went wrong' } });
}
