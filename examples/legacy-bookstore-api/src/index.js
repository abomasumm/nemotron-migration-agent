'use strict';
var start = require('./server').start;
start(Number(process.env.PORT) || 3000).then(function (s) { console.log('bookstore api on ' + s.url); });
