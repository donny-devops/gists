#!/usr/bin/env bash
# =============================================================================
# git-branch-cleanup.sh
# Clean up stale Git branches — both local and remote — safely.
#
# What it does:
#   1. Fetches latest refs from origin (with --prune)
#   2. Lists branches merged into main/master
#   3. Optionally lists branches with no activity for N days
#   4. Confirms before deleting each batch
#   5. Never deletes protected branches (main, master, develop, release/*)
#
# Usage:
#   ./git-branch-cleanup.sh               # Interactive cleanup
#   ./git-branch-cleanup.sh --force        # Skip confirmation prompts
#   ./git-branch-cleanup.sh --merged-only  # Only remove merged branches
#   ./git-branch-cleanup.sh --stale-days 60  # Stale threshold in days (default: 90)
#
# Run from inside a Git repository.
# =============================================================================

set -euo pipefail

# Defaults
FORCE=false
MERGED_ONLY=false
STALE_DAYS=90

# Parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --force)        FORCE=true ;;
    --merged-only)  MERGED_ONLY=true ;;
    --stale-days)   STALE_DAYS="$2"; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
err()     { echo -e "${RED}[ERR]${NC}   $*" >&2; }

# Protected branches — NEVER delete these
PROTECTED_PATTERN="^(main|master|develop|staging|release/.*)$"

confirm() {
  [[ "$FORCE" == true ]] && return 0
  read -rp "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

is_protected() {
  [[ "$1" =~ $PROTECTED_PATTERN ]]
}

check_git_repo() {
  if ! git rev-parse --git-dir &>/dev/null; then
    err "Not inside a Git repository."
    exit 1
  fi
}

detect_default_branch() {
  # Try to detect the default branch from origin
  local default
  default=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}') || true
  if [[ -z "$default" ]]; then
    # Fallback: check if main or master exists
    if git show-ref --quiet refs/heads/main; then
      default="main"
    elif git show-ref --quiet refs/heads/master; then
      default="master"
    else
      default="main"
    fi
  fi
  echo "$default"
}

fetch_and_prune() {
  log "Fetching from origin and pruning deleted remote branches..."
  git fetch origin --prune --quiet
  success "Fetch complete."
}

get_merged_branches() {
  local base_branch="$1"
  git branch --merged "origin/${base_branch}" \
    | grep -v "^\*" \
    | sed 's/^[[:space:]]*//' \
    | grep -Ev "$PROTECTED_PATTERN" \
    || true
}

get_stale_local_branches() {
  local cutoff_date
  cutoff_date=$(date -d "-${STALE_DAYS} days" +%Y-%m-%d 2>/dev/null \
    || date -v "-${STALE_DAYS}d" +%Y-%m-%d)  # macOS fallback

  while IFS= read -r branch; do
    local last_commit
    last_commit=$(git log -1 --format="%ci" "$branch" 2>/dev/null | cut -d' ' -f1) || continue
    if [[ "$last_commit" < "$cutoff_date" ]]; then
      echo "$branch  (last commit: $last_commit)"
    fi
  done < <(git branch | grep -v "^\*" | sed 's/^[[:space:]]*//' | grep -Ev "$PROTECTED_PATTERN" || true)
}

delete_local_branches() {
  local branches=("$@")
  [[ ${#branches[@]} -eq 0 ]] && return
  log "Deleting ${#branches[@]} local branch(es)..."
  for branch in "${branches[@]}"; do
    branch=$(echo "$branch" | awk '{print $1}')  # Strip trailing metadata
    if is_protected "$branch"; then
      warn "Skipping protected branch: ${branch}"
      continue
    fi
    git branch -d "$branch" 2>/dev/null \
      || git branch -D "$branch"  # Force-delete if unmerged (user confirmed)
    success "Deleted local branch: ${branch}"
  done
}

delete_remote_branches() {
  local branches=("$@")
  [[ ${#branches[@]} -eq 0 ]] && return
  log "Deleting ${#branches[@]} remote branch(es) from origin..."
  for branch in "${branches[@]}"; do
    branch=$(echo "$branch" | awk '{print $1}')
    if is_protected "$branch"; then
      warn "Skipping protected branch: ${branch}"
      continue
    fi
    git push origin --delete "$branch" --quiet 2>/dev/null && success "Deleted remote: origin/${branch}" \
      || warn "Could not delete remote branch: ${branch} (may not exist remotely)"
  done
}

main() {
  check_git_repo

  local default_branch
  default_branch=$(detect_default_branch)
  log "Default branch detected: ${default_branch}"

  fetch_and_prune

  # ── Merged Branches ──────────────────────────────────────────────────────
  echo ""
  log "Branches merged into '${default_branch}':"
  mapfile -t MERGED < <(get_merged_branches "$default_branch")

  if [[ ${#MERGED[@]} -eq 0 ]]; then
    log "No merged branches to clean up."
  else
    printf '  %s\n' "${MERGED[@]}"
    if confirm "\nDelete these ${#MERGED[@]} merged local branch(es)?"; then
      delete_local_branches "${MERGED[@]}"
    fi
    if confirm "Delete these ${#MERGED[@]} merged remote branch(es) from origin?"; then
      delete_remote_branches "${MERGED[@]}"
    fi
  fi

  # ── Stale Branches ───────────────────────────────────────────────────────
  if [[ "$MERGED_ONLY" == false ]]; then
    echo ""
    log "Stale local branches (no commits in ${STALE_DAYS}+ days):"
    mapfile -t STALE < <(get_stale_local_branches)

    if [[ ${#STALE[@]} -eq 0 ]]; then
      log "No stale branches found."
    else
      printf '  %s\n' "${STALE[@]}"
      warn "These branches have had no activity in ${STALE_DAYS}+ days."
      if confirm "\nDelete these ${#STALE[@]} stale local branch(es)?"; then
        delete_local_branches "${STALE[@]}"
      fi
      if confirm "Delete these ${#STALE[@]} stale remote branch(es) from origin?"; then
        delete_remote_branches "${STALE[@]}"
      fi
    fi
  fi

  echo ""
  success "Git branch cleanup complete."
  log "Current branches:"
  git branch -v
}

main "$@"
