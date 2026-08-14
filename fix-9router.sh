#!/usr/bin/env bash
# fix-9router.sh - Patch 9Router's compiled OpenCode Free executor to send the
# x-opencode-session / x-opencode-project / x-opencode-request headers and CLI
# User-Agent that the real opencode client sends. Without them, requests hit a
# shared anonymous quota and fail with "Free usage exceeded" after a couple calls.
#
# Run:
#   chmod +x fix-9router.sh
#   ./fix-9router.sh
#
# Then restart 9Router - the patch is loaded at startup.
#
# Safe: backs up the chunk to <file>.bak, patches by pattern, validates syntax
# after patching with node --check, and skips if already patched.

set -euo pipefail

info() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

chunk=""
tmp=""
backup=""

cleanup() {
  local rc=$?

  if [[ -n "$tmp" && -f "$tmp" ]]; then
    rm -f -- "$tmp" 2>/dev/null || true
  fi

  # If we failed after making a backup, try to restore the original file.
  if [[ $rc -ne 0 && -n "$backup" && -f "$backup" && -n "$chunk" && -f "$chunk" ]]; then
    cp -f -- "$backup" "$chunk" 2>/dev/null || true
    printf 'Restored backup due to failure.\n' >&2 || true
  fi
}

trap cleanup EXIT

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

command -v node >/dev/null 2>&1 || die "node not found. 9Router needs Node.js."

get_9router_install() {
  local root="" home c d

  home="${HOME:-}"

  # If running through sudo, try to find the invoking user's home directory too.
  if [[ -z "$home" && -n "${SUDO_USER:-}" ]]; then
    home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)
  fi

  if command -v npm >/dev/null 2>&1; then
    root=$(npm root -g 2>/dev/null | head -n 1 || true)
    root=$(trim "$root")
  fi

  local candidates=()

  if [[ -n "$root" ]]; then
    candidates+=("$root/9router")
  fi

  if [[ -n "$home" ]]; then
    candidates+=("$home/.npm-global/lib/node_modules/9router")
    candidates+=("$home/.local/lib/node_modules/9router")

    # nvm layouts
    for d in "$home"/.nvm/versions/node/*/lib/node_modules/9router; do
      if [[ -d "$d" ]]; then
        candidates+=("$d")
      fi
    done
  fi

  # Common system-wide locations
  candidates+=(
    "/usr/local/lib/node_modules/9router"
    "/usr/lib/node_modules/9router"
    "/opt/homebrew/lib/node_modules/9router"
    "/home/linuxbrew/.linuxbrew/lib/node_modules/9router"
  )

  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -d "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done

  return 1
}

find_executor_chunk() {
  local base="$1"
  local needle='Authorization:"Bearer public"'
  local dirs=(
    "$base/app/.next-cli-build/server/chunks"
    "$base/app/.next/server/chunks"
    "$base/app/.next-cli-build/server"
  )
  local dir hit

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue

    hit=$(
      grep -R -l -F --include='*.js' -- "$needle" "$dir" 2>/dev/null |
        head -n 1 || true
    )

    if [[ -n "$hit" ]]; then
      printf '%s\n' "$hit"
      return 0
    fi
  done

  return 1
}

install=$(get_9router_install) ||
  die "9Router install not found. Is it installed via npm (npm i -g 9router)?"

info "9Router install: $install"

chunk=$(find_executor_chunk "$install") ||
  die "opencode executor chunk not found under $install/app/.next-cli-build"

info "Found chunk: $chunk"

if grep -qF -- '"x-opencode-session"' "$chunk"; then
  info "Already patched - nothing to do."
  exit 0
fi

tmp=$(mktemp "${chunk}.patch.XXXXXX") ||
  die "Could not create temporary file."

rc=0

# Use Node itself for the regex replacement because 9Router already requires Node.
# Exit codes:
#   0 = patched tmp file successfully
#   2 = buildHeaders signature not found
#   3 = replacement produced no change
#   4 = read/write failure
CHUNK="$chunk" TMP="$tmp" node - <<'NODE' || rc=$?
const fs = require('fs');

const input = process.env.CHUNK;
const output = process.env.TMP;

if (!input || !output) {
  process.exit(4);
}

let content;
try {
  content = fs.readFileSync(input, 'utf8');
} catch (e) {
  process.exit(4);
}

const re = /(buildHeaders\(\)\{)(return\{"Content-Type":"application\/json",Authorization:"Bearer public","x-opencode-client":"desktop",)(Accept:)([^}]*)(\}\})/g;

if (!re.test(content)) {
  process.exit(2);
}

// Reset global regex state before replace.
re.lastIndex = 0;

const injected =
  'var _s=this._sid||(this._sid="ses_"+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2)),_p=this._pid||(this._pid="p_"+Math.random().toString(36).slice(2)+Math.random().toString(36).slice(2));';

const extraHeaders =
  '"x-opencode-session":_s,"x-opencode-project":_p,"x-opencode-request":_s+":"+Date.now()+":"+Math.random().toString(36).slice(2),"User-Agent":"opencode/1.17.0",';

const patched = content.replace(re, (m, p1, p2, p3, p4, p5) => {
  return p1 + injected + p2 + extraHeaders + p3 + p4 + p5;
});

if (patched === content) {
  process.exit(3);
}

try {
  fs.writeFileSync(output, patched, 'utf8');
} catch (e) {
  process.exit(4);
}

process.exit(0);
NODE

case "$rc" in
  0)
    ;;
  2)
    die "buildHeaders signature not found in this version. No changes made."
    ;;
  3)
    die "replacement produced no change. No changes made."
    ;;
  4)
    die "could not read/write patch files."
    ;;
  *)
    die "patch failed (node exit code $rc)."
    ;;
esac

if [[ ! -s "$tmp" ]]; then
  die "patch output is empty."
fi

backup="$chunk.bak"
cp -f -- "$chunk" "$backup" || die "Failed to create backup."
info "Backup: $backup"

cat "$tmp" > "$chunk" || die "Failed to write patched chunk."
rm -f -- "$tmp"
tmp=""

# Validate syntax with the same Node that runs 9Router.
if ! node --check "$chunk"; then
  if cp -f -- "$backup" "$chunk"; then
    backup=""
  fi
  die "syntax check failed - restored backup."
fi

info "Syntax check: OK"

echo
info "PATCHED. Restart 9Router (or restart the tray app) for it to take effect."
info "Note: 'npm i -g 9router@latest' will overwrite this fix - re-run the script after updating."
