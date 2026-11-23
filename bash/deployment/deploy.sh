#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail

# =========================================================================
# Deploy script
#   1. preflight: required tools, clean working tree, right branch, lock
#   2. record the current commit (for rollback)
#   3. git fetch + fast-forward to the remote branch (never a merge commit)
#   4. npm ci --omit=dev
#   5. db-migrate up
#   6. pm2 reload <app>
#   7. optional HTTP health check
#
# Fails fast: the first failing step stops the run, and migrations run BEFORE
# the reload, so a failed migration leaves the old code running. On failure
# after the code has changed, the exact rollback commands are printed. Nothing
# is rolled back automatically, because undoing code while the database has
# already been migrated can make things worse.
#
# --dry-run runs the preflight checks, then prints every step instead of
# running it.
# =========================================================================

# --- Config --------------------------------------------------------------
APP=""
REMOTE=origin
BRANCH=""                    # defaults to the currently checked-out branch
HEALTH_URL=""
HEALTH_RETRIES=10
HEALTH_INTERVAL=2            # seconds between health-check attempts
DRY_RUN=0
LOCK_DIR=${DEPLOY_LOCK_DIR:-${TMPDIR:-/tmp}}

# --- State ---------------------------------------------------------------
STEP="startup"
PREV_SHA=""
NEW_SHA=""
MUTATING=0                   # 1 once the working tree has been changed

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") --app NAME [options]

Deploys the current repository: pulls the latest code (fast-forward only),
installs dependencies, runs database migrations, reloads the pm2 app and
optionally checks that it came back up. Run it from inside the repository.

Required:
  --app NAME            pm2 app name to reload.

Options:
  --remote NAME         Git remote to pull from (default: origin).
  --branch NAME         Branch to deploy. Must be the checked-out branch
                        (default: the checked-out branch).
  --health-url URL      After the reload, request this URL until it succeeds.
  --health-retries N    Health-check attempts (default: $HEALTH_RETRIES).
  --health-interval S   Seconds between attempts (default: $HEALTH_INTERVAL).
  -n, --dry-run         Run the preflight checks, then only print the steps.
  -h, --help            Show this help message and exit.

Environment:
  DEPLOY_LOCK_DIR       Where the per-app lock file lives (default: \$TMPDIR or /tmp).

Requires: git, npm (7+), db-migrate, pm2, flock (and curl with --health-url).

Exit status:
  0    Deployed (or dry run completed).
  1    Preflight failed, a step failed, or the health check failed.
  2    Invalid command-line usage.

Examples:
  $(basename "$0") --app myapp
  $(basename "$0") --app myapp --branch main --health-url http://localhost:3000/health
  $(basename "$0") --app myapp --dry-run
EOF
}

log() {
    echo "$(date +%F_%T) $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage_error() {
    echo "error: $*" >&2
    usage >&2
    exit 2
}

# Runs on any unexpected command failure (set -e + ERR trap).
on_error() {
    local rc=$?
    trap - ERR
    echo "$(date +%F_%T) DEPLOY FAILED during: $STEP (exit $rc)" >&2
    if (( MUTATING )); then
        print_rollback >&2
    fi
    exit "$rc"
}
trap on_error ERR

print_rollback() {
    echo
    echo "The code on this machine was changed. To go back to the previous release:"
    echo "  git reset --hard $PREV_SHA && npm ci --omit=dev && pm2 reload $APP"
    if [[ $STEP != "install dependencies" ]]; then
        echo
        echo "Database migrations are NOT rolled back automatically. If this release"
        echo "added a migration, review it and revert it with: db-migrate down"
    fi
}

# Run a command, or only print it under --dry-run. fd 9 (the lock) is closed
# for the child so a daemon it starts (pm2 does) cannot hold the lock forever.
run() {
    if (( DRY_RUN )); then
        log "[dry-run] would run: $*"
    else
        log "+ $*"
        "$@" 9>&-
    fi
}

