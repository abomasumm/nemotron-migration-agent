'use strict';
// Hand-written validation. Returns an array of messages; empty means valid.

function bookErrors(body) {
  var errs = [];
  if (!body || typeof body !== 'object') return ['body must be an object'];
  if (typeof body.title !== 'string' || !body.title.trim()) errs.push('title is required');
  if (typeof body.author !== 'string' || !body.author.trim()) errs.push('author is required');
  if (typeof body.price !== 'number' || !(body.price > 0)) errs.push('price must be a positive number');
  if (body.stock !== undefined && (!Number.isInteger(body.stock) || body.stock < 0)) errs.push('stock must be a non-negative integer');
  return errs;
}

function orderErrors(body) {
  if (!body || !Array.isArray(body.items) || body.items.length === 0) return ['items must be a non-empty array'];
  var errs = [];
  body.items.forEach(function (it, i) {
    if (!it || typeof it.bookId !== 'string') errs.push('items[' + i + '].bookId is required');
    if (!it || !Number.isInteger(it.qty) || it.qty < 1) errs.push('items[' + i + '].qty must be a positive integer');
  });
  return errs;
}

module.exports = { bookErrors: bookErrors, orderErrors: orderErrors };
