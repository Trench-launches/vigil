#!/usr/bin/env bash
# Deploy the site (web/) to Cloudflare Pages production. The Cloudflare twin of scripts/deploy-web.sh (Vercel).
#
# One-time setup:
#   npx wrangler login                                                  # opens the browser; sign in and allow
#   npx wrangler pages project create buddy-terminal --production-branch main --force   # --force: classic Pages
# Then:  bash scripts/deploy-cloudflare.sh
#
# The site's per-deployment settings come from SITE_* variables: from your shell first, then from the gitignored
# .env.site file at the repo root (a variable set in the shell wins, even when it's set to nothing). They are
# written into the deployed copy only: config.js, and the <head> tags link previews read.
#   CF_PAGES_PROJECT  optional: the Pages project (default buddy-terminal)
#   SITE_URL          optional: the site's public URL (default https://<project>.pages.dev; set it once a custom
#                     domain is attached)
#   SITE_API_URL      required: the backend's public URL, e.g. https://api.example.com
#   SITE_API_FALLBACK optional: an older backend URL, tried when the first can't be reached
#   SITE_NAME         optional: the persona's name (default Buddy)
#   SITE_X_HANDLE     optional: the bot's X handle, without the @
#   SITE_TOKEN_CA     optional: the project's own token contract, once launched
#   SITE_TOKEN_GMGN   optional: its GMGN link
# Only public values belong here: everything in config.js is served to every visitor.
#
# The backend only answers browsers on sites it knows: add the site's URL to CT_SITE_ORIGINS there, or the pages
# load with no data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${CF_PAGES_PROJECT:-buddy-terminal}"
VARS="SITE_URL SITE_API_URL SITE_API_FALLBACK SITE_NAME SITE_X_HANDLE SITE_TOKEN_CA SITE_TOKEN_GMGN"
# remember what the shell set, load .env.site, then put the shell's values back on top
for v in $VARS; do
  if [ -n "${!v+x}" ]; then export "_SHELL_$v=${!v}"; export "_SHELLSET_$v=1"; fi
done
if [ -f "$ROOT/.env.site" ]; then
  set -a; . "$ROOT/.env.site"; set +a
fi
for v in $VARS; do
  s="_SHELLSET_$v"; w="_SHELL_$v"
  if [ -n "${!s:-}" ]; then export "$v=${!w}"; fi
done
# .env.site's SITE_URL is the Vercel site's; on Cloudflare the default is the project's own pages.dev address
[ -n "${_SHELLSET_SITE_URL:-}" ] || export SITE_URL="https://$PROJECT.pages.dev"
if [ -z "${SITE_API_URL:-}" ]; then
  echo "SITE_API_URL is not set. See the top of $0." >&2
  exit 1
fi
[ -n "${SITE_X_HANDLE:-}" ] || echo "note: SITE_X_HANDLE is not set; the site won't link to an X account" >&2
# The first Python that runs (on Windows, `python3` can be the Microsoft Store stub, which doesn't)
PY=""
for p in "${PYTHON:-}" python3 python py; do
  if [ -n "$p" ] && "$p" -c "" >/dev/null 2>&1; then PY="$p"; break; fi
done
[ -n "$PY" ] || { echo "No working Python found (set PYTHON=/path/to/python)." >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'cd "$ROOT"; rm -rf "$TMP" 2>/dev/null || true' EXIT  # Windows may still hold the folder briefly; leftover temp files are harmless
cp -r "$ROOT/web" "$TMP/web"
# json.dumps / html.escape escape every value, so nothing in a variable can break out of the files
"$PY" - "$TMP/web" <<'EOF'
import html, json, os, re, sys
env = os.environ.get
handle = env("SITE_X_HANDLE", "").lstrip("@")
if handle and not re.fullmatch(r"[A-Za-z0-9_]{1,15}", handle):
    sys.exit(f"SITE_X_HANDLE {handle!r} isn't an X handle")
for k in ("SITE_URL", "SITE_API_URL", "SITE_API_FALLBACK", "SITE_TOKEN_GMGN"):
    if env(k) and not env(k).startswith("https://"):
        sys.exit(f"{k} must be an https:// URL")
cfg = {"name": env("SITE_NAME") or "Buddy", "xHandle": handle, "api": env("SITE_API_URL"),
       "apiFallback": env("SITE_API_FALLBACK", ""),
       "token": {"ca": env("SITE_TOKEN_CA", ""), "gmgn": env("SITE_TOKEN_GMGN", "")}}
with open(os.path.join(sys.argv[1], "config.js"), "w", encoding="utf-8") as f:
    f.write("// Written by scripts/deploy-cloudflare.sh at deploy time.\nwindow.SITE_CONFIG = " + json.dumps(cfg) + ";\n")
print("site config:", json.dumps(cfg))

# <head> tags crawlers read (they don't run config.js). Each must be found exactly once, or the deploy stops.
site = html.escape(env("SITE_URL").rstrip("/"), quote=True)
for name, path in (("index.html", "/"), ("launchpad.html", "/launchpad")):  # every page and the address it's served at
    tags = [
        (r'(<link rel="canonical" href=")[^"]*(")', site + path),
        (r'(<meta property="og:url" content=")[^"]*(")', site + path),
        (r'(<meta property="og:image" content=")https?://[^/"]+(/[^"]*")', site),
        (r'(<meta name="twitter:image" content=")https?://[^/"]+(/[^"]*")', site),
        (r'(<meta name="twitter:site" content=")[^"]*(")', "@" + handle if handle else ""),
    ]
    page = os.path.join(sys.argv[1], name)
    with open(page, encoding="utf-8", newline="") as f:
        doc = f.read()
    for pat, val in tags:
        doc, n = re.subn(pat, lambda m: m.group(1) + val + m.group(2), doc)
        if n != 1:
            sys.exit(f"web/{name}: expected one tag matching {pat}, found {n}")
    with open(page, "w", encoding="utf-8", newline="") as f:
        f.write(doc)
print("head tags set for", site)

# Cloudflare Pages reads caching rules from a _headers file: images for a day, the settings file always fresh
with open(os.path.join(sys.argv[1], "_headers"), "w", encoding="utf-8", newline="\n") as f:
    f.write("/assets/*\n  Cache-Control: public, max-age=86400\n\n/config.js\n  Cache-Control: no-cache\n")
EOF
# Pages serves launchpad.html at /launchpad on its own. Deploying a copy with no Git history keeps the commit out of it.
cd "$TMP"
npx --yes wrangler@4 pages deploy web --project-name "$PROJECT" --branch main --commit-dirty=true < /dev/null
echo "deployed: $SITE_URL"
