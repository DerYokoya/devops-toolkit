#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail
trap 'echo "$(date +%F_%T) ERROR: line $LINENO: command failed" >&2' ERR

# =========================================================================
# Provision users
#   Reads ONE list file, then for every user in it:
#     - creates the account if it does not exist (home directory, shell,
#       optional extra groups)
#     - adds the listed SSH PUBLIC keys to ~/.ssh/authorized_keys
#       (700 on ~/.ssh, 600 on authorized_keys, owned by the user)
#
#   Security choices:
#     - NO passwords are ever set. Accounts are key-only. (A predictable or
#       shared password is the first thing an attacker tries.)
#     - NO private keys are generated here. Each person creates their own key
#       pair on their own machine and sends you the public half.
#     - The whole list is validated BEFORE anything is changed.
#     - Existing system accounts (uid < 1000) are never modified.
#     - Symlinked ~/.ssh or authorized_keys are refused (a user could
#       otherwise point them at a file root would then write to).
#     - Safe to re-run: existing users are left alone and keys that are
#       already present are not added twice.
#     - No sudo rights are granted.
# =========================================================================

# --- Config --------------------------------------------------------------
MIN_UID=1000                 # accounts below this are system accounts
SHELL_BIN=/bin/bash
EXTRA_GROUPS=()
DRY_RUN=0
LIST_FILE=""

# --- State ---------------------------------------------------------------
USER_ORDER=()                # users in the order they first appear in the list
declare -A USER_KEYS=()      # user -> newline-separated public keys
EXTRA_GROUPS_CSV=""
CREATED=0
EXISTING=0
KEYS_ADDED=0
KEYS_PRESENT=0
FAILED=0

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] LIST_FILE

Creates the users in LIST_FILE and installs their SSH public keys. Run it as
root (for example: sudo $(basename "$0") users.txt). Use --dry-run first.

LIST_FILE has one entry per line:

    username [ssh-public-key]

  * Blank lines and lines starting with # are ignored.
  * The key is a full public key line, e.g. "ssh-ed25519 AAAAC3... alice@laptop".
  * A user may appear on several lines to give them several keys.
  * Key options such as command="..." or from="..." are not accepted.

Options:
  -n, --dry-run     Validate the list and print what would be done; change nothing.
      --shell PATH  Login shell for NEW users (default: $SHELL_BIN).
      --group NAME  Add NEW users to this existing group. Repeatable.
  -h, --help        Show this help message and exit.

What it does NOT do: set passwords, generate private keys, grant sudo, or
modify existing accounts (it only appends missing keys to their
authorized_keys). Accounts with a uid below $MIN_UID are refused.

Exit status:
  0    All users provisioned (or dry run completed).
  1    The list is invalid, a requirement is missing, or a user failed.
  2    Invalid command-line usage.

Example list:
    # username  public key
    alice   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyAlice alice@laptop
    bob     ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyBob bob@desktop
    carol

Examples:
  $(basename "$0") --dry-run users.txt
  sudo $(basename "$0") --group developers users.txt
EOF
}

log() {
    echo "$(date +%F_%T) $*"
}

