patch: Small, precise change. Keep the diff minimal.
feature: New behaviour across a few files. Keep functions small and typed.
debug: Find the root cause before changing code. A failing test reproduces the bug; make it pass without weakening it.
ui: Follow the existing design system and components. Keep markup accessible (labels, contrast, keyboard use).
data: Keep transforms deterministic and idempotent. Never hard-code credentials or read real data files.
bulk: Mechanical change applied consistently everywhere listed. No behaviour changes.
long: Multi-step task. Work in small steps and keep the code building after each one.
pin: Write characterization tests ONLY, in the project's test folder and framework: tests that pin what the listed code does TODAY, including odd results, rounding and error messages. Never change source code, never "fix" a bug you find; pin it and mention it in your summary. If the brief describes behaviour the code does not have, pin what the code actually does and say so in your summary. Run the tests: every one must pass on the current code.
migrate: Convert the listed files as MIGRATION.md describes, without changing behaviour. Keep import paths in their existing style (never add a .ts extension to an import). Never edit, rename or delete a test file: the existing tests must keep passing as they are. Keep exported names and signatures. Run the tests and the typecheck before you finish.
