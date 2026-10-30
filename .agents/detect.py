"""detect.py: facts about a repo for migrate.sh init. Prints one JSON object. Standard library only.

Usage: python3 -I .agents/detect.py <repo root>
Finds the stack, the commands, source and test files, which modules tests import, the import graph among
source files (dependency order, leaves first) and simple risk signals. No model involved.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
SRC_EXT = (".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".py")
SKIP_DIRS = ("node_modules/", "dist/", "build/", "coverage/", ".agents/", ".worktrees/", "vendor/", "examples/")
TEST_RE = re.compile(r"(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.[a-z]+$|(^|/)test_[^/]+\.py$|_test\.py$")
JS_IMPORT = re.compile(r"""(?:import\s[^'"]*?from\s*|import\s*\(\s*|require\s*\(\s*|export\s[^'"]*?from\s*)['"](\.{1,2}/[^'"]+)['"]""")
PY_IMPORT = re.compile(r"^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))", re.M)


def git_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True).stdout
    return [f for f in out.splitlines() if not f.startswith(SKIP_DIRS)]


def read(path):
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def resolve_js(importer, spec, files):
    base = os.path.normpath(os.path.join(os.path.dirname(importer), spec))
    stem = re.sub(r"\.(m?js|cjs|jsx|tsx?)$", "", base)
    for cand in [base] + [stem + e for e in (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")] + \
                [os.path.join(stem, "index" + e) for e in (".ts", ".js")]:
        if cand in files:
            return cand
    return None


def resolve_py(spec, files):
    path = spec.replace(".", "/")
    for cand in (path + ".py", path + "/__init__.py", "src/" + path + ".py"):
        if cand in files:
            return cand
    return None


def imports_of(path, files):
    text = read(path)
    found = set()
    if path.endswith(".py"):
        for a, b in PY_IMPORT.findall(text):
            r = resolve_py(a or b, files)
            if r:
                found.add(r)
    else:
        for spec in JS_IMPORT.findall(text):
            r = resolve_js(path, spec, files)
            if r:
                found.add(r)
    found.discard(path)
    return sorted(found)


def dependency_order(sources, graph):
    """Leaves first (a module comes after everything it imports). Cycles are appended at the end."""
    order, done, visiting, cycles = [], set(), set(), set()

    def visit(m):
        if m in done:
            return
        if m in visiting:
            cycles.add(m)
            return
        visiting.add(m)
        for d in graph.get(m, []):
            if d in sources:
                visit(d)
        visiting.discard(m)
        done.add(m)
        order.append(m)

    for m in sorted(sources):
        visit(m)
    return order, sorted(cycles)


def main():
    files = set(git_files())
    tests = sorted(f for f in files if f.endswith(SRC_EXT) and TEST_RE.search(f))
    sources = sorted(f for f in files if f.endswith(SRC_EXT) and f not in tests
                     and not re.search(r"(^|/)(vite|vitest|jest|webpack|rollup|babel|eslint|prettier)\.config\.", f))

    pkg = {}
    if "package.json" in files:
        try:
            pkg = json.loads(read("package.json"))
        except ValueError:
            pkg = {}
    deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
    scripts = pkg.get("scripts", {})
    stack = "node" if pkg else ("python" if {"pyproject.toml", "requirements.txt", "setup.py"} & files else "unknown")
    runner = next((r for r in ("vitest", "jest", "mocha", "ava") if r in deps), None)
    if stack == "python":
        runner = "pytest"
    commands = {}
    if stack == "node":
        for name in ("test", "lint", "typecheck", "build"):
            if name in scripts:
                commands[name] = "npm run " + name if name != "test" else "npm test"
    elif stack == "python":
        commands["test"] = "python3 -m pytest -q"

    ext_count = {}
    for f in sources:
        e = os.path.splitext(f)[1]
        ext_count[e] = ext_count.get(e, 0) + 1
    language = "unknown"
    if ext_count:
        top = max(ext_count, key=ext_count.get)
        language = {".js": "JavaScript", ".jsx": "JavaScript (JSX)", ".mjs": "JavaScript", ".cjs": "JavaScript",
                    ".ts": "TypeScript", ".tsx": "TypeScript (TSX)", ".py": "Python"}.get(top, top)
    module_style = None
    if language.startswith("JavaScript"):
        joined = "\n".join(read(f) for f in sources[:50])
        module_style = "ES modules" if re.search(r"^\s*(import|export)\s", joined, re.M) else "CommonJS"

    graph = {s: imports_of(s, files) for s in sources}
    # A test covers what it imports, including through test helpers (files in test folders it imports).
    tested_by = {s: [] for s in sources}
    for t in tests:
        deps, seen = list(imports_of(t, files)), {t}
        while deps:
            dep = deps.pop()
            if dep in seen:
                continue
            seen.add(dep)
            if dep in tested_by:
                tested_by[dep].append(t)
            elif dep in tests:
                deps.extend(imports_of(dep, files))
    imported_by = {s: [] for s in sources}
    for s, deps_ in graph.items():
        for d in deps_:
            if d in imported_by:
                imported_by[d].append(s)
    order, cycles = dependency_order(set(sources), graph)

    modules = []
    for s in order:
        lines = read(s).count("\n")
        risks = []
        if not tested_by[s]:
            risks.append("no tests")
        if len(imported_by[s]) >= 3:
            risks.append("imported by %d modules" % len(imported_by[s]))
        if lines > 300:
            risks.append("%d lines" % lines)
        if s in cycles:
            risks.append("import cycle")
        if re.search(r"\b(eval|new Function|global\.|window\.)", read(s)):
            risks.append("dynamic or global code")
        modules.append({"path": s, "lines": lines, "imports": graph[s], "imported_by": sorted(imported_by[s]),
                        "tests": sorted(tested_by[s]), "risks": risks})

    test_titles = {}
    for t in tests:
        titles = re.findall(r"""\b(?:describe|it|test)\s*\(\s*['"`]([^'"`]+)['"`]""", read(t))
        titles += re.findall(r"^\s*def (test_\w+)", read(t), re.M)
        if titles:
            test_titles[t] = titles[:40]

    top_dirs = sorted({s.split("/")[0] + "/" if "/" in s else s for s in sources})
    print(json.dumps({
        "root": ROOT, "stack": stack, "language": language, "module_style": module_style,
        "typescript": "typescript" in deps or "tsconfig.json" in files, "test_runner": runner,
        "commands": commands, "source_dirs": top_dirs, "test_files": tests, "test_titles": test_titles,
        "modules": modules, "cycles": cycles,
        "untested": [m["path"] for m in modules if not m["tests"]],
    }, indent=2))


if __name__ == "__main__":
    main()
