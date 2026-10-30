// Builds an invoice total from line items.
import { roundMoney, sum } from './money';
import { lineTax } from './tax';
import { discountAmount } from './discount';

export function lineNet(item) {
  var qty = item.qty == null ? 1 : item.qty;
  if (qty < 0) throw new Error('Negative quantity for ' + item.sku);
  return roundMoney(item.price * qty);
}

export function buildInvoice(items, opts) {
  opts = opts || {};
  var region = opts.region || 'US-OR';
  var lines = items.map(function (item) {
    var net = lineNet(item);
    return { sku: item.sku, category: item.category || 'general', qty: item.qty == null ? 1 : item.qty, net: net };
  });
  var subtotal = sum(lines.map(function (l) { return l.net; }));
  var discount = roundMoney(discountAmount(subtotal, opts.code));
  // discount is spread over lines in proportion to their net, so tax is charged on the discounted price
  var ratio = subtotal > 0 ? (subtotal - discount) / subtotal : 0;
  var tax = sum(lines.map(function (l) {
    return roundMoney(lineTax({ net: l.net * ratio, category: l.category }, region, opts));
  }));
  return {
    region: region,
    lines: lines,
    subtotal: subtotal,
    discount: discount,
    tax: tax,
    total: roundMoney(subtotal - discount + tax)
  };
}
