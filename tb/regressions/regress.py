#!/usr/bin/env python3
import argparse
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RESULTS = os.path.join(ROOT, ".build", "regressions")
KINDS = ("sanity", "nightly")
COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ
GREEN = "\033[32m" if COLOR else ""
RED = "\033[31m" if COLOR else ""
BOLD = "\033[1m" if COLOR else ""
RESET = "\033[0m" if COLOR else ""
ANSI = re.compile(r"\x1b\[[0-9;]*m")
ERROR = re.compile(r"\bFAIL\b|%Error|\berror:|Build failed|Test failed|Failed tests|No rule to make target|Traceback")


def paint(text):
    text = re.sub(r"\bPASS\b", f"{GREEN}PASS{RESET}", text)
    return re.sub(r"\bFAIL\b", f"{RED}FAIL{RESET}", text)


def load_suites():
    suites = {}
    for path in sorted(glob.glob(os.path.join(HERE, "*.yml"))):
        if os.path.basename(path) in ("nightly.yml", "sanity.yml"):
            continue
        with open(path) as f:
            suite = yaml.safe_load(f)
        suites[suite["name"]] = suite
    return suites


def load_config():
    with open(os.path.join(HERE, "nightly.yml")) as f:
        return yaml.safe_load(f) or {}


def load_sanity_list(suites):
    with open(os.path.join(HERE, "sanity.yml")) as f:
        names = (yaml.safe_load(f) or {}).get("suites") or []
    for n in names:
        if n not in suites:
            sys.exit(f"unknown suite '{n}' in tb/regressions/sanity.yml, known: {', '.join(suites)}")
        if "sanity" not in suites[n]:
            sys.exit(f"'{n}' has no sanity command in tb/regressions/{n}.yml")
    return names


def pick(suites, config, select):
    select = select.strip()
    if select == "":
        names = config.get("regressions") or []
    elif select == "all":
        names = ["sanity"] + [n for n, s in suites.items() if "nightly" in s]
    else:
        names = [n.strip() for n in select.split(",") if n.strip()]
    sanity = load_sanity_list(suites) if "sanity" in names else []
    regressions = [n for n in names if n != "sanity"]
    for n in regressions:
        if n not in suites:
            sys.exit(f"unknown regression '{n}', known: sanity, {', '.join(suites)}")
        if "nightly" not in suites[n]:
            sys.exit(f"'{n}' has no nightly command in tb/regressions/{n}.yml")
    return sanity, regressions


def leaf_dir(name, kind):
    return os.path.join(RESULTS, name, kind)


