"""Nemotron Migration Agent: local web app. Standard library only.

    python3 app/server.py [--port 8780] [--workspace ~/nemotron-migrations]

Point it at a GitHub URL or a local git repo, answer the migration questions, connect providers, pick a model
per role, start the migration and watch it. The pipeline itself is the kit in .agents/ (bash scripts); this
server only calls those scripts and reads their files.

Safety: it listens on 127.0.0.1 only, and every /api call must carry the random token this process embeds in
the page, so other websites open in the same browser cannot drive it. API keys are written to the project's
git-ignored .agents/secrets.sh and are never sent back to the browser.
"""
import http.server
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = secrets.token_hex(16)
args = sys.argv[1:]
PORT = int(args[args.index("--port") + 1]) if "--port" in args else 8780
WORKSPACE = os.path.expanduser(args[args.index("--workspace") + 1] if "--workspace" in args
                               else os.environ.get("NMA_WORKSPACE", "~/nemotron-migrations"))
REGISTRY = os.path.join(WORKSPACE, "projects.json")
COMPAT = {"supportsDeveloperRole": False, "supportsStore": False, "maxTokensField": "max_tokens"}
ROLE_VARS = {"orchestrator": "ORCH_MODEL", "reviewer": "M_NEMO", "worker_a": "M_DS", "worker_b": "M_MM",
             "tester": "M_GLM", "helper": "M_HELPER", "last_retry": "ESC_MODEL"}
LOCK = threading.Lock()
JOBS = {}
PI_INSTALL = "npm install -g @earendil-works/pi-coding-agent@1.0.4"
# (tool, needed?, what it's for, how to install on macOS)
TOOLS = [
    ("git", True, "repos and branches", "brew bundle"),
    ("jq", True, "reading JSON in the pipeline", "brew bundle"),
    ("curl", True, "provider checks", "brew bundle"),
    ("timeout|gtimeout", True, "time limits on model calls", "brew bundle  (coreutils)"),
    ("pi", True, "runs the models", PI_INSTALL),
    ("npm", False, "JavaScript projects", "brew bundle  (node)"),
    ("gitleaks", False, "security gate: secrets", "brew bundle"),
    ("semgrep", False, "security gate: risky code", "brew bundle"),
    ("gh", False, "Open pull request", "brew bundle, then gh auth login"),
]


def missing_tools():
    out = []
    for names, required, purpose, install in TOOLS:
        if not any(shutil.which(n) for n in names.split("|")):
            out.append({"tool": names.split("|")[0], "required": required, "for": purpose, "install": install})
    return out


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


# ---------- projects ----------
def load_projects():
    try:
        with open(REGISTRY) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return []


def save_projects(projects):
    os.makedirs(WORKSPACE, exist_ok=True)
    with open(REGISTRY, "w") as fh:
        json.dump(projects, fh, indent=2)


def project(pid):
    for p in load_projects():
        if p["id"] == pid:
            return p
    raise ApiError(404, "no project " + pid)


def ag(p, *parts):
    return os.path.join(p["path"], ".agents", *parts)


def run(cmd, cwd, timeout=600, env=None):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                       env={**os.environ, **(env or {})}, stdin=subprocess.DEVNULL)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def git(p, *a):
    return run(["git", *a], p["path"])


def commit(p, paths, message):
    git(p, "add", "--", *paths)
    rc, out = run(["git", "-c", "user.name=Migration Agent", "-c", "user.email=agent@localhost", "commit", "-q",
                   "-m", message], p["path"])
    return rc == 0 or "nothing to commit" in out


# ---------- background jobs (clone, prepare, tests, pull request) ----------
def start_job(kind, fn):
    jid = secrets.token_hex(6)
    JOBS[jid] = {"id": jid, "kind": kind, "status": "running", "log": "", "result": None, "started": time.time()}

    def log(text):
        JOBS[jid]["log"] = (JOBS[jid]["log"] + text.rstrip("\n") + "\n")[-20000:]

    def target():
        try:
            JOBS[jid]["result"] = fn(log)
            JOBS[jid]["status"] = "done"
        except Exception as e:  # report every failure to the page
            log("ERROR: %s" % e)
            JOBS[jid]["status"] = "failed"
    threading.Thread(target=target, daemon=True).start()
    return JOBS[jid]


def stream(cmd, cwd, log, env=None):
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            stdin=subprocess.DEVNULL, env={**os.environ, **(env or {})})
    for line in proc.stdout:
        log(line)
    return proc.wait()


