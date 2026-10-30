"""dashboard.py: read-only dashboard over the pipeline's state files. Standard library only.

    python3 .agents/dashboard.py [--port 8765]     serve it live at http://127.0.0.1:8765 (refreshes itself)
    python3 .agents/dashboard.py --export DIR      write a static snapshot (index.html, state.json, diffs/)
                                                   for GitHub Pages or any static host
    python3 .agents/dashboard.py --json | --diff T-001   print the state or one task's diff (the web app uses these)

Reads goals, tasks, MIGRATION.md, logs/runs.csv and logs/orchestrator.log. Never writes to the repo.
"""
import csv
import http.server
import json
import os
import re
import subprocess
import sys
import urllib.parse

AG = os.path.dirname(os.path.abspath(__file__))
ROOT = subprocess.run(["git", "-C", AG, "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()
TASKS, GOALS, LOGS = (os.path.join(AG, d) for d in ("tasks", "goals", "logs"))
OUTCOMES = ("gate-pass", "gate-fail", "b2win", "b2loss", "flaky")


def read(path, limit=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(limit) if limit else fh.read()
    except OSError:
        return ""


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], capture_output=True, text=True).stdout


def settings():
    """Model per role and branch names, as routing.sh (plus local.sh) resolves them."""
    keys = "ORCH_MODEL M_NEMO M_DS M_MM M_GLM ESC_MODEL INTEGRATION_BRANCH MAIN_BRANCH PROFILE"
    script = 'source "%s/lib.sh" >/dev/null 2>&1 || exit 1; for k in %s; do printf "%%s=%%s\\n" "$k" "${!k}"; done' % (AG, keys)
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, cwd=ROOT).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def frontmatter(text):
    meta, body = {}, text
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            for line in text[4:end].splitlines():
                if ":" in line:
                    k, v = line.split(":", 1)
                    meta[k.strip()] = v.strip()
            body = text[end + 4:]
    return meta, body


def log_lines(body):
    return [m.group(1) for m in re.finditer(r"^- (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d .*)$", body, re.M)]


def verdict(path):
    m = re.search(r'"verdict"\s*:\s*"([A-Z]+)"', read(path))
    return m.group(1) if m else None


def runs():
    rows = []
    try:
        with open(os.path.join(LOGS, "runs.csv"), newline="") as fh:
            for r in csv.reader(fh):
                if len(r) >= 7:
                    rows.append({"date": r[0], "time": r[1], "task": r[2], "role": r[3], "model": r[4],
                                 "rc": int(r[5] or 0), "seconds": int(r[6] or 0)})
    except OSError:
        pass
    return rows


def tier(model):
    m = model.lower()
    if "nemotron" in m:
        for key, name in (("ultra", "Ultra"), ("super-vl", "Super VL"), ("super", "Super"), ("nano", "Nano")):
            if key in m:
                return "Nemotron " + name
    return "Other open models"


def short(model):
    return re.sub(r"^tokenfactory/[^/]+/", "", model).split(":")[0]


def tasks(all_runs):
    out = []
    if not os.path.isdir(TASKS):
        return out
    for name in sorted(os.listdir(TASKS)):
        if not re.match(r"^T-\d+\.md$", name):
            continue
        tid = name[:-3]
        meta, body = frontmatter(read(os.path.join(TASKS, name)))
        mine = [r for r in all_runs if r["task"] == tid]
        gates = [{"result": "pass" if r["role"] == "gate-pass" else "fail", "model": short(r["model"]),
                  "at": r["date"] + " " + r["time"]} for r in mine if r["role"] in ("gate-pass", "gate-fail")]
        calls = [{"role": r["role"], "model": short(r["model"]), "tier": tier(r["model"]), "rc": r["rc"],
                  "seconds": r["seconds"], "at": r["date"] + " " + r["time"]} for r in mine if r["role"] not in OUTCOMES]
        out.append({
            "id": tid, "title": meta.get("title", ""), "goal": meta.get("goal", ""), "type": meta.get("type", ""),
            "risk": meta.get("risk", ""), "status": meta.get("status", ""), "files": meta.get("files", ""),
            "after": meta.get("after", "").strip("[] "), "attempt": meta.get("attempt", ""), "model": short(meta.get("model", "")),
            "brief": re.split(r"^## Log\s*$", body, flags=re.M)[0].strip()[:6000],
            "log": log_lines(body), "gates": gates, "calls": calls,
            "flaky": any(r["role"] == "flaky" for r in mine),
            "flaky_note": read(os.path.join(TASKS, tid + ".flaky.md"), 2000),
            "verdicts": {k: verdict(os.path.join(TASKS, "%s.%s.json" % (tid, k)))
                         for k in ("review1", "review2", "judge", "uiqa")},
        })
    return out


def goals():
    out = []
    if not os.path.isdir(GOALS):
        return out
    for name in sorted(os.listdir(GOALS)):
        if re.match(r"^G-\d+\.md$", name):
            meta, body = frontmatter(read(os.path.join(GOALS, name)))
            out.append({"id": name[:-3], "title": meta.get("title", ""), "status": meta.get("status", ""),
                        "mode": meta.get("mode", ""), "profile": meta.get("profile", ""),
                        "created": meta.get("created", ""), "log": log_lines(body)})
    return out


