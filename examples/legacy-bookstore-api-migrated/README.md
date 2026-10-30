# legacy-bookstore-api, after the migration

This is [`../legacy-bookstore-api`](../legacy-bookstore-api) after one run of the migration agent: Express 4 with
callbacks in CommonJS became **Fastify 5 + TypeScript (strict) + async/await**. Compare the two folders side by
side.

- 9 of 9 modules migrated (`src/*.ts`), no Express imports, no callbacks left in `src/store.ts`.
- The 5 original tests in `test/books.test.js` are unchanged; 7 pin tasks added 95 characterization tests
  first. All 100 pass on the old code and on this one.
- 11 tasks, 37 model calls, about 34 minutes. The plan the agent followed is [`MIGRATION.md`](MIGRATION.md).
- Left for a human, as the agent noted when it closed the migration: `package.json` was out of scope, so it
  still lists `express` and `main: src/index.js`.

---

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
