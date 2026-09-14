#!/bin/bash

# Headless tests for the listingValidatedCommit pin: missing/malformed SHA
# refuses; a valid SHA takes the pinned install (and catalog-context update)
# path. Dry-run only — no network, no real omarchy plugin commands.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
TUI=$ROOT/bin/fast-plugin-tui-omarchy
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fpto-pin.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

PIN=0123456789abcdef0123456789abcdef01234567
SHORT=${PIN:0:7}

mkdir -p "$WORK/bin" "$WORK/cache" "$WORK/seed" "$WORK/plugins"
export PATH="$WORK/bin:$PATH"
export XDG_CACHE_HOME="$WORK/cache"
export FAST_PLUGIN_TUI_OMARCHY_DRY_RUN=1
export FAST_PLUGIN_TUI_OMARCHY_CATALOG_URL="file://$WORK/seed/catalog.json"
export FAST_PLUGIN_TUI_OMARCHY_STATS_URL="file://$WORK/seed/stats.json"
export FAST_PLUGIN_TUI_OMARCHY_PLUGINS_DIR="$WORK/plugins"

printf '%s\n' '#!/bin/bash' 'exit 0' >"$WORK/bin/omarchy-git-url-check"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$WORK/bin/omarchy-show-done"
printf '%s\n' '#!/bin/bash' 'echo "[]"' >"$WORK/bin/omarchy-plugin-list"
chmod +x "$WORK/bin/omarchy-git-url-check" "$WORK/bin/omarchy-show-done" "$WORK/bin/omarchy-plugin-list"
printf '{"plugins":{}}\n' >"$WORK/seed/stats.json"

pass=0 fail=0
declare -a REPORT=()

ok() { pass=$((pass + 1)); REPORT+=("PASS | $1"); echo "PASS $1"; }
bad() { fail=$((fail + 1)); REPORT+=("FAIL | $1 | $2"); echo "FAIL $1 — $2"; }

make_catalog() {
  jq -n --argjson extra "$1" '{
    plugins: [
      {
        id: "example.pinned",
        name: "Pinned Example",
        author: "Test",
        repo: "https://github.com/example/pinned-plugin",
        sourceType: "community",
        installAvailable: true,
        installCommand: "omarchy plugin add https://github.com/example/pinned-plugin",
        status: "active",
        category: "System",
        kind: "service",
        tags: ["test"],
        stars: 1
      } + $extra
    ]
  }' >"$WORK/seed/catalog.json"
}

refresh() {
  rm -rf "$WORK/cache/fast-plugin-tui-omarchy"
  mkdir -p "$WORK/cache"
  "$TUI" __refresh-cache </dev/null >/dev/null
}

install_out() {
  "$TUI" __install example.pinned </dev/null 2>&1 || true
}

update_out() {
  "$TUI" __update example.pinned </dev/null 2>&1 || true
}

mark_installed() {
  mkdir -p "$WORK/plugins/example.pinned/.git"
  printf 'example.pinned\ttrue\n' >"$WORK/cache/fast-plugin-tui-omarchy/installed.tsv"
}

# --- missing SHA → refuse ---
make_catalog '{}'
refresh
out=$(install_out)
if [[ $out == *'refusing to install without a 40-character listingValidatedCommit'* && $out != *omarchy-plugin-add* ]]; then
  ok "install missing SHA refuses (no add)"
else
  bad "install missing SHA refuses (no add)" "$out"
fi

# --- malformed SHAs → refuse ---
for extra in \
  '{"listingValidatedCommit":"deadbeef"}' \
  '{"listingValidatedCommit":"0123456789ABCDEF0123456789ABCDEF01234567"}' \
  '{"listingValidatedCommit":"0123456789abcdef0123456789abcdef0123456"}' \
  '{"listingValidatedCommit":"0123456789abcdef0123456789abcdef012345678"}' \
  '{"listingValidatedCommit":"not-a-commit"}'
do
  make_catalog "$extra"
  refresh
  out=$(install_out)
  if [[ $out == *'refusing to install without a 40-character listingValidatedCommit'* && $out != *omarchy-plugin-add* ]]; then
    ok "install malformed SHA refuses ($extra)"
  else
    bad "install malformed SHA refuses ($extra)" "$out"
  fi
done

# --- valid SHA → pinned install path ---
make_catalog "$(jq -n --arg sha "$PIN" '{listingValidatedCommit: $sha}')"
refresh
out=$(install_out)
if [[ $out == *'[dry-run] omarchy-plugin-add https://github.com/example/pinned-plugin --yes'* &&
      $out == *'checkout --detach '"$PIN"* &&
      $out == *'[dry-run] omarchy-plugin-enable example.pinned'* &&
      $out != *'omarchy-plugin-add https://github.com/example/pinned-plugin --enable'* ]]; then
  ok "install valid SHA pins then enables (no --enable on add)"
else
  bad "install valid SHA pins then enables (no --enable on add)" "$out"
fi

# preview shows the short pin
prev=$("$TUI" __preview example.pinned </dev/null 2>/dev/null || true)
if [[ $prev == *$SHORT* ]]; then
  ok "preview shows short validated SHA"
else
  bad "preview shows short validated SHA" "$prev"
fi

# --- update without pin → refuse ---
make_catalog '{}'
refresh
mark_installed
out=$(update_out)
if [[ $out == *'refusing to update without a 40-character listingValidatedCommit'* && $out != *omarchy-plugin-update* ]]; then
  ok "update missing SHA refuses (no HEAD pull)"
else
  bad "update missing SHA refuses (no HEAD pull)" "$out"
fi

# --- update with pin → catalog SHA, not omarchy-plugin-update ---
make_catalog "$(jq -n --arg sha "$PIN" '{listingValidatedCommit: $sha}')"
refresh
mark_installed
out=$(update_out)
if [[ $out == *'checkout --detach '"$PIN"* && $out != *omarchy-plugin-update* ]]; then
  ok "update valid SHA pins to catalog commit"
else
  bad "update valid SHA pins to catalog commit" "$out"
fi

echo
printf '%s\n' "${REPORT[@]}"
echo
echo "passed: $pass  failed: $fail"
(( fail == 0 ))
