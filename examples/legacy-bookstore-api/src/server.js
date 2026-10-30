'use strict';
// The stable boundary: start(port) -> Promise<{ url, close() }>. Tests and the CLI only use this.
var createApp = require('./app').createApp;

function start(port) {
  return new Promise(function (resolve, reject) {
    var server = createApp().listen(port || 0, '127.0.0.1', function () {
      var addr = server.address();
      resolve({
        url: 'http://127.0.0.1:' + addr.port,
        close: function () { return new Promise(function (r) { server.close(function () { r(); }); }); }
      });
    });
    server.on('error', reject);
  });
}

module.exports = { start: start };
