// In-memory data store. Operations are asynchronous and return Promises; reset() is synchronous.

export interface Book {
  id: string;
  title: string;
  author: string;
  price: number;
  stock: number;
}

export interface NewBook {
  title: string;
  author: string;
  price: number;
  stock?: number | null;
}

export interface BookFilter {
  author?: string;
  inStock?: boolean;
}

export interface OrderLine {
  bookId: string;
  title: string;
  qty: number;
  unitPrice: number;
  lineTotal: number;
}

export interface NewOrder {
  lines: OrderLine[];
  subtotal: number;
  discount: number;
  tax: number;
  total: number;
}

export interface Order extends NewOrder {
  id: string;
  createdAt: string;
}

let books: Record<string, Book> = {};
let orders: Record<string, Order> = {};
let nextBookId = 1;
let nextOrderId = 1000;

export function reset(): void {
  books = {};
  orders = {};
  nextBookId = 1;
  nextOrderId = 1000;
  const seed: Array<Omit<Book, 'id'>> = [
    { title: 'The Pragmatic Programmer', author: 'Hunt', price: 42.5, stock: 7 },
    { title: 'Refactoring', author: 'Fowler', price: 47.99, stock: 3 },
    { title: 'Working Effectively with Legacy Code', author: 'Feathers', price: 54, stock: 0 },
    { title: 'Patterns of Enterprise Application Architecture', author: 'Fowler', price: 59.95, stock: 12 }
  ];
  for (const b of seed) {
    const id = String(nextBookId++);
    books[id] = { id, ...b };
  }
}

export async function listBooks(filter: BookFilter): Promise<Book[]> {
  let all = Object.keys(books).map((k) => books[k]);
  if (filter.author) {
    const a = filter.author.toLowerCase();
    all = all.filter((b) => b.author.toLowerCase() === a);
  }
  if (filter.inStock) all = all.filter((b) => b.stock > 0);
  return all;
}

export async function getBook(id: string): Promise<Book | null> {
  return books[id] || null;
}

export async function createBook(data: NewBook): Promise<Book> {
  const id = String(nextBookId++);
  books[id] = { id, title: data.title, author: data.author, price: data.price, stock: data.stock || 0 };
  return books[id];
}

export async function adjustStock(id: string, delta: number): Promise<Book | null> {
  const b = books[id];
  if (!b) return null;
  if (b.stock + delta < 0) throw new Error('insufficient stock');
  b.stock += delta;
  return b;
}

export async function saveOrder(order: NewOrder): Promise<Order> {
  const id = 'ORD-' + nextOrderId++;
  orders[id] = { id, createdAt: '2024-01-01T00:00:00.000Z', ...order };
  return orders[id];
}

export async function getOrder(id: string): Promise<Order | null> {
  return orders[id] || null;
}

reset();
