#!/usr/bin/env bash
# Transitional import for installed legacy callers; no independent defaults.
# shellcheck source=scripts/lib/haven-env.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/haven-env.sh"
for _haven_alias in ${!HAVEN_@}; do
  printf -v "HYBRID_AI_${_haven_alias#HAVEN_}" '%s' "${!_haven_alias}"
  export "HYBRID_AI_${_haven_alias#HAVEN_}"
done
unset _haven_alias