err() {
    echo "$(date +%F_%T) ERROR: $*" >&2
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

# Run a command, or only print it under --dry-run.
run() {
    if (( DRY_RUN )); then
        log "[dry-run] would run: $*"
    else
        log "+ $*"
        "$@"
    fi
}

# "ssh-ed25519 ...XXXXXXXX alice@laptop": enough to recognise a key in logs
# without printing the whole thing.
describe_key() {
    local type blob comment
    read -r type blob comment <<<"$1"
    echo "$type ...${blob: -8}${comment:+ ($comment)}"
}

# =========================================================================
# Arguments
# =========================================================================
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            --shell|--group)
                if (( $# < 2 )); then
                    usage_error "$1 requires a value"
                fi
                if [[ $1 == --shell ]]; then
                    SHELL_BIN=$2
                else
                    EXTRA_GROUPS+=("$2")
                fi
                shift
                ;;
            -*) usage_error "unknown option: $1" ;;
            *)
                if [[ -n $LIST_FILE ]]; then
                    usage_error "only one LIST_FILE is accepted"
                fi
                LIST_FILE=$1
                ;;
        esac
        shift
    done

    if [[ -z $LIST_FILE ]]; then
        usage_error "LIST_FILE is required"
    fi
    if [[ $SHELL_BIN != /* ]]; then
        usage_error "--shell must be an absolute path"
    fi

    local g
    if (( ${#EXTRA_GROUPS[@]} > 0 )); then
        for g in "${EXTRA_GROUPS[@]}"; do
            if [[ ! $g =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
                usage_error "invalid group name: $g"
            fi
        done
        EXTRA_GROUPS_CSV=$(IFS=,; echo "${EXTRA_GROUPS[*]}")
    fi
}

# =========================================================================
# List file: parse and validate everything before touching the system
# =========================================================================
parse_list() {
    local line lineno=0 user key errors=0
    local key_re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+=*( .*)?$'

    if [[ ! -r $LIST_FILE || ! -f $LIST_FILE ]]; then
        die "cannot read list file: $LIST_FILE"
    fi

    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}                    # tolerate Windows line endings
        user=""
        key=""
        read -r user key <<<"$line" || true   # trims surrounding whitespace
        if [[ -z $user || $user == \#* ]]; then
            continue
        fi

        if [[ ! $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            err "line $lineno: invalid username '$user' (lowercase letters, digits, '_' and '-'; max 32)"
            errors=$((errors + 1))
            continue
        fi
        if [[ $user == root ]]; then
            err "line $lineno: refusing to provision 'root'"
            errors=$((errors + 1))
            continue
        fi
        if [[ -n $key && ! $key =~ $key_re ]]; then
            err "line $lineno: '$user' has something that is not a supported SSH public key (private keys and key options are rejected)"
            errors=$((errors + 1))
            continue
        fi

        if [[ -z ${USER_KEYS[$user]+set} ]]; then
            USER_ORDER+=("$user")
            USER_KEYS[$user]=""
        fi
        if [[ -n $key ]]; then
            # Skip exact duplicates within the list.
            if [[ $'\n'${USER_KEYS[$user]}$'\n' != *$'\n'"$key"$'\n'* ]]; then
                USER_KEYS[$user]+="${USER_KEYS[$user]:+$'\n'}$key"
            fi
        fi
    done < "$LIST_FILE"

    if (( errors > 0 )); then
        die "$errors problem(s) in $LIST_FILE; nothing was changed"
    fi
    if (( ${#USER_ORDER[@]} == 0 )); then
        die "no users found in $LIST_FILE"
    fi
}

# =========================================================================
# Preflight
# =========================================================================
preflight() {
    local tool g
    local missing=()
    local tools=(getent)

    if (( ! DRY_RUN )); then
        tools=(getent id useradd chown chmod mkdir grep tail)
    fi
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "missing required tools: ${missing[*]}"
    fi

    if (( ! DRY_RUN )) && [[ $(id -u) != 0 ]]; then
        die "must be run as root (try: sudo $(basename "$0") $LIST_FILE); use --dry-run to preview without root"
    fi
    if [[ ! -x $SHELL_BIN ]]; then
        die "shell not found or not executable: $SHELL_BIN"
    fi
    if (( ${#EXTRA_GROUPS[@]} > 0 )); then
        for g in "${EXTRA_GROUPS[@]}"; do
            if ! getent group "$g" >/dev/null 2>&1; then
                die "group does not exist: $g"
            fi
        done
    fi
}

# =========================================================================
# One user
#   NOTE: this function is called from an `if`, where `set -e` is switched
#   off, so every step checks its own result and returns 1 on failure.
# =========================================================================
provision_user() {
    local user=$1
    local entry uid="" home="" existing=0
    local cmd=() keys=() key ssh_dir auth_file

    if entry=$(getent passwd "$user"); then
        IFS=: read -r _ _ uid _ _ home _ <<<"$entry"
        if [[ ! $uid =~ ^[0-9]+$ ]] || (( uid < MIN_UID )); then
            err "$user: refusing to modify an existing system account (uid ${uid:-unknown})"
            return 1
        fi
        existing=1
        EXISTING=$((EXISTING + 1))
        log "$user: already exists, leaving the account as it is"
    else
        cmd=(useradd --create-home --shell "$SHELL_BIN")
        if [[ -n $EXTRA_GROUPS_CSV ]]; then
            cmd+=(--groups "$EXTRA_GROUPS_CSV")
        fi
        cmd+=(-- "$user")
        if ! run "${cmd[@]}"; then
            err "$user: useradd failed"
            return 1
        fi
        CREATED=$((CREATED + 1))
        if (( ! DRY_RUN )); then
            if ! entry=$(getent passwd "$user"); then
                err "$user: account not found after useradd"
                return 1
            fi
            IFS=: read -r _ _ uid _ _ home _ <<<"$entry"
        fi
    fi

    if [[ -n ${USER_KEYS[$user]:-} ]]; then
        mapfile -t keys <<<"${USER_KEYS[$user]}"
    fi
    if (( ${#keys[@]} == 0 )); then
        log "$user: no SSH key in the list, so this user cannot log in over SSH yet"
        return 0
    fi

    # A new account does not exist yet in a dry run, so there is nothing to inspect.
    if (( DRY_RUN && ! existing )); then
        for key in "${keys[@]}"; do
            log "[dry-run] would add key $(describe_key "$key") to ~$user/.ssh/authorized_keys"
            KEYS_ADDED=$((KEYS_ADDED + 1))
        done
        return 0
    fi

    if [[ -z $home || ! -d $home ]]; then
        err "$user: home directory '$home' does not exist"
        return 1
    fi
    ssh_dir=$home/.ssh
    auth_file=$ssh_dir/authorized_keys

    if [[ -L $ssh_dir || -L $auth_file ]]; then
        err "$user: $ssh_dir or authorized_keys is a symlink; refusing to write through it"
        return 1
    fi

    if (( ! DRY_RUN )); then
        if ! mkdir -p -- "$ssh_dir" \
            || ! chmod 700 -- "$ssh_dir" \
            || ! chown -- "$user:" "$ssh_dir"; then
            err "$user: could not prepare $ssh_dir"
            return 1
        fi
        if ! { : >> "$auth_file"; } \
            || ! chmod 600 -- "$auth_file" \
            || ! chown -- "$user:" "$auth_file"; then
            err "$user: could not prepare $auth_file"
            return 1
        fi
    fi

    for key in "${keys[@]}"; do
        if [[ -f $auth_file ]] && grep -qxF -- "$key" "$auth_file"; then
            log "$user: key $(describe_key "$key") already present"
            KEYS_PRESENT=$((KEYS_PRESENT + 1))
        elif (( DRY_RUN )); then
            log "[dry-run] would add key $(describe_key "$key") to $auth_file"
            KEYS_ADDED=$((KEYS_ADDED + 1))
        else
            # An existing file might not end in a newline; don't glue two keys together.
            if [[ -s $auth_file && -n $(tail -c 1 "$auth_file") ]]; then
                printf '\n' >> "$auth_file"
            fi
            if printf '%s\n' "$key" >> "$auth_file"; then
                log "$user: added key $(describe_key "$key")"
                KEYS_ADDED=$((KEYS_ADDED + 1))
            else
                err "$user: could not write to $auth_file"
                return 1
            fi
        fi
    done
    return 0
}

# =========================================================================
# Main
# =========================================================================
main() {
    local user

    parse_args "$@"
    parse_list
    preflight

    if (( DRY_RUN )); then
        log "Dry run: nothing will be changed."
    fi

    for user in "${USER_ORDER[@]}"; do
        if ! provision_user "$user"; then
            FAILED=$((FAILED + 1))
        fi
    done

    echo
    if (( DRY_RUN )); then
        log "Dry run complete: $CREATED to create, $EXISTING already exist, $KEYS_ADDED key(s) to add, $KEYS_PRESENT already present, $FAILED problem(s). Nothing was changed."
    else
        log "Done: $CREATED created, $EXISTING already existed, $KEYS_ADDED key(s) added, $KEYS_PRESENT already present, $FAILED failed."
    fi
    if (( FAILED > 0 )); then
        exit 1
    fi
}

main "$@"
