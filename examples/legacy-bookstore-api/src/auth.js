'use strict';
// Write endpoints need the x-api-key header. Keys come from the BOOKSTORE_API_KEYS env var (comma separated).
var HttpError = require('./errors').HttpError;

function keys() {
  return (process.env.BOOKSTORE_API_KEYS || 'dev-key').split(',').map(function (k) { return k.trim(); });
}

function requireKey(req, res, next) {
  var key = req.get('x-api-key');
  if (!key) return next(new HttpError(401, 'unauthorized', 'Missing x-api-key header'));
  if (keys().indexOf(key) === -1) return next(new HttpError(403, 'forbidden', 'Invalid API key'));
  next();
}

module.exports = { requireKey: requireKey };
