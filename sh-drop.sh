#!/bin/bash

# Adjust the values of the following variables
TMP_DIR="/home/ubuntu/sh-drop/"

show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "Options:"
  echo "  --skip-download      Skip downloading of Spamhaus DROP, use last output file"
  echo "  -h, --help           Show this help message"
}

SKIP_DOWNLOAD=false

for arg in "$@"; do
  case $arg in
    --skip-download)
      SKIP_DOWNLOAD=true
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $arg"
      show_help
      exit 1
      ;;
  esac
done

# Check if required packages are installed
for cmd in ipset jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd NOT found, please install package."
    exit 1
  fi
done

if [ "$SKIP_DOWNLOAD" = false ]
then
  echo "Retrieve IPs from Spamhaus DROP BL..."
  for bl in drop_v4 drop_v6; do
    curl -sG https://www.spamhaus.org/drop/${bl}.json \
      -o ${TMP_DIR}/${bl}.json

    # Capture the exit code
    exit_code=$?

    # Check for error
    if [ $exit_code -ne 0 ]; then
      echo "Curl encountered an error with exit code $exit_code while retrieving the Spamhaus DROP IPs."
      exit 1
    fi
  done
else
  for bl in drop_v4 drop_v6; do
    if [ ! -f ${TMP_DIR}/${bl}.json ]; then
      echo "Skipping download but file ${TMP_DIR}/${bl}.json does not exist."
      exit 1
    fi
  done
  echo "Skipping download of Spamhaus DROP BL."
fi

IPSET_V4="drop_v4"
IPSET_V6="drop_v6"

echo "Ensure ipsets exist"
# Create IPv4 ipset if missing
if ! ipset list $IPSET_V4 &>/dev/null; then
  echo "Creating ipset $IPSET_V4"
  ipset create $IPSET_V4 hash:net family inet
fi
# Create IPv6 ipset if missing
if ! ipset list $IPSET_V6 &>/dev/null; then
  echo "Creating ipset $IPSET_V6"
  ipset create $IPSET_V6 hash:net family inet6
fi

echo "Flush existing ipsets"
ipset flush $IPSET_V4
ipset flush $IPSET_V6

echo "Process entries and add to ipset"
while IFS= read -r ip; do
  ipset add $IPSET_V4 "$ip" 2>/dev/null
done < <(jq -r 'select(.cidr != null) | .cidr' ${TMP_DIR}/drop_v4.json)
while IFS= read -r ip; do
  ipset add $IPSET_V6 "$ip" 2>/dev/null
done < <(jq -r 'select(.cidr != null) | .cidr' ${TMP_DIR}/drop_v6.json)

echo "Ensure ip(6)tables rules exist at the top"

ensure_rule_at_top() {
  local chain=$1
  local rule=$2
  local cmd=$3  # iptables or ip6tables

  if ! $cmd -S $chain | grep -q -- "$rule"; then
    eval "$cmd -I $chain 1 $rule"  # Add rule if missing
  else
    FIRST_RULE=$($cmd -S $chain | sed -n '2p')
    if [[ "$FIRST_RULE" != *"$rule"* ]]; then
      eval "$cmd -D $chain $rule"  # Remove old rule
      eval "$cmd -I $chain 1 $rule"  # Reinsert at the top
    fi
  fi
}

# iptables variables
CHAIN_NAME="MAILCOW" # DO NOT CHANGE THIS UNTIL YOU KNOW WHAT YOU'RE DOING! :)

IPTABLES_RULE_V4="-m set --match-set $IPSET_V4 src -j DROP"
IPTABLES_RULE_V6="-m set --match-set $IPSET_V6 src -j DROP"

ensure_rule_at_top "$CHAIN_NAME" "$IPTABLES_RULE_V4" "iptables"
ensure_rule_at_top "$CHAIN_NAME" "$IPTABLES_RULE_V6" "ip6tables"

# Save ipset rules to persist across reboots
ipset save > /etc/ipset.rules

echo -e "\n\nDone.\n\nCheck current iplist entries with 'sudo ipset list | less'"
