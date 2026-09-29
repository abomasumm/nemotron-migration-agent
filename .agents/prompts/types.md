patch: Small, precise change. Keep the diff minimal.
feature: New behaviour across a few files. Keep functions small and typed.
debug: Find the root cause before changing code. A failing test reproduces the bug; make it pass without weakening it.
ui: Follow the existing design system and components. Keep markup accessible (labels, contrast, keyboard use).
data: Keep transforms deterministic and idempotent. Never hard-code credentials or read real data files.
bulk: Mechanical change applied consistently everywhere listed. No behaviour changes.
long: Multi-step task. Work in small steps and keep the code building after each one.
