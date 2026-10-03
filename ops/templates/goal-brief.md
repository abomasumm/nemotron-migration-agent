<one-line summary: what gets built>
Outcome: what a user or the system can do afterwards that it can't today.
Acceptance (testable, 3-6 bullets; name the functions, routes, tables and files involved):
- `functionName(args)` returns ... for ...; tested in `path/to/file.test.ts`.
- `GET /route` responds with ... ; ...
- ...
Scope: files or areas likely touched, INCLUDING test files. Out of scope: ...
Risk: low | high, and why (auth, payments, data model, migrations, shared core = high).
Constraints: libraries to use or avoid, style, performance limits, no new paid services.

<!--
Checklist before queuing (from NOTES.md lessons):
- Every acceptance bullet can be checked by a test or a command, not by reading the code.
- Names in backticks exist in the repo (or the brief says they are new). Check in the step view.
- Scope lists every file the acceptance needs, test files too; out-of-scope files are blocked by the gate.
- Only low or high risk. Anything touching auth, payments, schema or migrations is high.
- One milestone = one goal. If it has more than ~6 acceptance bullets, split it into two goals.
-->
