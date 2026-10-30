'use strict';
// One error format for the whole API: { "error": { "code": "...", "message": "..." } }

function HttpError(status, code, message) {
  this.status = status;
  this.code = code;
  this.message = message;
}
HttpError.prototype = Object.create(Error.prototype);

function notFound(req, res) {
  res.status(404).json({ error: { code: 'not_found', message: 'No route for ' + req.method + ' ' + req.path } });
}

// eslint-disable-next-line no-unused-vars
function errorHandler(err, req, res, next) {
  if (err instanceof HttpError) {
    return res.status(err.status).json({ error: { code: err.code, message: err.message } });
  }
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: { code: 'bad_json', message: 'Request body is not valid JSON' } });
  }
  res.status(500).json({ error: { code: 'internal', message: 'Something went wrong' } });
}

module.exports = { HttpError: HttpError, notFound: notFound, errorHandler: errorHandler };
