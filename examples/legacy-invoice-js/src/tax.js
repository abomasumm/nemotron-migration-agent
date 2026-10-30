// Sales tax by region. Unknown regions are taxed at 0 unless strict is set.
var RATES = {
  'US-CA': 0.0725,
  'US-NY': 0.04,
  'US-TX': 0.0625,
  'US-OR': 0,
  'DE': 0.19,
  'FR': 0.2,
  'GB': 0.2,
  'JP': 0.1
};

// Some categories are exempt in some regions.
var EXEMPT = {
  'US-NY': ['clothing'],
  'GB': ['books', 'food'],
  'DE': []
};

export function taxRate(region, options) {
  options = options || {};
  if (RATES.hasOwnProperty(region)) return RATES[region];
  if (options.strict) throw new Error('Unknown tax region: ' + region);
  return 0;
}

export function isExempt(region, category) {
  var list = EXEMPT[region];
  if (!list) return false;
  return list.indexOf(category) !== -1;
}

export function lineTax(line, region, options) {
  if (isExempt(region, line.category)) return 0;
  return line.net * taxRate(region, options);
}
