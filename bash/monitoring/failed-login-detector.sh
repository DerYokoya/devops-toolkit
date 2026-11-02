#!/usr/bin/env bash
set -euo pipefail

FILENAME="failed_login.txt"
SECURITY_FILE=/placeholder/
ATTEMPT_LOG=/var/log/auth.log
ATTEMPT_SECURE=/var/log/secure

declare -A ip_counts = ()

# =========================================================================
# Arguments
# =========================================================================
case "${1:-}" in # ${1:-} means "if $1 is unset or empty, use an empty string"
    # if the argument is -h or --help, call the usage function and
    # exit with status 0 (success).
    -h|--help) usage; exit 0 ;; 
    "")        ;; # if the argument is an empty string, do nothing in this branch.
    # if the argument is anything else, print an error message to stderr,
    # call the usage function, and exit with status 2 (incorrect usage).
    *)         echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

if [ -e "$ATTEMPT_LOG" ]; then
    echo "$ATTEMPT_LOG exists."
    SECURITY_FILE=$ATTEMPT_LOG
fi

if [[ ! -e "$ATTEMPT_SECURE" ]]; then
    echo "$ATTEMPT_SECURE exists."
    SECURITY_FILE=$ATTEMPT_SECURE
fi

if [SECURITY_FILE -eq "/placeholder/"]; then
    echo "No security file found."
    exit 1;
fi

echo "USERNAMES THAT FAILED TO LOG IN" >> FILENAME
(sudo grep "Failed password" $SECURITY_FILE | awk '{print $9}') | tee -a FILENAME

echo "IP ADDRESSES THAT FAILED TO LOG IN" >> FILENAME
sudo grep "Failed password" $SECURITY_FILE | awk '{print $11}' | tee -a FILENAME

echo "WHAT COMMANDS WERE RAN WITH SUDO" >> FILENAME
sudo grep "COMMAND=" $SECURITY_FILE | awk '{print "User: " $6 " -> Ran: " $15}' | tee -a FILENAME

exit 0;

# =========================================================================
# Helpers
# =========================================================================

usage() {
    cat <<'EOF'
Usage: failed-login-detector.sh [-h|--help]

Scans authentication logs for repeated failed SSH attempts and lists the offending IPs.
Targets system auth logs (e.g., /var/log/auth.log or secure). Extract IP addresses using grep and awk.
Aggregates failure counts per IP. Output a clean list of top offending IPs

Options:
  -h, --help    Show this help message and exit.

Exit status:
  0    All checks passed.
  1    Security file is missing.
  2    Invalid command-line usage.

TO ADD EXAMPLES
EOF
}
