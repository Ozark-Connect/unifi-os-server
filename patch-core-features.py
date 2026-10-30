#!/usr/bin/env python3
"""Patch UniFi Core's features fetch (CQe in 6.0.130) to stop the Network 11 recursion loop.

Network 11.0.x refreshes its system info by calling core GET /api/system. Core answers by
fetching Network features?includeSystemFeatures=true, which reads the same expired Network
cache and calls core again, until Network's 5-connection pool to core is used up. Every other
Network request that needs core then waits for the 40 s socket timeout.

The patch makes the fetch stale-while-revalidate with a single in-flight refresh, so
/api/system never waits on Network once core holds one features list.

It applies only while the installed Network version is in AFFECTED_MIN..AFFECTED_MAX and the
stock function is found. Otherwise the pristine service.js is restored.

Usage: patch-core-features.py [--revert] [--service-js PATH] [--network-version X.Y.Z]
Exit codes: 0 = no change, 10 = service.js changed (restart unifi-core), 1 = error, no change.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

SERVICE_JS = "/usr/share/unifi-core/app/service.js"
ORIG_SUFFIX = ".features-loop.orig"
MARKER = "/*uos-features-loop-patch*/"

# Network versions with the 5-deep loop (11.0.81-11.0.97 verified on gateways and UOS
# Server; 11.0.99 by decompile: cache adapter and RestTemplate unchanged from 11.0.97).
# Raise AFFECTED_MAX only after checking ipc.log burst depth or Network's cache code.
AFFECTED_MIN = (11, 0, 81)
AFFECTED_MAX = (11, 0, 99)

# Stock CQe, matched by structure. Minified names are captured, not hard-coded.
PATTERN = re.compile(
    r'var (?P<cache>[\w$]+)=new (?P<cls>[\w$]+)\(\{stdTTL:300\}\);'
    r'async function (?P<fn>[\w$]+)\(e=false\)\{if\(!e\)\{let o=(?P=cache)\.get\("features"\);if\(o\)return o\}'
    r'(?P<fetch>let t=await [\w$]+\("/v2/api/site/default/features\?includeSystemFeatures=true",'
    r'\{signal:AbortSignal\.timeout\(6e4\)\}\);await [\w$]+\("features",t\);let r=[\w$]+\.parse\(await t\.json\(\)\);)'
    r'return (?P=cache)\.set\("features",r\),r\}'
)

DONE, CHANGED, ERROR = 0, 10, 1


def log(msg):
    print(f"[patch-core-features] {msg}", flush=True)


def network_version():
    try:
        out = subprocess.run(["dpkg-query", "-W", "-f=${Version}", "unifi"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    m = re.match(r"(\d+)\.(\d+)\.(\d+)", out)
    return tuple(int(x) for x in m.groups()) if m else None


def patch_text(src):
    """Return src with the patched CQe, or None if the stock function is not found exactly once."""
    matches = list(PATTERN.finditer(src))
    if len(matches) != 1:
        return None
    m = matches[0]
    cache, cls, fn, fetch = m.group("cache"), m.group("cls"), m.group("fn"), m.group("fetch")
    new = (
        f'var {cache}=new {cls}({{stdTTL:300}});{MARKER}'
        f'var __uosFl={{v:null,p:null}};'
        f'async function __uosFlFetch(){{{fetch}{cache}.set("features",r);__uosFl.v=r;return r}}'
        f'function __uosFlRefresh(){{if(!__uosFl.p){{__uosFl.p=Promise.resolve().then(__uosFlFetch).finally(()=>{{__uosFl.p=null}})}}return __uosFl.p}}'
        f'async function {fn}(e=false){{if(!e){{let o={cache}.get("features");if(o)return o;'
        f'if(__uosFl.v){{__uosFlRefresh().catch(()=>{{}});return __uosFl.v}}'
        f'if(__uosFl.p)return []}}return __uosFlRefresh()}}'
    )
    return src[:m.start()] + new + src[m.end():]


def node_check(path):
    for node in ("/usr/bin/node24", "/usr/bin/node", "node"):
        if os.path.isabs(node) and not os.path.exists(node):
            continue
        try:
            r = subprocess.run([node, "--check", path], capture_output=True, text=True)
        except OSError:
            continue
        if r.returncode != 0:
            log(f"node --check failed: {r.stderr.strip()[:300]}")
        return r.returncode == 0
    log("no node binary found for syntax check")
    return False


def write_atomic(path, text):
    tmp = path + ".features-loop.tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--revert", action="store_true", help="restore the pristine service.js")
    ap.add_argument("--service-js", default=SERVICE_JS)
    ap.add_argument("--network-version", help="override the dpkg lookup (testing)")
    args = ap.parse_args()

    path = args.service_js
    orig = path + ORIG_SUFFIX
    try:
        with open(path, encoding="utf-8", newline="") as f:
            current = f.read()
    except OSError as e:
        log(f"cannot read {path}: {e}")
        return ERROR

    patched = MARKER in current
    if patched:
        if not os.path.exists(orig):
            log(f"{path} is patched but {orig} is missing; leaving it alone")
            return ERROR
        with open(orig, encoding="utf-8", newline="") as f:
            pristine = f.read()
    else:
        # Fresh install or a unifi-core update: the current file is the pristine one.
        pristine = current
        with open(orig, "w", encoding="utf-8", newline="") as f:
            f.write(pristine)

    if args.network_version:
        ver = tuple(int(x) for x in args.network_version.split(".")[:3])
    else:
        ver = network_version()
    vstr = ".".join(map(str, ver)) if ver else "unknown"

    if args.revert:
        want, reason = False, "--revert"
    elif ver is None or not (AFFECTED_MIN <= ver <= AFFECTED_MAX):
        want, reason = False, f"Network {vstr} is outside the affected range"
    else:
        want, reason = True, f"Network {vstr} is affected"

    if want:
        if patched:
            log(f"already patched ({reason})")
            return DONE
        new = patch_text(pristine)
        if new is None:
            log(f"stock features fetch not found; skipping ({reason})")
            return DONE
        tmp = path + ".features-loop.check.js"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(new)
        ok = node_check(tmp)
        os.remove(tmp)
        if not ok:
            log("patched file failed the syntax check; skipping")
            return ERROR
        write_atomic(path, new)
        log(f"patched ({reason})")
        return CHANGED

    if patched:
        write_atomic(path, pristine)
        log(f"reverted ({reason})")
        return CHANGED
    log(f"not patched ({reason})")
    return DONE


if __name__ == "__main__":
    sys.exit(main())
