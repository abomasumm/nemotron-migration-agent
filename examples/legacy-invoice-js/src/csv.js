// CSV export of an invoice, for the accounting import. Column order is part of the contract.
import { formatMoney } from './money';

function escape(value) {
  var s = String(value);
  if (/[",\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

export function invoiceToCsv(invoice, currency) {
  var rows = [['sku', 'category', 'qty', 'net']];
  invoice.lines.forEach(function (l) {
    rows.push([l.sku, l.category, l.qty, formatMoney(l.net, currency)]);
  });
  rows.push(['', '', 'subtotal', formatMoney(invoice.subtotal, currency)]);
  if (invoice.discount) rows.push(['', '', 'discount', formatMoney(-invoice.discount, currency)]);
  rows.push(['', '', 'tax', formatMoney(invoice.tax, currency)]);
  rows.push(['', '', 'total', formatMoney(invoice.total, currency)]);
  return rows.map(function (r) { return r.map(escape).join(','); }).join('\n') + '\n';
}
