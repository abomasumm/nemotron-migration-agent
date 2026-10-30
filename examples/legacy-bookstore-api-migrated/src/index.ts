import { start } from './server';

start(Number(process.env.PORT) || 3000).then(function (s) {
  console.log('bookstore api on ' + s.url);
});
