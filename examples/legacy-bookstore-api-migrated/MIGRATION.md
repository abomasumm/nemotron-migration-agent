# Migration plan
<!-- Written by .agents/migrate.sh init on 2026-10-30 16:51:12. Edit freely: the planner and every worker read this file. -->

## Migration
- From: JavaScript (CommonJS)
- To: Fastify 5 + TypeScript (strict) + async/await, ES modules

## Scope
In scope:
- src/
Never touch:
- existing tests
- package.json and lockfile
- build and tool config

## Behaviour that must not change
- After store.reset(), GET /books?limit=1&offset=1 returns x-total-count 4 and the body {"items":[{"id":"2","title":"Refactoring","author":"Fowler","price":47.99,"stock":3}],"total":4,"limit":1,"offset":1}
- After store.reset(), GET /books?author=fowler returns x-total-count 2 and a body whose items have ids 2 and 4 with total 2, limit 20, and offset 0
- GET /books?limit=0 returns status 400 and exactly {"error":{"code":"bad_query","message":"limit must be 1-100"}}
- GET /books/999 returns status 404 and exactly {"error":{"code":"not_found","message":"Book 999 not found"}}
- POST /books without x-api-key returns status 401 and exactly {"error":{"code":"unauthorized","message":"Missing x-api-key header"}}, while an invalid key returns status 403 and exactly {"error":{"code":"forbidden","message":"Invalid API key"}}
- POST /orders with x-api-key dev-key and one item for bookId 4 with qty 10 returns status 201 with id ORD-1000, createdAt 2024-01-01T00:00:00.000Z, subtotal 599.5, discount 29.98, tax 45.56, and total 615.08

## Rules
- New dependencies allowed: no
- Public API changes allowed: no
- Tests: existing tests are never edited. Untested modules get characterization tests first (pin tasks).
- One module per migrate task, in the dependency order below.

## Approach
- Phase 1, framework-independent modules one at a time, leaves first: `src/errors.js`, `src/validate.js`, `src/store.js` become TypeScript ES modules. `store` switches from callbacks to async functions returning Promises (same names, same results); its callers are updated in the same task so everything keeps working.
- Phase 2, one task: switch Express to Fastify 5 for `src/auth.js`, `src/routes/books.js`, `src/routes/orders.js`, `src/app.js`, `src/server.js` and `src/index.js` together, in TypeScript with async/await handlers. Express cannot run half-migrated, so these move as one change.
- The HTTP contract is the boundary: every route, status code, header (`x-total-count`, `x-request-id`, `location`), JSON body and error format `{ "error": { "code", "message" } }` stays identical, including 404s for unknown routes and 400 `bad_json` for malformed JSON.
- `start(port)` in `src/server` keeps returning a Promise of `{ url, close() }`; `reset` stays exported from `src/store`. The tests use only these.
- After phase 2, Express is no longer imported anywhere (it stays in package.json; removing it is a separate change).

## Done when
- no JavaScript source files left in scope
- all tests and the typecheck pass

## Commands
- test: `npm test`
- typecheck: `npm run typecheck`
- Baseline on 2026-10-30: green

## Modules (dependency order: migrate from the top)
| Module | Lines | Imports | Imported by | Tests | Risk |
|---|---|---|---|---|---|
| `src/errors.js` | 26 |  | 4 | none | no tests, imported by 4 modules |
| `src/auth.js` | 16 | errors.js | 2 | none | no tests, critical |
| `src/store.js` | 66 |  | 2 | test/books.test.js, test/helpers.js |  |
| `src/validate.js` | 24 |  | 2 | none | no tests |
| `src/routes/books.js` | 51 | auth.js, errors.js, store.js, validate.js | 1 | none | no tests |
| `src/routes/orders.js` | 66 | auth.js, errors.js, store.js, validate.js | 1 | none | no tests, critical |
| `src/app.js` | 23 | errors.js, books.js, orders.js | 1 | none | no tests |
| `src/server.js` | 18 | app.js | 1 | test/books.test.js, test/helpers.js |  |
| `src/index.js` | 3 | server.js | 0 | none | no tests |

## Existing tests (what they already cover)
- `test/books.test.js`: GET /books; lists books with paging metadata and a total-count header; filters by author, case-insensitively; rejects a bad limit; GET /books/:id; returns one book; 404s with the API error format

## Notes from Nemotron Nano
- src/errors.js uses a custom HttpError prototype and errorHandler depends on instanceof HttpError, so a TypeScript class rewrite must preserve status, code, message, and error classification
- The shown src/store.js and src/routes/orders.js excerpts are incomplete, and getOrder is referenced by src/routes/orders.js, so confirm the full exports before changing module types
- The limit and offset parsing accepts partially numeric strings such as 10abc through parseInt, which can be surprising but is observable behavior
- Order pricing depends on two-decimal rounding, a quantity threshold of 10 for the 5 percent discount, and an 8 percent tax calculated after the discount
- src/store.js createBook uses data.stock || 0, so undefined, null, and zero stocks all become zero
