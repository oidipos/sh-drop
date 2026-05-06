#!/usr/bin/env bash
#
# sh-drop — Fetch Spamhaus DROP lists and load them into ipsets atomically.
#

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
TMP_DIR="/home/ubuntu/sh-drop"
IPSET_V4="drop_v4"
IPSET_V6="drop_v6"
CHAIN_NAME="MAILCOW"  # iptables chain to hook into

# ─── Functions ────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  --skip-download   Skip downloading Spamhaus DROP lists; reuse cached files
  -h, --help        Show this help message
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 \
      || die "Required command '${cmd}' not found. Please install it."
  done
}

# Download a single blocklist, with basic validation.
download_list() {
  local name="$1"
  local url="https://www.spamhaus.org/drop/${name}.json"
  local dest="${TMP_DIR}/${name}.json"

  if ! curl -sSfL -o "${dest}" "${url}"; then
    die "Failed to download ${url}"
  fi

  # Sanity-check: the file must contain valid JSON with at least one entry.
  if ! jq -e 'length > 0' "${dest}" >/dev/null 2>&1; then
    die "Downloaded file ${dest} is empty or not valid JSON."
  fi
}

# Populate a temporary ipset from a JSON file, then atomically swap it in.
load_ipset() {
  local name="$1"      # e.g. drop_v4
  local family="$2"    # inet | inet6
  local json="${TMP_DIR}/${name}.json"
  local tmp_name="${name}_tmp"

  # Ensure the live set exists.
  if ! ipset list "$name" &>/dev/null; then
    echo "Creating ipset ${name} (${family})"
    ipset create "$name" hash:net family "$family"
  fi

  # (Re)create a temporary set to stage the new data.
  ipset destroy "$tmp_name" 2>/dev/null || true
  ipset create "$tmp_name" hash:net family "$family"

  # Populate the temporary set.
  local count=0
  while IFS= read -r cidr; do
    ipset add "$tmp_name" "$cidr"
    (( ++count ))
  done < <(jq -r 'select(.cidr != null) | .cidr' "$json")

  echo "Loaded ${count} entries into ${tmp_name}"

  # Atomic swap: the live set instantly contains the new data.
  ipset swap "$tmp_name" "$name"
  ipset destroy "$tmp_name"

  echo "Swapped ${tmp_name} → ${name}"
}

# Ensure an iptables/ip6tables rule sits at position 1 in the given chain.
ensure_rule_at_top() {
  local chain="$1"
  local rule="$2"
  local cmd="$3"  # iptables | ip6tables

  # shellcheck disable=SC2086
  if ! $cmd -C "$chain" $rule 2>/dev/null; then
    # Rule doesn't exist — insert at top.
    $cmd -I "$chain" 1 $rule
  else
    # Rule exists — check whether it's already the first rule.
    local first_rule
    first_rule=$($cmd -S "$chain" | sed -n '2p')
    if [[ "$first_rule" != *"$rule"* ]]; then
      $cmd -D "$chain" $rule
      $cmd -I "$chain" 1 $rule
    fi
  fi
}

# ─── Argument parsing ────────────────────────────────────────────────────────

skip_download=false

for arg in "$@"; do
  case "$arg" in
    --skip-download) skip_download=true ;;
    -h|--help)       show_help; exit 0  ;;
    *)               die "Unknown option: ${arg}" ;;
  esac
done

# ─── Main ─────────────────────────────────────────────────────────────────────

require_cmd curl jq ipset iptables ip6tables

mkdir -p "$TMP_DIR"

# 1. Obtain blocklists
if [[ "$skip_download" == true ]]; then
  echo "Skipping download — reusing cached files."
  for bl in drop_v4 drop_v6; do
    [[ -f "${TMP_DIR}/${bl}.json" ]] \
      || die "Cached file ${TMP_DIR}/${bl}.json does not exist."
  done
else
  echo "Downloading Spamhaus DROP lists…"
  download_list drop_v4
  download_list drop_v6
fi

# 2. Load ipsets atomically
echo "Loading ipsets…"
load_ipset "$IPSET_V4" inet
load_ipset "$IPSET_V6" inet6

# 3. Ensure iptables rules are in place
echo "Ensuring iptables rules…"
ensure_rule_at_top "$CHAIN_NAME" "-m set --match-set ${IPSET_V4} src -j DROP" iptables
ensure_rule_at_top "$CHAIN_NAME" "-m set --match-set ${IPSET_V6} src -j DROP" ip6tables

# 4. Persist ipset across reboots
ipset save > /etc/ipset.rules

echo ""
echo "Done. Inspect with: sudo ipset list | less"
