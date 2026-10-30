'use strict';
var express = require('express');
var errors = require('./errors');

var requestCounter = 0;

function createApp() {
  var app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '100kb' }));
  app.use(function (req, res, next) {
    res.set('x-request-id', req.get('x-request-id') || 'req-' + (++requestCounter));
    next();
  });
  app.get('/health', function (req, res) { res.json({ status: 'ok' }); });
  app.use('/books', require('./routes/books'));
  app.use('/orders', require('./routes/orders'));
  app.use(errors.notFound);
  app.use(errors.errorHandler);
  return app;
}

module.exports = { createApp: createApp };
