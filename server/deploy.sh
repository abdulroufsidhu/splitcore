#!/usr/bin/env bash
# Ship the server to production.
#
# The box has under 1 GB of RAM and would OOM part-way through a Go build,
# so the image is built here and copied over as a tarball rather than built
# there. That is the whole reason this is a script and not `git push`.
#
#   ./server/deploy.sh            # backup, build, ship, restart, verify
#   ./server/deploy.sh -y         # no confirmation prompt
#   ./server/deploy.sh --no-backup
#
# Override the target with environment variables:
#   DEPLOY_HOST=ubuntu@host  DEPLOY_DIR=~/splitcore  DEPLOY_URL=https://...
set -euo pipefail

DEPLOY_HOST="${DEPLOY_HOST:-ubuntu@168.138.75.8}"
DEPLOY_DIR="${DEPLOY_DIR:-~/splitcore}"
DEPLOY_URL="${DEPLOY_URL:-https://splitcore.orgolink.ch}"
IMAGE="${IMAGE:-splitcore-server:latest}"
VOLUME="${VOLUME:-splitcore_pb_data}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assume_yes=false
do_backup=true
for arg in "$@"; do
  case "$arg" in
    -y|--yes) assume_yes=true ;;
    --no-backup) do_backup=false ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------
# 0 — what is about to be deployed
# ---------------------------------------------------------------------
cd "$REPO_ROOT"
step "0/5  target"
echo "  host   $DEPLOY_HOST"
echo "  url    $DEPLOY_URL"
echo "  commit $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"

# The build copies the working tree, not HEAD, so uncommitted work ships
# too. Worth knowing before it does.
if [ -n "$(git status --porcelain)" ]; then
  printf '\033[33m  working tree is dirty — those changes will ship\033[0m\n'
fi

if [ "$assume_yes" = false ]; then
  read -r -p "Deploy to production? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || fail "aborted"
fi

# ---------------------------------------------------------------------
# 1 — back up the live database first
# ---------------------------------------------------------------------
if [ "$do_backup" = true ]; then
  step "1/5  backup"
  # shellcheck disable=SC2029  # the variables are meant to expand locally
  ssh "$DEPLOY_HOST" "TS=\$(date +%Y%m%d_%H%M%S); \
    docker run --rm -v $VOLUME:/d:ro -v /home/ubuntu:/b alpine \
      tar czf /b/pb_data_backup_\$TS.tgz -C /d . \
    && ls -lh /home/ubuntu/pb_data_backup_\$TS.tgz"
else
  step "1/5  backup (skipped)"
fi

# ---------------------------------------------------------------------
# 2 — build locally
# ---------------------------------------------------------------------
step "2/5  build"
before="$(docker images --no-trunc --format '{{.ID}}' "$IMAGE" 2>/dev/null || true)"
docker build -f server/Dockerfile -t "$IMAGE" .
after="$(docker images --no-trunc --format '{{.ID}}' "$IMAGE")"

if [ "$before" = "$after" ]; then
  # Not fatal — re-deploying an unchanged image is a legitimate thing to
  # want — but it is also exactly what a forgotten `git commit` looks like.
  printf '\033[33m  image is unchanged (%s) — nothing new was built\033[0m\n' "${after:0:19}"
else
  echo "  built ${after:0:19}"
fi

# ---------------------------------------------------------------------
# 3 — ship it
# ---------------------------------------------------------------------
step "3/5  ship"
docker save "$IMAGE" | gzip -1 | ssh "$DEPLOY_HOST" 'gunzip | docker load'

# ---------------------------------------------------------------------
# 4 — restart
# ---------------------------------------------------------------------
step "4/5  restart"
# shellcheck disable=SC2029
ssh "$DEPLOY_HOST" "cd $DEPLOY_DIR && docker compose up -d && sleep 12 && \
  docker ps --filter name=splitcore-server --format '{{.Names}}\t{{.Status}}\t{{.Image}}'"

# ---------------------------------------------------------------------
# 5 — verify the new binary is the one answering
# ---------------------------------------------------------------------
step "5/5  verify"
code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "$DEPLOY_URL$2"; }

health="$(code GET /api/health)"
echo "  health                 $health"
[ "$health" = "200" ] || fail "server is not healthy — check 'docker compose logs' on the box"

# Every custom route, unauthenticated. 401 means the route is bound and
# refused us for lack of a token, which is the proof that this build is
# serving. 404 means the router has never heard of it — the old image is
# still running and something above did not take.
failed=0
for route in \
  "GET  /api/splitcore/staleness" \
  "GET  /api/splitcore/members" \
  "POST /api/splitcore/invite" \
  "POST /api/splitcore/remove-member" \
  "POST /api/splitcore/transfer-ownership" \
  "POST /api/splitcore/delete-account"
do
  method="${route%% *}"
  path="${route##* }"
  status="$(code "$method" "$path")"
  printf '  %-22s %s\n' "${path##*/}" "$status"
  [ "$status" = "404" ] && failed=1
done
[ "$failed" = "0" ] || fail "a route 404'd — the old build is still serving"

printf '\n\033[32mDeployed. %s is serving %s\033[0m\n' "$DEPLOY_URL" "$(git rev-parse --short HEAD)"