# =========================================================================
# Arguments
# =========================================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            --app|--remote|--branch|--health-url|--health-retries|--health-interval)
                if (( $# < 2 )); then
                    usage_error "$1 requires a value"
                fi
                case "$1" in
                    --app)             APP=$2 ;;
                    --remote)          REMOTE=$2 ;;
                    --branch)          BRANCH=$2 ;;
                    --health-url)      HEALTH_URL=$2 ;;
                    --health-retries)  HEALTH_RETRIES=$2 ;;
                    --health-interval) HEALTH_INTERVAL=$2 ;;
                esac
                shift
                ;;
            *) usage_error "unknown argument: $1" ;;
        esac
        shift
    done

    if [[ -z $APP ]]; then
        usage_error "--app is required"
    fi
    if [[ ! $APP =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        usage_error "--app may only contain letters, digits, '.', '_' and '-'"
    fi
    if [[ $REMOTE == -* || $BRANCH == -* ]]; then
        usage_error "--remote and --branch must not start with '-'"
    fi
    if [[ ! $HEALTH_RETRIES =~ ^[0-9]+$ ]] || (( 10#$HEALTH_RETRIES < 1 )); then
        usage_error "--health-retries must be a positive whole number"
    fi
    if [[ ! $HEALTH_INTERVAL =~ ^[0-9]+$ ]]; then
        usage_error "--health-interval must be a whole number of seconds"
    fi
    HEALTH_RETRIES=$((10#$HEALTH_RETRIES))
    HEALTH_INTERVAL=$((10#$HEALTH_INTERVAL))
}

# =========================================================================
# Preflight
# =========================================================================
preflight() {
    STEP="preflight"
    local tool current lock_file
    local missing=()

    for tool in git npm db-migrate pm2 flock; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if [[ -n $HEALTH_URL ]] && ! command -v curl >/dev/null 2>&1; then
        missing+=(curl)
    fi
    if (( ${#missing[@]} > 0 )); then
        die "missing required tools: ${missing[*]}"
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "not inside a git work tree; run this from the repository"
    fi
    if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
        die "git remote '$REMOTE' does not exist"
    fi

    current=$(git branch --show-current)
    if [[ -z $current ]]; then
        die "HEAD is detached; check out the branch you want to deploy"
    fi
    if [[ -z $BRANCH ]]; then
        BRANCH=$current
    fi
    if [[ $BRANCH != "$current" ]]; then
        die "checked-out branch is '$current' but --branch is '$BRANCH'; check it out first"
    fi

    # Untracked files are fine; modified or staged tracked files are not.
    if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
        die "working tree has uncommitted changes; commit or stash them first"
    fi

    lock_file="$LOCK_DIR/deploy-$APP.lock"
    exec 9>"$lock_file"
    if ! flock --nonblock 9; then
        die "another deploy of '$APP' is already running (lock: $lock_file)"
    fi

    log "Preflight OK: app=$APP remote=$REMOTE branch=$BRANCH"
}

# =========================================================================
# Health check
# =========================================================================
health_check() {
    local i

    if [[ -z $HEALTH_URL ]]; then
        log "No --health-url given; skipping the health check."
        return 0
    fi
    if (( DRY_RUN )); then
        log "[dry-run] would check $HEALTH_URL (up to $HEALTH_RETRIES attempts, ${HEALTH_INTERVAL}s apart)"
        return 0
    fi

    for (( i = 1; i <= HEALTH_RETRIES; i++ )); do
        if curl --fail --silent --show-error --max-time 5 --output /dev/null "$HEALTH_URL"; then
            log "Health check passed ($HEALTH_URL, attempt $i/$HEALTH_RETRIES)"
            return 0
        fi
        if (( i < HEALTH_RETRIES )); then
            sleep "$HEALTH_INTERVAL"
        fi
    done

    echo "Health check failed after $HEALTH_RETRIES attempts: $HEALTH_URL" >&2
    return 1
}

# =========================================================================
# Deploy
# =========================================================================
deploy() {
    STEP="record current commit"
    PREV_SHA=$(git rev-parse HEAD)
    log "Current commit: $PREV_SHA"

    STEP="fetch"
    run git fetch "$REMOTE" "$BRANCH"

    STEP="fast-forward"
    run git merge --ff-only FETCH_HEAD
    MUTATING=1                                # code on disk has changed from here on

    STEP="install dependencies"
    run npm ci --omit=dev

    STEP="run migrations"
    run db-migrate up

    STEP="reload $APP"
    run pm2 reload "$APP"

    STEP="health check"
    health_check

    STEP="done"
    if (( DRY_RUN )); then
        echo
        log "Dry run complete: nothing was changed."
        return 0
    fi

    NEW_SHA=$(git rev-parse HEAD)
    echo
    log "Deployed $APP: ${PREV_SHA:0:7} -> ${NEW_SHA:0:7}"
    echo "To roll back the code: git reset --hard $PREV_SHA && npm ci --omit=dev && pm2 reload $APP"
}

# =========================================================================
# Main
# =========================================================================
main() {
    parse_args "$@"
    preflight
    deploy
}

main "$@"