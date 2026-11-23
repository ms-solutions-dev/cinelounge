#!/usr/bin/env bash
# Checks both programs one after the other: first the TV (root directory), then
# the phone (`Phone/`). Green only if BOTH are green.
#
# Since the merge (decision 17, 2026-09-26) both live in one repo, and the shared
# packages under `Packages/` carry both programs. A change there can break the
# phone without the TV run noticing anything — hence this one call for both.
#
# **One after the other, never at the same time:** Both runs compile the same
# shared packages and build in the simulator; in parallel they disturb each other.
set -uo pipefail
cd "$(dirname "$0")/.."

# Space for both runs is checked once here; the two runs then skip their own check.
./scripts/disk-space.sh || exit 1
export CL_MIN_FREE_GB=0

./scripts/check.sh
tv=$?

./Phone/scripts/check.sh
phone=$?

# **grundstock carries both programs and the reading app** (AP58, finding A14): Its
# `swift test` did not run in either of the two runs until 2026-09-26. The path is
# the same one `Packages/Core/Package.swift` pulls in — so this run checks exactly
# the version both programs were built against.
printf '\n\033[1m▸ grundstock\033[0m\n'
grundstock_dir="Packages/Grundstock"
if [ -f "$grundstock_dir/Package.swift" ]; then
    gs_out=$( (cd "$grundstock_dir" && swift test 2>&1) )
    if printf '%s' "$gs_out" | grep -q "Test run with .* passed"; then
        gs=0
        printf '  \033[32m✓\033[0m %s\n' "$(printf '%s' "$gs_out" | grep -oE "Test run with [0-9]+ tests?" | head -1)"
    else
        gs=1
        printf '%s\n' "$gs_out" | grep -E "error:|✘|failed" | head -12
        printf '  \033[31m✗\033[0m grundstock\n'
    fi
else
    gs=1
    printf '  \033[31m✗\033[0m grundstock missing under %s\n' "$grundstock_dir"
fi

# **Local additions** (optional): `checks.local.sh` in the root. Both runs above already read
# its settings (spec, extra packages); called here with `run`, it adds its own steps. Its exit
# code counts like a third program.
local_rc=0
if [ -f ./checks.local.sh ]; then
    printf '\n\033[1m▸ Local checks\033[0m\n'
    bash ./checks.local.sh run
    local_rc=$?
fi

printf '\n\033[1m▸ Both programs\033[0m\n'
[ $tv -eq 0 ] && printf '  \033[32m✓\033[0m TV\n' || printf '  \033[31m✗\033[0m TV (exit %s)\n' "$tv"
[ $phone -eq 0 ] && printf '  \033[32m✓\033[0m Phone\n' || printf '  \033[31m✗\033[0m Phone (exit %s)\n' "$phone"
[ $gs -eq 0 ] && printf '  \033[32m✓\033[0m grundstock\n' || printf '  \033[31m✗\033[0m grundstock\n'
[ -f ./checks.local.sh ] && { [ $local_rc -eq 0 ] && printf '  \033[32m✓\033[0m local checks\n' || printf '  \033[31m✗\033[0m local checks (exit %s)\n' "$local_rc"; }

if [ $tv -eq 0 ] && [ $phone -eq 0 ] && [ $gs -eq 0 ] && [ $local_rc -eq 0 ]; then
    printf '\033[32m✓ All green.\033[0m\n'
    exit 0
fi
printf '\033[31m✗ At least one part is red — see above.\033[0m\n'
exit 1
