# legacy-bookstore-api

A bookstore REST API on **Express 4**, written in callback-style CommonJS JavaScript. Fastify is already in
`dependencies`: the team planned to move to Fastify 5 + TypeScript + async/await and never did.
Demo target for the Nemotron migration agent.

Endpoints: `GET /health`, `GET /books` (author, inStock, limit, offset), `GET /books/:id`, `POST /books`,
`PATCH /books/:id/stock`, `POST /orders` (tax, bulk discount, stock reservation), `GET /orders/:id`.
Writes need an `x-api-key` header (`BOOKSTORE_API_KEYS`, default `dev-key`). Errors are always
`{ "error": { "code", "message" } }`.

Tests talk to the server over HTTP through `start()` in `src/server`, so they don't depend on the framework.
Only `GET /books` is tested; orders, auth, validation, stock and error handling have no tests yet.

    npm install
    npm test
    npm run typecheck
