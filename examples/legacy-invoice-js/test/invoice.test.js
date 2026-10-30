import { describe, it, expect } from 'vitest';
import { buildInvoice, lineNet } from '../src/invoice';

describe('invoice', () => {
  it('computes line net with default quantity', () => {
    expect(lineNet({ sku: 'A', price: 9.99 })).toBe(9.99);
    expect(lineNet({ sku: 'A', price: 9.99, qty: 3 })).toBe(29.97);
  });
  it('rejects negative quantities', () => {
    expect(() => lineNet({ sku: 'A', price: 1, qty: -1 })).toThrow('Negative quantity for A');
  });
  it('builds a California invoice with a percent discount', () => {
    const inv = buildInvoice(
      [{ sku: 'BOOK', price: 20, qty: 2 }, { sku: 'PEN', price: 2.5, qty: 4 }],
      { region: 'US-CA', code: 'save10' }
    );
    expect(inv.subtotal).toBe(50);
    expect(inv.discount).toBe(5);
    expect(inv.tax).toBe(3.26);
    expect(inv.total).toBe(48.26);
  });
});
