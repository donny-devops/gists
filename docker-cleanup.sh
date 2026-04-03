#!/usr/bin/env bash
# =============================================================================
# docker-cleanup.sh
# Safe Docker system pruning script with before/after disk usage report.
#
# Usage:
#   ./docker-cleanup.sh           # Interactive (asks before each step)
#   ./docker-cleanup.sh --force   # Non-interactive (CI/cron safe)
#   ./docker-cleanup.sh --dry-run # Show what would be removed, don't remove
#
# What it cleans:
#   - Stopped containers
#   - Dangling images (untagged)
#   - Unused volumes
#   - Unused networks
#   - Build cache (optional)
# =============================================================================

set -euo pipefail

FORCE=false
DRY_RUN=false

# Parse flags
for arg in "$@"; do
  case $arg in
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown flag: $arg" && exit 1 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
header()  { echo -e "\n${GREEN}==>${NC} $*"; }

confirm() {
  local prompt="$1"
  if [[ "$FORCE" == true ]]; then return 0; fi
  read -rp "$prompt [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

check_docker() {
  if ! command -v docker &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Docker is not installed or not in PATH."
    exit 1
  fi
  if ! docker info &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Docker daemon is not running."
    exit 1
  fi
}

disk_usage() {
  docker system df --format 'table {{.Type}}\t{{.Size}}\t{{.Reclaimable}}'
}

main() {
  check_docker

  header "Docker Cleanup Script"
  [[ "$DRY_RUN" == true ]] && warn "DRY RUN mode — nothing will be deleted."

  echo ""
  log "Disk usage BEFORE cleanup:"
  disk_usage

  # 1. Stopped containers
  header "Stopped Containers"
  STOPPED=$(docker ps -aq --filter status=exited --filter status=dead | wc -l | tr -d ' ')
  if [[ "$STOPPED" -gt 0 ]]; then
    log "Found $STOPPED stopped container(s)."
    if confirm "Remove stopped containers?"; then
      [[ "$DRY_RUN" == false ]] && docker container prune -f
      success "Removed stopped containers."
    fi
  else
    log "No stopped containers found."
  fi

  # 2. Dangling images
  header "Dangling Images"
  DANGLING=$(docker images -q --filter dangling=true | wc -l | tr -d ' ')
  if [[ "$DANGLING" -gt 0 ]]; then
    log "Found $DANGLING dangling image(s)."
    if confirm "Remove dangling images?"; then
      [[ "$DRY_RUN" == false ]] && docker image prune -f
      success "Removed dangling images."
    fi
  else
    log "No dangling images found."
  fi

  # 3. Unused volumes
  header "Unused Volumes"
  VOLUMES=$(docker volume ls -q --filter dangling=true | wc -l | tr -d ' ')
  if [[ "$VOLUMES" -gt 0 ]]; then
    warn "Found $VOLUMES unused volume(s). This may include data — review before removing."
    if confirm "Remove unused volumes?"; then
      [[ "$DRY_RUN" == false ]] && docker volume prune -f
      success "Removed unused volumes."
    fi
  else
    log "No unused volumes found."
  fi

  # 4. Unused networks
  header "Unused Networks"
  if confirm "Remove unused networks (bridge, host, none are always kept)?"; then
    [[ "$DRY_RUN" == false ]] && docker network prune -f
    success "Removed unused networks."
  fi

  # 5. Build cache (opt-in)
  header "Build Cache"
  CACHE=$(docker buildx du 2>/dev/null | tail -1 || echo "unknown")
  log "Build cache size: $CACHE"
  if confirm "Remove build cache?"; then
    [[ "$DRY_RUN" == false ]] && docker buildx prune -f
    success "Cleared build cache."
  fi

  echo ""
  log "Disk usage AFTER cleanup:"
  disk_usage
  success "Docker cleanup complete."
}

main "$@"
