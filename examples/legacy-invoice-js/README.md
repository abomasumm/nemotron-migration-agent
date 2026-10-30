# legacy-invoice-js

Invoice totals, sales tax, discount codes and CSV export, written in old-style JavaScript (var, function
expressions, no types). Demo target for the Nemotron migration agent: migrate it to TypeScript without
changing behaviour.

Only `money` and `invoice` have tests; `tax`, `discount` and `csv` have none yet.

    npm install
    npm test
    npm run typecheck
