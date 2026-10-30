import { describe, it, expect } from 'vitest';
import { roundMoney, formatMoney, sum } from '../src/money';

describe('money', () => {
  it('rounds half away from zero', () => {
    expect(roundMoney(0.125)).toBe(0.13);
    expect(roundMoney(-0.125)).toBe(-0.13);
    expect(roundMoney(2.344)).toBe(2.34);
  });
  it('formats with symbol and thousands separators', () => {
    expect(formatMoney(1234567.5)).toBe('$1,234,567.50');
    expect(formatMoney(-12.3, 'EUR')).toBe('-€12.30');
    expect(formatMoney(1500, 'JPY')).toBe('¥1,500');
    expect(formatMoney(3, 'CHF')).toBe('CHF 3.00');
  });
  it('sums and rounds', () => {
    expect(sum([0.1, 0.2])).toBe(0.3);
    expect(sum([])).toBe(0);
  });
});
