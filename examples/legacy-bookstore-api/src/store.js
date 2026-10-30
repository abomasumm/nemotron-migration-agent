// In-memory data store with a callback API (it used to wrap a database driver with the same shape).
// Every function calls back asynchronously: cb(err, result).
'use strict';

var books = {};
var orders = {};
var nextBookId = 1;
var nextOrderId = 1000;

function later(cb, err, value) {
  setImmediate(function () { cb(err, value); });
}

function reset() {
  books = {};
  orders = {};
  nextBookId = 1;
  nextOrderId = 1000;
  [
    { title: 'The Pragmatic Programmer', author: 'Hunt', price: 42.5, stock: 7 },
    { title: 'Refactoring', author: 'Fowler', price: 47.99, stock: 3 },
    { title: 'Working Effectively with Legacy Code', author: 'Feathers', price: 54, stock: 0 },
    { title: 'Patterns of Enterprise Application Architecture', author: 'Fowler', price: 59.95, stock: 12 }
  ].forEach(function (b) { var id = String(nextBookId++); books[id] = Object.assign({ id: id }, b); });
}

function listBooks(filter, cb) {
  var all = Object.keys(books).map(function (k) { return books[k]; });
  if (filter.author) {
    var a = filter.author.toLowerCase();
    all = all.filter(function (b) { return b.author.toLowerCase() === a; });
  }
  if (filter.inStock) all = all.filter(function (b) { return b.stock > 0; });
  later(cb, null, all);
}

function getBook(id, cb) {
  later(cb, null, books[id] || null);
}

function createBook(data, cb) {
  var id = String(nextBookId++);
  books[id] = { id: id, title: data.title, author: data.author, price: data.price, stock: data.stock || 0 };
  later(cb, null, books[id]);
}

function adjustStock(id, delta, cb) {
  var b = books[id];
  if (!b) return later(cb, null, null);
  if (b.stock + delta < 0) return later(cb, new Error('insufficient stock'));
  b.stock += delta;
  later(cb, null, b);
}

function saveOrder(order, cb) {
  var id = 'ORD-' + nextOrderId++;
  orders[id] = Object.assign({ id: id, createdAt: '2024-01-01T00:00:00.000Z' }, order);
  later(cb, null, orders[id]);
}

function getOrder(id, cb) {
  later(cb, null, orders[id] || null);
}

reset();
module.exports = { reset: reset, listBooks: listBooks, getBook: getBook, createBook: createBook, adjustStock: adjustStock, saveOrder: saveOrder, getOrder: getOrder };
