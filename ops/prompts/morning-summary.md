Morning summary (scheduled, read-only). Write it for the owner, who reads it on a phone in two minutes.

1. Run `./kitctl overview`. For any repo with a task in `needs-you`, run `./kitctl <repo> show <id>`.
   For any repo whose overview says the main checkout has uncommitted changes, run `./kitctl <repo> dirty`.
2. Run `./kitctl <repo> log fallbacks 40` for each repo, and look for pool pauses since yesterday 18:00.
3. Write `digests/YYYY-MM-DD.md` (today's date) with these sections, skipping any that are empty:
   - **Needs you**: each `needs-you` task: repo, id, title, what went wrong in one sentence, and a proposed
     hint the owner could approve ("say: requeue <repo> <id> with this hint").
   - **Waiting on sign-off**: tasks in `needs-approval` (Claude signs these off; only list them).
   - **Finished**: goals that reached `done` since yesterday, with a reminder to merge `agents` into main.
   - **Problems**: loops that look stopped (last active over 15 minutes ago), pool pauses, any uncommitted
     change in a main checkout (list the files; the pipeline itself never leaves these, so ask about them).
   - **Usage**: one line per repo from the overview's "Calls today" line.
4. Do not run any command that changes anything: no `goal`, `requeue` or `park`, and no file other than
   the digest. If kitctl refuses a command, say so in the digest instead of working around it.
