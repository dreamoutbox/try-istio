#!/usr/bin/env bash
# Run every phase in order. Prefer running phases one at a time (PAUSE=1) when learning.
set -euo pipefail
cd "$(dirname "$0")"
for f in [0-9][0-9]-*.sh; do
  if [[ "$f" == "99-teardown.sh" ]]; then
    continue
  fi
  printf '\n\033[1;35m######## %s ########\033[0m\n' "$f"
  ./"$f"
done
