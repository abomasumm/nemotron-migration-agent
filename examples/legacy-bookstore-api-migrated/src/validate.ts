// Hand-written validation. Returns an array of messages; empty means valid.

interface Fields {
  [key: string]: unknown;
}

function isRecord(value: unknown): value is Fields {
  return typeof value === 'object' && value !== null;
}

function isUnknownArray(value: unknown): value is unknown[] {
  return Array.isArray(value);
}

export function bookErrors(body: unknown): string[] {
  if (!isRecord(body)) return ['body must be an object'];

  const errs: string[] = [];
  const title = body.title;
  const author = body.author;
  const price = body.price;
  const stock = body.stock;

  if (typeof title !== 'string' || !title.trim()) errs.push('title is required');
  if (typeof author !== 'string' || !author.trim()) errs.push('author is required');
  if (typeof price !== 'number' || !(price > 0)) errs.push('price must be a positive number');
  if (stock !== undefined && (typeof stock !== 'number' || !Number.isInteger(stock) || stock < 0)) {
    errs.push('stock must be a non-negative integer');
  }
  return errs;
}

export function orderErrors(body: unknown): string[] {
  if (!isRecord(body) || !isUnknownArray(body.items) || body.items.length === 0) {
    return ['items must be a non-empty array'];
  }

  const errs: string[] = [];
  body.items.forEach((it, i) => {
    const item = isRecord(it) ? it : undefined;
    if (typeof item?.bookId !== 'string') {
      errs.push('items[' + i + '].bookId is required');
    }
    const qty = item?.qty;
    if (typeof qty !== 'number' || !Number.isInteger(qty) || qty < 1) {
      errs.push('items[' + i + '].qty must be a positive integer');
    }
  });
  return errs;
}
