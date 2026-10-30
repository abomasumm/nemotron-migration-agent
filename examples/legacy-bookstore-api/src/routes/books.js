'use strict';
var express = require('express');
var store = require('../store');
var validate = require('../validate');
var requireKey = require('../auth').requireKey;
var HttpError = require('../errors').HttpError;

var router = express.Router();

// GET /books?author=Fowler&inStock=true&limit=10&offset=0
router.get('/', function (req, res, next) {
  var limit = req.query.limit === undefined ? 20 : parseInt(req.query.limit, 10);
  var offset = req.query.offset === undefined ? 0 : parseInt(req.query.offset, 10);
  if (isNaN(limit) || limit < 1 || limit > 100) return next(new HttpError(400, 'bad_query', 'limit must be 1-100'));
  if (isNaN(offset) || offset < 0) return next(new HttpError(400, 'bad_query', 'offset must be >= 0'));
  store.listBooks({ author: req.query.author, inStock: req.query.inStock === 'true' }, function (err, all) {
    if (err) return next(err);
    res.set('x-total-count', String(all.length));
    res.json({ items: all.slice(offset, offset + limit), total: all.length, limit: limit, offset: offset });
  });
});

router.get('/:id', function (req, res, next) {
  store.getBook(req.params.id, function (err, book) {
    if (err) return next(err);
    if (!book) return next(new HttpError(404, 'not_found', 'Book ' + req.params.id + ' not found'));
    res.json(book);
  });
});

router.post('/', requireKey, function (req, res, next) {
  var errs = validate.bookErrors(req.body);
  if (errs.length) return next(new HttpError(422, 'invalid', errs.join('; ')));
  store.createBook(req.body, function (err, book) {
    if (err) return next(err);
    res.status(201).location('/books/' + book.id).json(book);
  });
});

// PATCH /books/:id/stock  { "delta": -2 }
router.patch('/:id/stock', requireKey, function (req, res, next) {
  var delta = req.body && req.body.delta;
  if (!Number.isInteger(delta)) return next(new HttpError(422, 'invalid', 'delta must be an integer'));
  store.adjustStock(req.params.id, delta, function (err, book) {
    if (err) return next(new HttpError(409, 'conflict', err.message));
    if (!book) return next(new HttpError(404, 'not_found', 'Book ' + req.params.id + ' not found'));
    res.json(book);
  });
});

module.exports = router;
