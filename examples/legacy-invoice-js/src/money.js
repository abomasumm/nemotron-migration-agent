// Money helpers. Amounts are plain numbers in the invoice currency.

export function roundMoney(amount) {
  // round half away from zero, to cents
  var sign = amount < 0 ? -1 : 1;
  return sign * Math.round(Math.abs(amount) * 100 + Number.EPSILON) / 100;
}

export function formatMoney(amount, currency) {
  if (currency === undefined) currency = 'USD';
  var symbols = { USD: '$', EUR: '€', GBP: '£', JPY: '¥' };
  var symbol = symbols[currency] || currency + ' ';
  var decimals = currency === 'JPY' ? 0 : 2;
  var fixed = Math.abs(roundMoney(amount)).toFixed(decimals);
  var parts = fixed.split('.');
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  var out = symbol + parts.join('.');
  return amount < 0 ? '-' + out : out;
}

export function sum(amounts) {
  var total = 0;
  for (var i = 0; i < amounts.length; i++) total += amounts[i];
  return roundMoney(total);
}
