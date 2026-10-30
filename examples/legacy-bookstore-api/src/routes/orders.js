'use strict';
var express = require('express');
var store = require('../store');
var validate = require('../validate');
var requireKey = require('../auth').requireKey;
var HttpError = require('../errors').HttpError;

var router = express.Router();
var TAX_RATE = 0.08;
var BULK_QTY = 10;        // 10 or more items in one order: 5% off the subtotal
var BULK_DISCOUNT = 0.05;

function round2(n) { return Math.round(n * 100) / 100; }

// POST /orders { "items": [{ "bookId": "1", "qty": 2 }] }
router.post('/', requireKey, function (req, res, next) {
  var errs = validate.orderErrors(req.body);
  if (errs.length) return next(new HttpError(422, 'invalid', errs.join('; ')));
  var items = req.body.items;
  var lines = [];
  var i = 0;

  // look up every book first (one callback at a time, the way the old driver required)
  (function lookup() {
    if (i === items.length) return reserve(0);
    var it = items[i];
    store.getBook(it.bookId, function (err, book) {
      if (err) return next(err);
      if (!book) return next(new HttpError(422, 'invalid', 'Unknown book ' + it.bookId));
      if (book.stock < it.qty) return next(new HttpError(409, 'out_of_stock', 'Only ' + book.stock + ' left of ' + book.title));
      lines.push({ bookId: book.id, title: book.title, qty: it.qty, unitPrice: book.price, lineTotal: round2(book.price * it.qty) });
      i++;
      lookup();
    });
  })();

  function reserve(j) {
    if (j === lines.length) return save();
    store.adjustStock(lines[j].bookId, -lines[j].qty, function (err) {
      if (err) return next(new HttpError(409, 'out_of_stock', err.message));
      reserve(j + 1);
    });
  }

  function save() {
    var qty = lines.reduce(function (s, l) { return s + l.qty; }, 0);
    var subtotal = round2(lines.reduce(function (s, l) { return s + l.lineTotal; }, 0));
    var discount = qty >= BULK_QTY ? round2(subtotal * BULK_DISCOUNT) : 0;
    var tax = round2((subtotal - discount) * TAX_RATE);
    store.saveOrder({ lines: lines, subtotal: subtotal, discount: discount, tax: tax, total: round2(subtotal - discount + tax) },
      function (err, order) {
        if (err) return next(err);
        res.status(201).location('/orders/' + order.id).json(order);
      });
  }
});

router.get('/:id', requireKey, function (req, res, next) {
  store.getOrder(req.params.id, function (err, order) {
    if (err) return next(err);
    if (!order) return next(new HttpError(404, 'not_found', 'Order ' + req.params.id + ' not found'));
    res.json(order);
  });
});

module.exports = router;
