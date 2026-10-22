#!/bin/sh
# ===========================================================================
# OP Anonymization - Launcher
# ===========================================================================
# Purpose : Starts the run (lib/anon.sh) in bash with the given options, and
#           returns its exit code. The Linux counterpart of
#           run_op_anonymization.bat.
# Usage   : run_op_anonymization.sh [--dryrun] [--auto] [--force] [--verbose]
#           [--no-open] [--no-color], or --inventory <file>, or --help
# Exit    : 0 PASS (a dry run: completed), 1 failed or not started,
#           2 FAIL, 3 REVIEW REQUIRED, 4 INCOMPLETE, 5 stopped with Ctrl+C.
# ===========================================================================
script=$(readlink -f "$0" 2> /dev/null) || script=$0
here=$(cd "$(dirname "$script")" && pwd) || exit 1
bash=$(command -v bash) || {
    echo ' OP Anonymization needs bash 4.2 or later, and there is no bash in PATH.' >&2
    exit 1
}
exec "$bash" "$here/lib/anon.sh" "$@"
