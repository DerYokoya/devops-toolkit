#!/usr/bin/env bash
# -E to ensure ERR trap is inherited by functions, command substitutions, and subshells
set -Eeuo pipefail

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<EOF
Example
EOF
}

# =========================================================================
# Arguments
# =========================================================================
declare -a username_list=()

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;; # Help message
        # Any string that starts with - but isn't -h or --help
        -*)        echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
        *)         username_list+=( $arg ) ;;
    esac
done

temp=""
for u in "${!username_list[@]}"; do
    echo "$(id $u)" > temp
    if [[ temp=="'$u': no such user"]]
        do
            sudo useradd -m $u
            echo "Created user {$u}"
            echo -e "'123$u!'\n'123$u!'" | passwd USERNAME
            echo "Changed password to 123$u!"
            sudo chage -M 7 $u
            echo "Password of $u must be changed within 7 days!"
            mkdir /usr/local
            mkdir /dev
            touch /dev/MAKEDEV.local
            echo "Created usr local, dev, and MAKEDEV local"
            sudo -u $u ssh-keygen
            echo "Created ssh key."
            # I can read / write / execute the file, but the user and
            # the group can't do anything about it
            chmod 700 /home/$u/.ssh/id_rsa
            echo "Adjusted permissions for the ssh key."
        done
    fi
done