#!/usr/bin/env bash
#
# Watch the workload route tables and print a timestamped line every time the
# firewall next-hop changes.
#
# Run this in a SECOND terminal window while you suspend the active firewall.
# You will see, live, the exact moment AWS re-points the routes at the other
# node -- which is the thing a failover test is actually proving.
#
#   ./scripts/watch-failover.sh
#
# Press Ctrl-C to stop. This script only reads; it changes nothing.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
die()   { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v terraform >/dev/null || die "terraform not found on PATH"
command -v aws       >/dev/null || die "aws CLI not found on PATH"
command -v python3   >/dev/null || die "python3 not found on PATH"

# terraform exits 0 with empty output when the state has no outputs yet, so
# every read below is checked for emptiness rather than for exit status.
NO_STATE="no Terraform outputs found in $(pwd) -- run ./deploy.sh first, or wait for it to finish applying"

REGION=$(terraform output -raw region 2>/dev/null || true)
[ -n "$REGION" ] || die "$NO_STATE"

RTBS=$(terraform output -json failover_route_table_ids 2>/dev/null \
       | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))' 2>/dev/null || true)
[ -n "$RTBS" ] || die "$NO_STATE"

# "eni-abc name" per line, so we can label the next hop with the firewall it
# belongs to. bash 3.2 on macOS has no associative arrays, hence the lookup fn.
ENI_MAP=$(terraform output -json trust_eni_ids 2>/dev/null \
          | python3 -c 'import json,sys; [print(v,k) for k,v in json.load(sys.stdin).items()]' 2>/dev/null || true)
[ -n "$ENI_MAP" ] || die "$NO_STATE"

name_for() {
  local want="$1" line
  while IFS= read -r line; do
    if [ "${line%% *}" = "$want" ]; then printf '%s' "${line#* }"; return; fi
  done <<< "$ENI_MAP"
  printf '%s' "not-a-firewall-eni"
}

snapshot() {
  aws ec2 describe-route-tables --region "$REGION" --route-table-ids $RTBS \
    --query 'RouteTables[].Routes[?NetworkInterfaceId!=`null`].[DestinationCidrBlock,NetworkInterfaceId]' \
    --output text 2>/dev/null | sort | tr '\t' ' '
}

bold "Watching failover route tables in $REGION"
dim  "  route tables:"
for r in $RTBS; do dim "    $r"; done
dim  "  trust ENIs (the possible next hops):"
while IFS= read -r line; do dim "    ${line#* }  ${line%% *}"; done <<< "$ENI_MAP"
echo
dim "Polling every 2s. Ctrl-C to stop. Nothing is modified."
echo

PREV=""
PREV_AT=0

while true; do
  CUR=$(snapshot || true)

  if [ -z "$CUR" ]; then
    printf '\033[33m[%s] no firewall routes returned (transient API error?)\033[0m\n' "$(date '+%H:%M:%S')"
    sleep 2
    continue
  fi

  if [ "$CUR" != "$PREV" ]; then
    NOW=$(date +%s)
    TS=$(date '+%H:%M:%S')
    if [ -z "$PREV" ]; then
      bold "[$TS] baseline -- routes currently point at:"
    else
      green "[$TS] *** ROUTES MOVED *** ($((NOW - PREV_AT))s since the last change)"
    fi
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      printf '           %-18s -> %s  (%s)\n' "${r%% *}" "${r##* }" "$(name_for "${r##* }")"
    done <<< "$CUR"
    echo
    PREV="$CUR"
    PREV_AT=$NOW
  fi

  sleep 2
done
