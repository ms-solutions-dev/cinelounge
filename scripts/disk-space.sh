#!/usr/bin/env bash
# Refuses to start a check run when the disk is nearly full.
#
# A full run builds every package on its own, in debug and in release — one
# working copy holds 15 GB of build folders. Running out of space halfway
# through ends in a cascade of unrelated build errors after forty minutes
# (2026-11-09); stopping at the start with the biggest build folders listed
# is cheaper.
#
#   scripts/disk-space.sh            exit 1 below CL_MIN_FREE_GB (default 20)
#   CL_MIN_FREE_GB=0 ./scripts/...   switches the check off
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
need="${CL_MIN_FREE_GB:-20}"
[ "$need" -le 0 ] 2>/dev/null && exit 0

free_kb=$(df -Pk "$root" | awk 'NR==2 {print $4}')
free_gb=$((free_kb / 1048576))
[ "$free_gb" -ge "$need" ] && exit 0

printf '\033[31m✗\033[0m only %s GB free, a full run needs about %s GB (CL_MIN_FREE_GB).\n' "$free_gb" "$need"
printf '  Largest build folders in this working copy:\n'
find "$root" \( -name .git -o -name node_modules \) -prune -o \
    -type d \( -name .build -o -name '.dd*' -o -name DerivedData \) -print -prune 2>/dev/null |
    while IFS= read -r d; do du -sk "$d" 2>/dev/null; done |
    sort -rn | head -8 |
    awk -v r="$root/" '{p=$2; sub(r, "", p); printf "    %5.1f GB  %s\n", $1/1048576, p}'
printf '  Build folders can be deleted safely; the next run recreates them.\n'
exit 1