def create_project(source, log):
    source = source.strip()
    is_url = bool(re.match(r"^(https://|git@)[\w.@:/~+-]+$", source))
    if is_url:
        name = re.sub(r"\.git$", "", source.rstrip("/").split("/")[-1].split(":")[-1]) or "repo"
        if not re.match(r"^[\w.-]+$", name):
            raise ValueError("unusual repository name")
        path = os.path.join(WORKSPACE, name)
        n = 2
        while os.path.exists(path):
            path = os.path.join(WORKSPACE, "%s-%d" % (name, n))
            n += 1
        os.makedirs(WORKSPACE, exist_ok=True)
        log("Cloning %s ..." % source)
        if stream(["git", "clone", "--", source, path], WORKSPACE, log) != 0:
            raise ValueError("git clone failed")
    else:
        path = os.path.abspath(os.path.expanduser(source))
        if not os.path.isdir(path):
            raise ValueError("Not a GitHub URL or an existing folder: " + source)
        if run(["git", "rev-parse", "--show-toplevel"], path)[0] != 0:
            raise ValueError("not a git repository: " + path)
        path = run(["git", "rev-parse", "--show-toplevel"], path)[1].strip()
        name = os.path.basename(path)
    if " " in path:
        raise ValueError("the kit's scripts don't support spaces in the path: " + path)
    p = {"id": secrets.token_hex(4), "name": name, "path": path, "source": source, "created": time.strftime("%F %T")}
    log("Installing the migration agent ...")
    if stream(["bash", os.path.join(KIT, "setup.sh"), path], path, log) != 0:
        raise ValueError("setup.sh failed")
    if os.path.exists(os.path.join(path, "package.json")) and not os.path.isdir(os.path.join(path, "node_modules")):
        log("Installing npm dependencies ...")
        stream(["npm", "install", "--no-audit", "--no-fund"], path, log)
    commit(p, [".agents", "AGENTS.md", "NOTES.md", ".gitignore"], "Add the migration agent")
    with LOCK:
        projects = [x for x in load_projects() if x["path"] != path]
        projects.append(p)
        save_projects(projects)
    log("Project ready: %s" % path)
    return p


