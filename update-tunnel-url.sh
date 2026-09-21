#!/bin/sh
# Publish the current cloudflared quick-tunnel URL to GitHub.
#
# This keeps two dynamic lines at the end of the configured GitHub file:
#   line 3: https://....trycloudflare.com
#   line 4: UTC timestamp of the update
# Lines 1-2 are preserved untouched.
#
# Required: GITHUB_TOKEN (or TOKEN_FILE). Do NOT hard-code the token here.
# Optional: GITHUB_REPO, GITHUB_PATH, GITHUB_BRANCH, CLOUDFLARED_CONTAINER,
#           LOG_TAIL, TOKEN_FILE.
set -eu
GITHUB_REPO="${GITHUB_REPO:-nakamacloud/isthatagubbylarpy}"
GITHUB_PATH="${GITHUB_PATH:-hmmmmmm}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
CLOUDFLARED_CONTAINER="${CLOUDFLARED_CONTAINER:-cloudflared}"
LOG_TAIL="${LOG_TAIL:-200}"
TOKEN_FILE="${TOKEN_FILE:-${HOME:-/root}/.config/tunnel-publisher/github-token}"
if [ -z "${GITHUB_TOKEN:-}" ] && [ -f "$TOKEN_FILE" ]; then
  GITHUB_TOKEN="$(cat "$TOKEN_FILE")"
fi
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "error: set GITHUB_TOKEN or place it in $TOKEN_FILE" >&2
  exit 1
fi
command -v docker >/dev/null 2>&1 || { echo "error: docker not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "error: curl not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }
if ! docker logs --tail 5 "$CLOUDFLARED_CONTAINER" >/dev/null 2>&1; then
  DISCOVERED="$(docker ps --filter 'ancestor=cloudflare/cloudflared' --format '{{.Names}}' | head -n 1 || true)"
  if [ -n "$DISCOVERED" ]; then
    CLOUDFLARED_CONTAINER="$DISCOVERED"
  else
    echo "error: docker container '$CLOUDFLARED_CONTAINER' not found" >&2
    exit 1
  fi
fi
URL="$(docker logs --tail "$LOG_TAIL" "$CLOUDFLARED_CONTAINER" 2>&1 | grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' | tail -n 1 || true)"
if [ -z "$URL" ]; then
  echo "error: no trycloudflare URL in logs for '$CLOUDFLARED_CONTAINER'" >&2
  exit 1
fi
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export GITHUB_TOKEN GITHUB_REPO GITHUB_PATH GITHUB_BRANCH URL STAMP
python3 - <<'PY'
import base64, json, os, sys, urllib.request
repo = os.environ["GITHUB_REPO"]
path = os.environ["GITHUB_PATH"]
branch = os.environ["GITHUB_BRANCH"]
token = os.environ["GITHUB_TOKEN"]
url = os.environ["URL"]
stamp = os.environ["STAMP"]
api = "https://api.github.com/repos/" + repo + "/contents/" + path
headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json", "User-Agent": "tunnel-publisher"}
def api_get(u):
    req = urllib.request.Request(u, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)
try:
    meta = api_get(api + "?ref=" + branch)
except Exception as e:
    print("error: cannot read GitHub file: " + str(e), file=sys.stderr)
    sys.exit(1)
sha = meta.get("sha")
if not sha:
    print("error: GitHub response missing sha", file=sys.stderr)
    sys.exit(1)
raw = base64.b64decode(meta.get("content") or "").decode("utf-8", errors="replace")
lines = raw.splitlines()
if len(lines) < 2 or not lines[0].strip() or not lines[1].strip():
    print("error: refusing to rewrite unexpected file; need 2 preserved lines", file=sys.stderr)
    sys.exit(1)
new_text = "\n".join([lines[0], lines[1], url, stamp]) + "\n"
if new_text == raw:
    print("no change")
    sys.exit(0)
body = json.dumps({"message": "Update tunnel URL " + stamp, "content": base64.b64encode(new_text.encode("utf-8")).decode("ascii"), "sha": sha, "branch": branch}).encode("utf-8")
req = urllib.request.Request(api, data=body, headers=headers, method="PUT")
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
except Exception as e:
    print("error: GitHub update failed: " + str(e), file=sys.stderr)
    sys.exit(1)
print("updated " + str(out.get("commit", {}).get("sha", "")))
PY
echo "published $URL"