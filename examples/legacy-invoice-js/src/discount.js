// Discount codes. A code is either a percentage ("SAVE10") or a fixed amount ("MINUS5").
// Percentage discounts apply to the subtotal; fixed discounts never take the total below zero.

var CODES = {
  SAVE10: { kind: 'percent', value: 10 },
  SAVE25: { kind: 'percent', value: 25, minSubtotal: 100 },
  MINUS5: { kind: 'fixed', value: 5 },
  MINUS50: { kind: 'fixed', value: 50, minSubtotal: 200 }
};

export function lookupCode(code) {
  if (!code) return null;
  return CODES[String(code).trim().toUpperCase()] || null;
}

export function discountAmount(subtotal, code) {
  var d = lookupCode(code);
  if (!d) return 0;
  if (d.minSubtotal && subtotal < d.minSubtotal) return 0;
  if (d.kind === 'percent') return subtotal * d.value / 100;
  return Math.min(d.value, subtotal);
}