# ---------- providers and models ----------
def models_json(p):
    try:
        with open(ag(p, "pi", "models.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"providers": {}}


def secrets_env(p):
    env = {}
    try:
        for line in open(ag(p, "secrets.sh")):
            m = re.match(r'^export ([A-Z_][A-Z0-9_]*)="(.*)"', line.strip())
            if m:
                env[m.group(1)] = m.group(2)
    except OSError:
        pass
    return env


def set_secret(p, name, value):
    path = ag(p, "secrets.sh")
    lines = open(path).read().splitlines() if os.path.exists(path) else ["# secrets.sh: API keys (git ignores this file)"]
    lines = [l for l in lines if not l.startswith("export %s=" % name)] + ['export %s="%s"' % (name, value)]
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(path, 0o600)


def catalog(p):
    try:
        with open(ag(p, "catalog.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        with open(os.path.join(KIT, ".agents", "catalog.json")) as fh:
            return json.load(fh)


def resolved_roles(p):
    script = 'source .agents/lib.sh >/dev/null 2>&1 || exit 1; for k in %s; do printf "%%s=%%s\\n" "$k" "${!k}"; done' % \
        " ".join(ROLE_VARS.values())
    out = run(["bash", "-c", script], p["path"])[1]
    vals = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    return {role: vals.get(var, "") for role, var in ROLE_VARS.items()}


def family_of(p, model):
    mid = model.split("/", 1)[1] if "/" in model else model
    mid = mid.split(":")[0]
    for m in catalog(p)["models"]:
        if m["id"] == mid:
            return m["family"]
    low = mid.lower()
    for key in ("nemotron", "deepseek", "minimax", "glm", "qwen", "kimi", "gpt", "llama", "gemma", "mistral"):
        if key in low:
            return key
    return mid.split("/")[0].lower()


def check_roles(p, roles):
    """The rules that keep the results trustworthy. Returns a list of problems."""
    fam = {r: family_of(p, m) for r, m in roles.items() if m}
    problems = []
    for r in ("worker_a", "worker_b", "tester"):
        if r in fam and fam.get("reviewer") == fam[r]:
            problems.append("The judge/reviewer must be a family no worker uses, but it shares the %s family with %s."
                            % (fam[r], r.replace("_", " ")))
    if fam.get("worker_a") and fam.get("worker_a") == fam.get("worker_b"):
        problems.append("Worker A and worker B must be different families (best-of-2 compares two families).")
    return problems


# ---------- loop ----------
def loop_pid(p):
    try:
        pid = int(open(ag(p, "loop.pid")).read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def start_loop(p):
    if loop_pid(p):
        return
    os.makedirs(ag(p, "logs"), exist_ok=True)
    out = open(ag(p, "logs", "loop.log"), "a")
    proc = subprocess.Popen(["bash", ag(p, "loop.sh")], cwd=p["path"], stdout=out, stderr=subprocess.STDOUT,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    with open(ag(p, "loop.pid"), "w") as fh:
        fh.write(str(proc.pid))


def stop_loop(p):
    pid = loop_pid(p)
    if pid:
        os.killpg(pid, signal.SIGTERM)


# ---------- API ----------
def api(method, parts, body, query):
    if parts == ["health"] and method == "GET":
        return {"missing": missing_tools()}
    if parts == ["projects"] and method == "GET":
        return [{**x, "loop": bool(loop_pid(x))} for x in load_projects()]
    if parts == ["projects"] and method == "POST":
        src = (body.get("source") or "").strip()
        if not src:
            raise ApiError(400, "Give a GitHub URL or a local path")
        return start_job("create", lambda log: create_project(src, log))
    if parts[:1] == ["jobs"] and len(parts) == 2:
        j = JOBS.get(parts[1]) or {}
        if not j:
            raise ApiError(404, "no job")
        return j
    if parts[:1] != ["projects"] or len(parts) < 2:
        raise ApiError(404, "unknown endpoint")
    p, rest = project(parts[1]), parts[2:]

    if rest == [] and method == "GET":
        q = ag(p, "logs", "migration-questions.json")
        mig = os.path.join(p["path"], "MIGRATION.md")
        rc, remote = git(p, "remote", "get-url", "origin")
        goals = os.listdir(ag(p, "goals")) if os.path.isdir(ag(p, "goals")) else []
        env = {**os.environ, **secrets_env(p)}
        key_ready = any(env.get((prov.get("apiKey") or "").lstrip("$")) and prov.get("models")
                        for prov in models_json(p).get("providers", {}).values())
        return {**p, "loop": bool(loop_pid(p)), "keyReady": key_ready,
                "questions": json.load(open(q)) if os.path.exists(q) else None,
                "migration": open(mig).read() if os.path.exists(mig) else None,
                "started": any(g.startswith("G-") for g in goals),
                "remote": remote.strip() if rc == 0 else "", "gh": bool(shutil.which("gh"))}
    if rest == ["prepare"] and method == "POST":
        return start_job("prepare", lambda log: stream(["bash", ag(p, "migrate.sh"), "init", "--prepare"], p["path"], log))
    if rest == ["answers"] and method == "POST":
        answers = {k: str(v) for k, v in (body.get("answers") or {}).items() if re.match(r"^[a-z]+$", k)}
        path = ag(p, "logs", "migration-answers.json")
        with open(path, "w") as fh:
            json.dump(answers, fh)
        rc, out = run(["bash", ag(p, "migrate.sh"), "init", "--answers", path], p["path"])
        if rc != 0:
            raise ApiError(500, out[-2000:])
        return {"migration": open(os.path.join(p["path"], "MIGRATION.md")).read()}
    if rest == ["migration"] and method == "POST":
        with open(os.path.join(p["path"], "MIGRATION.md"), "w") as fh:
            fh.write(body.get("text", ""))
        return {"ok": True}

    if rest == ["providers"] and method == "GET":
        env = {**os.environ, **secrets_env(p)}
        out = []
        for name, prov in models_json(p).get("providers", {}).items():
            key_env = (prov.get("apiKey") or "").lstrip("$").strip("{}")
            out.append({"name": name, "baseUrl": prov.get("baseUrl"), "keyEnv": key_env,
                        "keySet": bool(env.get(key_env)), "models": [m["id"] for m in prov.get("models", [])]})
        return out
    if rest == ["providers"] and method == "POST":
        name, url, key_env = body.get("name", ""), body.get("baseUrl", ""), body.get("keyEnv", "")
        if not re.match(r"^[a-z0-9][a-z0-9-]{0,30}$", name):
            raise ApiError(400, "Provider name: lowercase letters, digits and dashes")
        if not re.match(r"^https?://[\w.:/-]+$", url):
            raise ApiError(400, "Base URL must look like https://host/v1")
        if not re.match(r"^[A-Z_][A-Z0-9_]{1,40}$", key_env):
            raise ApiError(400, "Key variable: uppercase letters, digits and underscores")
        if body.get("key"):
            if not re.match(r"^[\w.~+/=:-]{8,400}$", body["key"]):
                raise ApiError(400, "That doesn't look like an API key")
            set_secret(p, key_env, body["key"])
        mj = models_json(p)
        prov = mj.setdefault("providers", {}).setdefault(name, {"models": []})
        prov.update({"baseUrl": url.rstrip("/"), "api": "openai-completions", "apiKey": "$" + key_env})
        with open(ag(p, "pi", "models.json"), "w") as fh:
            json.dump(mj, fh, indent=2)
        return {"ok": True}
    if len(rest) == 3 and rest[0] == "providers" and rest[2] == "available" and method == "GET":
        prov = models_json(p).get("providers", {}).get(rest[1]) or {}
        key = secrets_env(p).get((prov.get("apiKey") or "").lstrip("$")) or os.environ.get((prov.get("apiKey") or "").lstrip("$"), "")
        req = urllib.request.Request(prov.get("baseUrl", "") + "/models", headers={"Authorization": "Bearer " + key})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                ids = sorted(m["id"] for m in json.load(r).get("data", []))
        except Exception as e:
            raise ApiError(502, "Could not list models: %s" % e)
        cat = {m["id"]: m for m in catalog(p)["models"]}
        return [{"id": i, **({k: cat[i][k] for k in ("name", "family", "index", "cost_per_task", "price_in", "price_out")
                             if k in cat[i]} if i in cat else {})} for i in ids]
    if len(rest) == 3 and rest[0] == "providers" and rest[2] == "models" and method == "POST":
        mj = models_json(p)
        prov = mj.get("providers", {}).get(rest[1])
        if prov is None:
            raise ApiError(404, "no provider")
        cat = {m["id"]: m for m in catalog(p)["models"]}
        keep = {m["id"]: m for m in prov.get("models", [])}
        prov["models"] = [keep.get(i) or {"id": i, "reasoning": True, "contextWindow": 262144, "maxTokens": 32768,
                                          **({"input": ["text", "image"]} if cat.get(i, {}).get("vision") else {}),
                                          "compat": COMPAT}
                          for i in body.get("models", []) if re.match(r"^[\w.:/-]+$", i)]
        with open(ag(p, "pi", "models.json"), "w") as fh:
            json.dump(mj, fh, indent=2)
        return {"ok": True}

    if rest == ["models"] and method == "GET":
        mj = models_json(p)
        available = [{"model": "%s/%s" % (name, m["id"]), "provider": name, "id": m["id"]}
                     for name, prov in mj.get("providers", {}).items() for m in prov.get("models", [])]
        roles = resolved_roles(p)
        return {"roles": catalog(p)["roles"], "current": roles, "catalog": catalog(p)["models"],
                "source": catalog(p).get("source"), "available": available, "problems": check_roles(p, roles)}
    if rest == ["models"] and method == "POST":
        roles = {k: v for k, v in (body.get("roles") or {}).items() if k in ROLE_VARS and re.match(r"^[\w.:/-]+$", v)}
        problems = check_roles(p, roles)
        if problems:
            raise ApiError(400, " ".join(problems))
        with open(ag(p, "config.json"), "w") as fh:
            json.dump({"roles": roles}, fh, indent=2)
        return {"ok": True}
    if rest == ["test-models"] and method == "POST":
        return start_job("test", lambda log: stream(["bash", ag(p, "doctor.sh"), "--models"], p["path"], log))

    if rest == ["start"] and method == "POST":
        if not os.path.exists(os.path.join(p["path"], "MIGRATION.md")):
            raise ApiError(400, "Answer the migration questions first")
        if not commit(p, ["MIGRATION.md", ".agents/config.json", ".agents/pi/models.json"], "Migration plan"):
            raise ApiError(500, "Could not commit the migration plan")
        rc, out = run(["bash", ag(p, "migrate.sh"), "start", body.get("profile", "")], p["path"])
        if rc != 0:
            raise ApiError(400, out[-1500:])
        start_loop(p)
        return {"ok": True, "output": out}
    if rest == ["loop"] and method == "POST":
        start_loop(p) if body.get("action") == "start" else stop_loop(p)
        return {"loop": bool(loop_pid(p))}
    if rest == ["state"] and method == "GET":
        rc, out = run([sys.executable, ag(p, "dashboard.py"), "--json"], p["path"], timeout=60)
        if rc != 0:
            raise ApiError(500, out[-1000:])
        return {**json.loads(out), "loop": bool(loop_pid(p))}
    if len(rest) == 2 and rest[0] == "diff" and method == "GET":
        return {"diff": run([sys.executable, ag(p, "dashboard.py"), "--diff", rest[1]], p["path"], timeout=60)[1]}
    if len(rest) == 3 and rest[0] == "tasks" and method == "POST":
        tid, action = rest[1], rest[2]
        if not re.match(r"^T-\d+$", tid) or action not in ("approve", "reject", "requeue", "park", "drop"):
            raise ApiError(400, "bad task action")
        cmd = ["bash", ag(p, "runner.sh"), action, tid] + ([body.get("text", "")] if action != "approve" else [])
        rc, out = run(cmd, p["path"])
        if rc != 0:
            raise ApiError(400, out[-1500:])
        return {"ok": True, "output": out}
    if rest == ["pull-request"] and method == "POST":
        return start_job("pr", lambda log: open_pr(p, log))
    raise ApiError(404, "unknown endpoint")


def open_pr(p, log):
    rc, remote = git(p, "remote", "get-url", "origin")
    if rc != 0 or "github.com" not in remote:
        raise ValueError("This project has no GitHub remote (origin).")
    if not shutil.which("gh"):
        raise ValueError("Install the GitHub CLI (gh) and run `gh auth login` first.")
    integ = run(["bash", "-c", 'source .agents/lib.sh >/dev/null 2>&1; echo "$INTEGRATION_BRANCH $MAIN_BRANCH"'], p["path"])[1].split()
    head, base = (integ + ["agents", "main"])[:2]
    branch = "migration/" + time.strftime("%Y%m%d-%H%M")
    log("Pushing %s as %s ..." % (head, branch))
    if stream(["git", "push", "origin", "%s:refs/heads/%s" % (head, branch)], p["path"], log) != 0:
        raise ValueError("git push failed")
    title = "Migration: " + (re.search(r"^- To: (.*)$", open(os.path.join(p["path"], "MIGRATION.md")).read(), re.M) or [None, "update"])[1]
    body = ("Opened by the Nemotron Migration Agent. Every change passed the pinned characterization tests, typecheck, "
            "scope and security gates, and review by a different model family. See MIGRATION.md for the plan.")
    log("Opening the pull request ...")
    rc, out = run(["gh", "pr", "create", "--base", base, "--head", branch, "--title", title, "--body", body], p["path"], timeout=120)
    log(out)
    if rc != 0:
        raise ValueError("gh pr create failed")
    return {"url": out.strip().splitlines()[-1]}


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, status, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else (
            payload.encode() if isinstance(payload, str) else json.dumps(payload).encode())
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        url = urllib.parse.urlparse(self.path)
        if method == "GET" and url.path in ("/", "/index.html"):
            html = open(os.path.join(HERE, "index.html")).read().replace("__APP_TOKEN__", TOKEN)
            return self.reply(200, html, "text/html; charset=utf-8")
        if method == "GET" and url.path == "/assets/morphameleon-logo.png":
            with open(os.path.join(HERE, "assets", "morphameleon-logo.png"), "rb") as fh:
                return self.reply(200, fh.read(), "image/png")
        if method == "GET" and url.path == "/assets/morphameleon-hero.png":
            with open(os.path.join(HERE, "assets", "morphameleon-hero.png"), "rb") as fh:
                return self.reply(200, fh.read(), "image/png")
        if not url.path.startswith("/api/"):
            return self.reply(404, {"error": "not found"})
        if not secrets.compare_digest(self.headers.get("X-App-Token", ""), TOKEN):
            return self.reply(403, {"error": "missing or wrong app token; reload the page"})
        body = {}
        if method == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self.reply(400, {"error": "body must be JSON"})
        try:
            parts = [urllib.parse.unquote(x) for x in url.path[5:].split("/") if x]
            self.reply(200, api(method, parts, body, urllib.parse.parse_qs(url.query)))
        except ApiError as e:
            self.reply(e.status, {"error": str(e)})
        except Exception as e:
            self.reply(500, {"error": "%s: %s" % (type(e).__name__, e)})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    os.makedirs(WORKSPACE, exist_ok=True)
    for t in missing_tools():
        print("%s %-9s not found (%s). Install: %s" % ("MISSING " if t["required"] else "optional", t["tool"], t["for"], t["install"]))
    print("Nemotron Migration Agent at http://127.0.0.1:%d  (workspace: %s)" % (PORT, WORKSPACE))
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
