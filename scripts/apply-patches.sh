#!/usr/bin/env bash
# Applies the patch series (patches/series.conf) to the Proton source tree.
# Every patch is dry-run first, so a failing patch never leaves a half-applied tree.
set -euo pipefail

SRC_DIR="${SRC_DIR:?SRC_DIR is required}"
CI_DIR="${CI_DIR:?CI_DIR is required}"
OPTS_DIR="${OPTS_DIR:-/tmp/deadlock-opts}"
PROFILE="${PROFILE:-performance}"
STRICT="${STRICT:-false}"
SERIES="${SERIES:-$CI_DIR/patches/series.conf}"
REPORT="${REPORT:-$PWD/patch-report.md}"
APPLIED_LIST="${APPLIED_LIST:-$PWD/patches-applied.txt}"
CACHE_DIR="$(mktemp -d)"

tier_level() {
  case "$1" in
    stable) echo 1 ;;
    performance) echo 2 ;;
    aggressive) echo 3 ;;
    *) echo 0 ;;
  esac
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

want=$(tier_level "$PROFILE")
if [ "$want" -eq 0 ]; then
  echo "::error::Unknown profile '$PROFILE' (use stable, performance or aggressive)"
  exit 1
fi
if [ ! -f "$SERIES" ]; then
  echo "::error::Series file not found: $SERIES"
  exit 1
fi

: > "$APPLIED_LIST"
{
  echo "### Patch report (profile: \`$PROFILE\`)"
  echo
  echo "| Patch | Tier | Target | Result |"
  echo "|---|---|---|---|"
} > "$REPORT"
row() { printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >> "$REPORT"; }

applied=0
protocol_touched=0
fatal=0

while IFS='|' read -r name tier required target fuzz source || [ -n "${name:-}" ]; do
  name=$(trim "${name:-}")
  case "$name" in ''|'#'*) continue ;; esac
  tier=$(trim "${tier:-}"); required=$(trim "${required:-}")
  target=$(trim "${target:-}"); fuzz=$(trim "${fuzz:-0}"); source=$(trim "${source:-}")

  lvl=$(tier_level "$tier")
  if [ "$lvl" -eq 0 ]; then
    echo "::error::Patch '$name' has an invalid tier '$tier'"
    row "$name" "$tier" "$target" "FAILED (invalid tier)"
    fatal=1; break
  fi
  if [ "$lvl" -gt "$want" ]; then
    row "$name" "$tier" "$target" "skipped (profile)"
    continue
  fi

  case "$source" in
    opts:*)  file="$OPTS_DIR/${source#opts:}" ;;
    local:*) file="$CI_DIR/${source#local:}" ;;
    url:*)
      file="$CACHE_DIR/$name.patch"
      curl -fsSL --retry 3 --retry-delay 3 -o "$file" "${source#url:}" || file=""
      ;;
    *) file="" ;;
  esac

  dir="$SRC_DIR/$target"
  status=""
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    status="FAILED (patch file not found)"
  elif [ ! -d "$dir" ]; then
    status="FAILED (target dir '$target' missing)"
  elif patch -d "$dir" -p1 -R -f --dry-run --fuzz=0 < "$file" >/dev/null 2>&1; then
    status="already applied"
  elif patch -d "$dir" -p1 -f --dry-run --fuzz="$fuzz" < "$file" >/dev/null 2>&1; then
    patch -d "$dir" -p1 -f --no-backup-if-mismatch --fuzz="$fuzz" < "$file" >/dev/null
    status="applied"
  else
    status="FAILED (does not apply)"
    echo "==> $name: failing hunks (dry run, fuzz=$fuzz):"
    patch -d "$dir" -p1 -f --dry-run --fuzz="$fuzz" < "$file" 2>&1 \
      | grep -E 'FAILED|can.t find|Hunk' | tail -n 20 | sed 's/^/      /' || true
  fi

  echo "==> $name [$tier/$target]: $status"
  row "$name" "$tier" "$target" "$status"

  case "$status" in
    applied)
      applied=$((applied + 1))
      echo "$name" >> "$APPLIED_LIST"
      if [ "$target" = "wine" ] && grep -q 'server/protocol.def' "$file"; then
        protocol_touched=1
      fi
      ;;
    FAILED*)
      if [ "$required" = "yes" ] || [ "$STRICT" = "true" ]; then
        echo "::error::Patch '$name' failed and is required (or strict mode is on)."
        fatal=1; break
      fi
      echo "::warning::Optional patch '$name' skipped."
      ;;
  esac
done < "$SERIES"

[ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"

if [ "$fatal" -ne 0 ]; then
  exit 1
fi

if [ "$protocol_touched" -eq 1 ]; then
  if [ -x "$SRC_DIR/wine/tools/make_requests" ]; then
    echo "==> Regenerating wineserver protocol files..."
    (cd "$SRC_DIR/wine" && ./tools/make_requests)
  else
    echo "::error::server/protocol.def was patched but tools/make_requests is missing."
    exit 1
  fi
fi

echo "==> Done: $applied patch(es) newly applied for profile '$PROFILE'."
