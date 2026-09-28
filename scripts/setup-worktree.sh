#!/usr/bin/env bash
# Orca worktree setup hook for crystalfaux.
#
# plans/ is git-ignored and lives only in the main checkout. Every linked
# worktree gets a symlink to it so agents and humans share one set of plans.
# Configure this script as the repo's setup hook in Orca (Settings > Repos >
# crystalfaux > Setup script: scripts/setup-worktree.sh), or run it by hand
# from inside any worktree.
set -euo pipefail

# Resolve the worktree from the current directory so the script also works when
# invoked from another checkout's copy; fall back to the script's own checkout.
worktree_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "$worktree_root" ]]; then
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  worktree_root=$(git -C "$script_dir/.." rev-parse --show-toplevel)
fi
# Git lists the main worktree first. Preserve spaces in its path.
main_root=$(git -C "$worktree_root" worktree list --porcelain | sed -n '1s/^worktree //p')
plans_source="$main_root/plans"
plans_target="$worktree_root/plans"

if [[ ! -d "$plans_source" ]]; then
  printf 'Missing main-worktree plans directory: %s\n' "$plans_source" >&2
  exit 1
fi

if [[ "$worktree_root" != "$main_root" ]]; then
  if [[ -L "$plans_target" && "$plans_target" -ef "$plans_source" ]]; then
    printf 'Plans already linked to %s\n' "$plans_source"
  elif [[ -e "$plans_target" || -L "$plans_target" ]]; then
    printf 'Refusing to replace existing plans path: %s\n' "$plans_target" >&2
    exit 1
  else
    ln -s "$plans_source" "$plans_target"
    printf 'Linked plans to %s\n' "$plans_source"
  fi
fi

cd -- "$worktree_root"
if [[ -f shard.yml ]]; then
  shards install
fi