def migration(task_list):
    text = read(os.path.join(ROOT, "MIGRATION.md"))
    if not text:
        return None
    grab = lambda k: (re.search(r"^- %s: (.*)$" % k, text, re.M) or [None, ""])[1]
    modules = []
    for m in re.finditer(r"^\| `([^`]+)` \| (\d+) \|[^|]*\|[^|]*\| ([^|]*) \| ([^|]*) \|$", text, re.M):
        path = m.group(1)
        stem = re.sub(r"\.[a-z]+$", "", path)
        state = {"pin": None, "migrate": None}
        for t in task_list:
            listed = [f.strip() for f in t["files"].split(",")]
            if t["type"] == "migrate" and any(re.sub(r"\.[a-z]+$", "", f) == stem for f in listed):
                state["migrate"] = t["status"]
            if t["type"] == "pin" and os.path.basename(stem) in t["files"]:
                state["pin"] = t["status"]
        modules.append({"path": path, "lines": int(m.group(2)), "tested": m.group(3).strip() not in ("", "none"),
                        "risk": m.group(4).strip(), **state})
    return {"from": grab("From"), "to": grab("To"), "baseline": grab(r"Baseline on [\d-]+"), "modules": modules}


def decisions():
    lines = read(os.path.join(LOGS, "orchestrator.log")).splitlines()
    keep = [l for l in lines if re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (wake|run:|refused|undid|daily|G-\d+ done)", l)]
    return keep[-60:]


def state():
    s = settings()
    all_runs = runs()
    task_list = tasks(all_runs)
    calls = [r for r in all_runs if r["role"] not in OUTCOMES]
    by_model = {}
    for r in calls:
        k = short(r["model"])
        d = by_model.setdefault(k, {"model": k, "tier": tier(r["model"]), "calls": 0, "errors": 0, "seconds": 0})
        d["calls"] += 1
        d["errors"] += r["rc"] != 0
        d["seconds"] += r["seconds"]
    by_role = {}
    for r in calls:
        by_role[r["role"]] = by_role.get(r["role"], 0) + 1
    roles = {
        "Orchestrator (plan, triage, sign-off)": s.get("ORCH_MODEL", ""),
        "Judge, every review, UI screenshot QA": s.get("M_NEMO", ""),
        "Worker A": s.get("M_DS", ""), "Worker B, repo map, context": s.get("M_MM", ""),
        "Pin tests, first retry": s.get("M_GLM", ""), "Last retry": s.get("ESC_MODEL", ""),
    }
    return {
        "repo": os.path.basename(ROOT), "generated": subprocess.run(["date", "+%F %T"], capture_output=True, text=True).stdout.strip(),
        "profile": s.get("PROFILE", ""), "integration": s.get("INTEGRATION_BRANCH", "agents"), "main": s.get("MAIN_BRANCH", "main"),
        "roles": {k: short(v) + (" (" + v.rsplit(":", 1)[1] + " effort)" if v.count(":") else "") for k, v in roles.items() if v},
        "orchestrator": short(s.get("ORCH_MODEL", "")), "goals": goals(), "tasks": task_list,
        "migration": migration(task_list), "models": sorted(by_model.values(), key=lambda d: -d["calls"]),
        "by_role": by_role, "total_calls": len(calls), "decisions": decisions(),
    }


def diff(tid):
    if not re.match(r"^T-\d+$", tid or ""):
        return ""
    s = settings()
    integ = s.get("INTEGRATION_BRANCH", "agents")
    meta, _ = frontmatter(read(os.path.join(TASKS, tid + ".md")))
    for br in filter(None, [meta.get("branch"), "task/" + tid, "task/%s-b" % tid]):
        if git("rev-parse", "--verify", "--quiet", "refs/heads/" + br).strip():
            return git("diff", "%s...%s" % (integ, br))[:200000]
    merge = git("log", integ, "--merges", "--grep", "^%s:" % tid, "-1", "--format=%H").strip()
    return git("diff", merge + "^1", merge)[:200000] if merge else ""


class Handler(http.server.BaseHTTPRequestHandler):
    def send(self, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path in ("/", "/index.html"):
            self.send(read(os.path.join(AG, "dashboard.html")), "text/html; charset=utf-8")
        elif url.path == "/state.json":
            self.send(json.dumps(state()), "application/json")
        elif url.path.startswith("/diffs/") and url.path.endswith(".diff"):
            self.send(diff(url.path[7:-5]), "text/plain; charset=utf-8")
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass


def export(out):
    os.makedirs(os.path.join(out, "diffs"), exist_ok=True)
    st = state()
    st["static"] = True
    with open(os.path.join(out, "state.json"), "w") as fh:
        json.dump(st, fh)
    for t in st["tasks"]:
        with open(os.path.join(out, "diffs", t["id"] + ".diff"), "w") as fh:
            fh.write(diff(t["id"]))
    with open(os.path.join(out, "index.html"), "w") as fh:
        fh.write(read(os.path.join(AG, "dashboard.html")))
    print("wrote %s (index.html, state.json, %d diffs)" % (out, len(st["tasks"])))


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--json"]:          # used by the web app
        print(json.dumps(state()))
    elif args[:1] == ["--diff"]:
        sys.stdout.write(diff(args[1] if len(args) > 1 else ""))
    elif args[:1] == ["--export"]:
        export(args[1] if len(args) > 1 else "dashboard-snapshot")
    else:
        port = int(args[args.index("--port") + 1]) if "--port" in args else 8765
        print("dashboard for %s at http://127.0.0.1:%d (Ctrl+C to stop)" % (ROOT, port))
        http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
