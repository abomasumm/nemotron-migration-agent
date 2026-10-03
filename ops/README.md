# ops: the control desk for DeepSeek Harness (dsh)

A folder outside every repo where dsh works: it drafts briefs here and acts on pipelines only through
`kitctl`, a wrapper that allows a short list of kit commands and logs each call. The pipelines never depend
on it: everything kitctl does, you can do by hand in the repo.

## Install (once)
```bash
cp -Rn ~/Documents/GitHub/agent-pipeline-kit/ops ~/code/ops     # any folder outside your repos
cd ~/code/ops && cp repos.txt.example repos.txt                 # then edit: one "<name> <path>" per repo
./kitctl repos && ./kitctl overview                             # check it can see each repo
```
To update kitctl later: `cp ~/Documents/GitHub/agent-pipeline-kit/ops/kitctl ~/code/ops/` (repos.txt,
briefs and logs are yours and never overwritten).

## dsh setup
- Workspace `~/code/ops` with **workspace-write**. dsh reads `AGENTS.md` here: its rules.
- Each repo as its own **read-only** workspace, for drafting briefs. Never full access; avoid the minimal profile.
- Custom provider: 9router at `http://127.0.0.1:20128/v1`, protocol `openai-completions`, DeepSeek V4.1 Flash on `cmc/`.

**Test before trusting it:**
1. In dsh: "queue briefs/test.md as a goal for mentora" with a throwaway brief. Check `kitctl.log`.
2. Ask dsh to edit a file in a repo. It must refuse, or the sandbox must block it.
3. Ask dsh to approve a task. kitctl must refuse.
4. If the sandbox blocks kitctl writing the goal file into the repo, widen the ops workspace to the parent
   of your repos and rely on kitctl plus the morning summary's uncommitted-change check.

## Scheduled reports (dsh scheduled tasks; they only run while dsh runs)
- Weekdays 08:45: "Follow prompts/morning-summary.md" -> `digests/YYYY-MM-DD.md`
- Mondays 09:00: "Follow prompts/routing-report.md" -> `digests/routing-YYYY-MM-DD.md`

## What kitctl allows
| Any time | Only when you say so | Never |
|---|---|---|
| `repos`, `overview`, `status`, `show`, `goals`, `events`, `today`, `stats`, `log`, `note`, `dirty` | `goal`, `goal --file briefs/…`, `requeue` and `park` (needs-you tasks only) | `approve`, `reject`, `escalate`, `drop`, `wake`, `planned`, `done`, `task`, `run`, git, editing files |

Read `kitctl.log` weekly: it's the record of everything done through kitctl.