def run_suite(name, kind, quiet=False):
    suites = load_suites()
    if name not in suites:
        hint = f" (did you mean: regress.py {name})" if name in ("sanity", "nightly") else ""
        sys.exit(f"unknown suite '{name}', known: {', '.join(suites)}{hint}")
    suite = suites[name]
    if kind not in suite:
        sys.exit(f"'{name}' has no {kind} command")
    out = leaf_dir(name, kind)
    os.makedirs(out, exist_ok=True)
    print(f"{BOLD}=== {kind} {name}: {suite[kind]}{RESET}", flush=True)
    env = dict(os.environ)
    if COLOR:
        env["FORCE_COLOR"] = "1"
    started = time.time()
    with open(os.path.join(out, "run.log"), "w") as log:
        proc = subprocess.Popen(suite[kind], shell=True, cwd=ROOT, executable="/bin/bash", env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in proc.stdout:
            if not quiet:
                sys.stdout.write(line)
            log.write(ANSI.sub("", line))
        code = proc.wait()
    seconds = time.time() - started

    with open(os.path.join(out, "run.log")) as f:
        lines = f.read().splitlines()
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write(summarize(f"{kind} {name}", lines))
    with open(os.path.join(out, "error.summary"), "w") as f:
        f.write("\n".join(error_lines(lines, code)) + "\n")
    seeds = next((l for l in lines if l.startswith("Random seeds")), "")
    with open(os.path.join(out, "status"), "w") as f:
        f.write(f"{'PASS' if code == 0 else 'FAIL'}\n")
        f.write(f"exit code: {code}\n")
        f.write(f"duration: {seconds:.1f}s\n")
        f.write(f"command: {suite[kind]}\n")
        if seeds:
            f.write(f"{seeds}\n")
    return code, out


def error_lines(lines, code):
    errors = []
    for l in lines:
        if ERROR.search(l) and l not in errors:
            errors.append(l)
    if code != 0 and not errors:
        errors = lines[-20:]
    return errors or ["none"]


def summarize(title, lines):
    picked = [l for l in lines if l.startswith("Random seeds")]
    start = next((i for i, l in enumerate(lines) if "test summary" in l), None)
    results = [l for l in lines if l.startswith(("PASS", "FAIL"))]
    if start is not None:
        picked += lines[start:]
    elif results:
        picked += results
    else:
        picked += lines[-20:]
    return "\n".join([f"## {title}", "```"] + picked + ["```", ""])


def cmd_list(args):
    suites = load_suites()
    config = load_config()
    for n, s in suites.items():
        print(f"{n}")
        for kind in KINDS:
            if kind in s:
                print(f"  {kind}: {s[kind]}")
    print()
    print(f"sanity suites: {', '.join(load_sanity_list(suites)) or 'none'}")
    print(f"nightly runs: {', '.join(config.get('regressions') or []) or 'nothing'}")


def cmd_plan(args):
    suites = load_suites()
    config = load_config()
    sanity, regressions = pick(suites, config, args.select)
    print(f"sanity={json.dumps(sanity)}")
    print(f"regressions={json.dumps(regressions)}")


def cmd_run(args):
    code, out = run_suite(args.name, args.kind)
    print(f"results in {out}")
    return code


def cmd_sanity(args):
    suites = load_suites()
    return run_jobs([("sanity", n) for n in load_sanity_list(suites)], args.quiet)


def cmd_nightly(args):
    suites = load_suites()
    config = load_config()
    sanity, regressions = pick(suites, config, args.select)
    jobs = [("sanity", n) for n in sanity] + [("nightly", n) for n in regressions]
    return run_jobs(jobs, args.quiet)


def run_jobs(jobs, quiet=False):
    os.makedirs(RESULTS, exist_ok=True)
    lock = open(os.path.join(RESULTS, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("another regression run is using .build/regressions, waiting for it to finish...", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
    results = []
    for kind, name in jobs:
        code, out = run_suite(name, kind, quiet)
        results.append((kind, name, code, out))
    print()
    for kind, name, code, out in results:
        if quiet and code == 0:
            continue
        name_file = "error.summary" if quiet else "summary.md"
        with open(os.path.join(out, name_file)) as f:
            text = f.read()
        if quiet:
            text = f"## errors in {kind} {name}\n{text}"
        print(paint(text))
    print(f"{BOLD}Results{RESET}")
    for kind, name, code, out in results:
        status = f"{GREEN}PASS{RESET}" if code == 0 else f"{RED}FAIL{RESET}"
        print(f"  {status}: {kind} {name}  ({os.path.relpath(out, ROOT)})")
    return 0 if all(code == 0 for _, _, code, _ in results) else 1


def main():
    parser = argparse.ArgumentParser(description="Run the regressions defined in tb/regressions/*.yml")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="show suites and the nightly selection").set_defaults(func=cmd_list)

    p = sub.add_parser("plan", help="print what the nightly would run, for GitHub Actions")
    p.add_argument("--select", default="", help="comma list (sanity and/or suite names), 'all', or empty for nightly.yml")
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("run", help="run one suite")
    p.add_argument("name")
    p.add_argument("--kind", choices=KINDS, default="sanity")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("sanity", help="run the suites in sanity.yml")
    p.add_argument("--quiet", action="store_true", help="only print results and errors")
    p.set_defaults(func=cmd_sanity)

    p = sub.add_parser("nightly", help="run the nightly locally: sanity, then the selected regressions")
    p.add_argument("--select", default="", help="comma list (sanity and/or suite names), 'all', or empty for nightly.yml")
    p.add_argument("--quiet", action="store_true", help="only print results and errors")
    p.set_defaults(func=cmd_nightly)

    args = parser.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
