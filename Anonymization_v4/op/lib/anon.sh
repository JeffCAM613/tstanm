#!/usr/bin/env bash
# ============================================================================
# OP Anonymization - The run
# ============================================================================
# Purpose : Implementation of run_op_anonymization.sh. Reads the command
#           line and config/anonymization.ini, asks for what they leave
#           blank, gets ready by itself (sqlplus, the database as SYS and as
#           OP, the ANON_META schema, the engine, the inventory), then runs
#           the anonymization - or its dry run - in one sqlplus session while
#           a second one watches it, verifies a run, and leaves a folder with
#           the run's report (report.html), its output and its figures. The
#           same run as lib/anon.ps1 on Windows, with the same SQL.
# Usage   : run_op_anonymization.sh [--dryrun] [--auto] [--force] [--verbose]
#           [--no-open] [--no-color], or --inventory <file>, or --help
# Requires: bash 4.2 or later, awk, and sqlplus in PATH or in
#           $ORACLE_HOME/bin.
# Exit    : 0 PASS (a dry run: completed), 1 failed or not started, 2 FAIL,
#           3 REVIEW REQUIRED, 4 INCOMPLETE, 5 stopped with Ctrl+C.
#
# Passwords reach sqlplus on its standard input only: never on a command
# line, in a file this tool writes, or in the environment of a process it
# starts.
# ============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo ' OP Anonymization runs in bash: start it with op/run_op_anonymization.sh.' >&2
    exit 1
fi
case $BASH_VERSION in
    [0-3].*|4.[01].*)
        echo " OP Anonymization needs bash 4.2 or later; this is bash $BASH_VERSION." >&2
        exit 1 ;;
esac

# The tool reads and formats its own text byte by byte; the processes it
# starts keep the operator's locale.
ORIGINAL_LC_ALL_SET=${LC_ALL+1}
ORIGINAL_LC_ALL=${LC_ALL-}
export LC_ALL=C

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OP_DIR=${LIB_DIR%/*}
ROOT_DIR=${OP_DIR%/*}
SQL_DIR=$OP_DIR/sql
RUN_SQL_DIR=$SQL_DIR/run
VERIFY_SQL=$OP_DIR/verify/verify_op_coverage.sql
CONFIG_DIR=$ROOT_DIR/config
CONFIG_FILE=$CONFIG_DIR/anonymization.ini
LOG_ROOT=$OP_DIR/logs
WIDTH=80

# Exit codes, as the user guide lists them.
EXIT_PASS=0
EXIT_ERROR=1
EXIT_VERIFY_FAIL=2
EXIT_REVIEW=3
EXIT_INCOMPLETE=4
EXIT_STOPPED=5

# The launcher as it can be typed from the current directory: its path from
# there when it lies below it, its full path otherwise. Every command the
# screen tells the operator to type begins with it.
LAUNCHER=$OP_DIR/run_op_anonymization.sh
[[ $LAUNCHER == "$PWD"/* ]] && LAUNCHER=${LAUNCHER#"$PWD"/}
[[ $LAUNCHER == */* ]] || LAUNCHER=./$LAUNCHER
[[ $LAUNCHER == *' '* ]] && LAUNCHER="\"$LAUNCHER\""

# Output: colour, --verbose, console.log of the run (lines written before its
# folder exists are kept and written when it is created), and the status line
# rewritten in place on a terminal (show_status). A terminal that goes away
# (a closed window, a broken pipe) is written to no more; console.log still
# is.
OUTPUT_IS_TTY=0
[ -t 1 ] && OUTPUT_IS_TTY=1
USE_COLOR=$OUTPUT_IS_TTY
[ "${TERM:-}" = dumb ] && USE_COLOR=0
[ -n "${NO_COLOR:-}" ] && USE_COLOR=0
VERBOSE=0
LOG_FILE=''
BUFFERED=()
STATUS_LINE=0
STATUS_SHOWN=0
LAST_CONSOLE=0
CONSOLE_OK=1
TERM_COLUMNS=80
declare -A COLORS=([Red]=$'\e[31m' [Green]=$'\e[32m' [Yellow]=$'\e[33m' [Cyan]=$'\e[36m' [DarkCyan]=$'\e[36m'
                   [DarkGray]=$'\e[90m' [White]=$'\e[1m')
RESET=$'\e[0m'

# sqlplus and its sessions, ended on every way out (stop_children). A session
# is a number: S_NAME, S_PID, S_IN (the descriptor its input is written to),
# S_OUT (the descriptor its output is read from), S_DIR, S_PART (a line not
# complete yet), S_ENDED, S_OK and S_ERROR (its CONNECT).
SQLPLUS=''
S_NAME=(); S_PID=(); S_IN=(); S_OUT=(); S_DIR=(); S_PART=(); S_ENDED=(); S_OK=(); S_ERROR=()
READY_MARKER=ANON_SESSION_READY
CONNECT_TIMEOUT_S=120
MARKER_SEQ=0
# Errors printed by a CONNECT that succeeded: a password about to expire.
CONNECT_WARNINGS='ORA-28002|ORA-28011'
RE_ORACLE_ERROR='(ORA-[0-9]{5}|SP2-[0-9]{4}).*'
RE_ORACLE_CODE='ORA-[0-9]{5}|SP2-[0-9]{4}'
declare -A L_USER L_SECRET L_SYSDBA SECRET
L_TNS=''

# The tool's working files (the sessions' input and output), and a pipe
# nothing writes to, read with a time limit to wait without a process.
TMP_DIR=''
PAUSE_FD=''
TTY_SAVED=''

# Ctrl+C (SIGINT) and SIGTERM, counted until they are acted on; whether a
# stop was asked for.
PENDING_STOP=0
STOP_ASKED=0
STOP_KEYS=0

declare -A SET FILE_SETTINGS
INV_TABLE=(); INV_COLUMN=(); INV_RULE=(); INV_CATEGORY=(); INV_NOTES=(); INV_SOURCE=(); INV_SQL=()

# shellcheck source=anon_screen.sh
. "$LIB_DIR/anon_screen.sh"

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

now() { printf -v NOW '%(%s)T' -1; }

# A short wait, in seconds, without starting a process.
pause() {
    local _x
    if [ -n "$PAUSE_FD" ]; then read -r -t "$1" -u "$PAUSE_FD" _x 2> /dev/null; else sleep "$1"; fi
    return 0
}

# Appends a line to console.log of the run; lines written before the run
# folder exists are kept until it is created.
write_log() {
    if [ -n "$LOG_FILE" ]; then printf '%s\n' "$1" >> "$LOG_FILE"; else BUFFERED+=("$1"); fi
}

# Text on the terminal, in colour, then $3 (a new line unless given).
console_text() {   # TEXT [COLOR] [END]
    (( CONSOLE_OK )) || return 0
    local end=${3-$'\n'}
    if (( USE_COLOR )) && [ -n "${2:-}" ] && [ -n "${COLORS[$2]:-}" ]; then
        printf '%s%s%s%s' "${COLORS[$2]}" "$1" "$RESET" "$end" 2> /dev/null || CONSOLE_OK=0
    else
        printf '%s%s' "$1" "$end" 2> /dev/null || CONSOLE_OK=0
    fi
}

# A line on the terminal (in colour) and in console.log. detail: on the
# terminal only with --verbose; nolog: on the terminal only.
write_out() {   # TEXT [COLOR] [detail] [nolog]
    local text=${1:-} color=${2:-} flag detail=0 nolog=0
    for flag in "${@:3}"; do
        case $flag in
            detail) detail=1 ;;
            nolog)  nolog=1 ;;
        esac
    done
    if (( VERBOSE || ! detail )); then
        clear_status
        console_text "$text" "$color"
        now
        LAST_CONSOLE=$NOW
    fi
    (( nolog )) || write_log "$text"
}

# The status line: one line rewritten in place on a terminal, cleared before
# the next line is written (write_out); never logged.
show_status() {
    (( STATUS_LINE && CONSOLE_OK )) || return 0
    local text=$1 width=$((TERM_COLUMNS - 1))
    (( width < 20 )) && return 0
    (( ${#text} > width )) && text=${text:0:width-3}...
    if (( USE_COLOR )); then
        printf '\r%s%-*s%s\r' "${COLORS[DarkGray]}" "$width" "$text" "$RESET" 2> /dev/null || CONSOLE_OK=0
    else
        printf '\r%-*s\r' "$width" "$text" 2> /dev/null || CONSOLE_OK=0
    fi
    STATUS_SHOWN=1
}

clear_status() {
    (( STATUS_SHOWN )) || return 0
    STATUS_SHOWN=0
    (( CONSOLE_OK )) || return 0
    printf '\r%*s\r' $((TERM_COLUMNS - 1)) '' 2> /dev/null || CONSOLE_OK=0
}

# Output of sqlplus, line by line without its trailing blank lines: on the
# terminal only with --verbose (detail) and always in console.log. The lines
# the tool reads (ANON_...) are left out of the terminal.
show_lines() {   # [detail] LINES...
    local detail='' last i line color upper
    if [ "${1:-}" = detail ]; then detail=detail; shift; fi
    local -a lines=("$@")
    last=$((${#lines[@]} - 1))
    while (( last >= 0 )) && [[ ${lines[last]} != *[![:space:]]* ]]; do last=$((last - 1)); done
    for (( i = 0; i <= last; i++ )); do
        rtrim line "${lines[i]}"
        if [[ $line =~ ^ANON_[A-Z_]+[|] ]]; then write_log "$line"; continue; fi
        color=''
        upper=${line^^}
        if [[ $upper =~ $RE_ORACLE_CODE|BLOCKED|INVALID ]]; then
            color=Red
        elif [[ $upper =~ (^|[^A-Z0-9_])REVIEW([^A-Z0-9_]|$) ]]; then
            color=Yellow
        fi
        write_out "$line" "$color" $detail
    done
}

# Ends the tool: the message (red unless the code is 0), then the exit code.
exit_tool() {   # CODE [MESSAGE]
    if [ -n "${2:-}" ]; then
        if (( $1 == 0 )); then write_out " $2"; else write_out " $2" Red; fi
    fi
    stop_children
    exit "$1"
}

show_help() {
    local text
    read -r -d '' text << 'EOF'
OP Anonymization

  Replaces the client data of the OP schema, on a restored copy of the
  database, with safe values: the codes of entities, portfolios,
  counterparties and bank accounts get a generated replacement (E_, P_, T_,
  X_, CB_) everywhere they are used, labels and attributes are masked with
  it, and free text is emptied. What is covered is listed in
  config/inventory_op.csv; what is switched on, in config/anonymization.ini.

Usage
  run_op_anonymization.sh
      The run: it checks, shows what it will change, then asks for YES.
  run_op_anonymization.sh --dryrun
      What a run would change. Changes nothing.
  run_op_anonymization.sh --auto
      Asks nothing: everything comes from the configuration file and the
      environment. A run still asks for YES; add --force to skip it.
  run_op_anonymization.sh --inventory <file>
      Writes the inventory as SQL to <file> and stops. Touches no database.

Options
  --verbose    every line of the engine on the screen, as it comes
  --no-open    report.html is not opened in the browser at the end
  --no-color   no colours on the screen
  --help       this text

Passwords
  Asked for, not shown, when the configuration file leaves them blank.
  Without questions (--auto) they come from the environment -
  ANON_SYS_PASSWORD and ANON_OP_PASSWORD - or from the configuration file.
  They reach sqlplus on its input only.

Every run, dry runs included, leaves a folder in op/logs:
  report.html    the result, the figures, the checks; opened at the end
                 when the run has a desktop
  report.txt     what the engine printed
  verify.txt     what the verification printed (a run)
  console.log    every line of the screen, and the engine's
  results.txt    the figures report.html is built from (counts only)
  manifest.txt   the run in key=value lines
  inventory.sql  the inventory as it was loaded

Ctrl+C - or kill -INT <pid> from another terminal - asks the run to stop
after the table or column it is working on; it enables the triggers of OP
again and ends. A new run resumes from there with the same translations.
If the terminal closes, the run goes on to its end and leaves its folder.

Exit codes
  0  PASS - the run was verified complete; a dry run that completed
  1  failed, or not started (refused by its checks, or not confirmed)
  2  FAIL - client data is still present
  3  REVIEW REQUIRED - values were left as they are, their role ambiguous
  4  INCOMPLETE - a protection was switched off
  5  stopped with Ctrl+C
EOF
    printf '%s\n' "${text//run_op_anonymization.sh/$LAUNCHER}"
}

# ----------------------------------------------------------------------------
# Command line and configuration
# ----------------------------------------------------------------------------

# The options: --dryrun or -dryrun or /dryrun alike.
read_arguments() {
    local arg name
    CLI_DRYRUN=0; CLI_AUTO=0; CLI_FORCE=0; CLI_VERBOSE=0; CLI_NO_OPEN=0; CLI_HELP=0; CLI_NO_COLOR=0
    CLI_INVENTORY=''; CLI_HAS_INVENTORY=0
    while (( $# > 0 )); do
        trim arg "$1"
        name=${arg,,}
        if [[ $name == --* ]]; then name=${name#--}; elif [[ $name == [-/]* ]]; then name=${name#?}; fi
        case $name in
            dryrun|dry-run)   CLI_DRYRUN=1 ;;
            auto)             CLI_AUTO=1 ;;
            force)            CLI_FORCE=1 ;;
            verbose)          CLI_VERBOSE=1 ;;
            no-open|noopen)   CLI_NO_OPEN=1 ;;
            no-color|nocolor) CLI_NO_COLOR=1 ;;
            help|h|'?')       CLI_HELP=1 ;;
            inventory)
                shift
                if (( $# == 0 )) || [[ $1 != *[![:space:]]* ]]; then
                    exit_tool $EXIT_ERROR "--inventory needs the file to write, for example: $LAUNCHER --inventory /tmp/inventory.sql"
                fi
                CLI_INVENTORY=$1
                CLI_HAS_INVENTORY=1 ;;
            *)
                exit_tool $EXIT_ERROR "Unknown option $arg. $LAUNCHER --help lists the options." ;;
        esac
        shift
    done
}

# config/anonymization.ini: NAME=VALUE lines; lines starting with @REM, REM,
# # or ; are comments. Into FILE_SETTINGS; 1 when there is no such file.
read_config_file() {
    local line text key value n=0
    FILE_SETTINGS=()
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        (( n == 1 )) && line=${line#$'\xEF\xBB\xBF'}
        trim text "$line"
        [ -z "$text" ] && continue
        case $text in '@'*|'#'*|';'*) continue ;; esac
        [[ ${text,,} =~ ^rem([[:space:]]|$) ]] && continue
        key=${text%%=*}
        [[ $text == *=* && -n $key ]] || continue
        trim key "$key"
        trim value "${text#*=}"
        FILE_SETTINGS[${key^^}]=$value
    done < "$1"
    return 0
}

# A setting counts as not given when it is missing, blank, or still a
# <PLACEHOLDER> of the template.
test_given() {
    [ -n "${SET[$1]+x}" ] || return 1
    [[ ${SET[$1]} == *[![:space:]]* && ${SET[$1]} != *'<'* ]]
}

# y or n for a yes/no value (also yes, true, 1, o, oui / no, false, 0, non);
# empty for anything else.
to_yes_no() {   # VAR VALUE
    local _v
    trim _v "$2"
    case ${_v^^} in
        Y|YES|TRUE|1|O|OUI) printf -v "$1" '%s' y ;;
        N|NO|FALSE|0|NON)   printf -v "$1" '%s' n ;;
        *)                  printf -v "$1" '%s' '' ;;
    esac
}

# The names of the 15 switches, in the order the engine takes them: the
# renaming of each category, then its labels, then its attributes.
SWITCH_KEYS=()
for c in "${CATEGORIES[@]}"; do SWITCH_KEYS+=("ANONYMIZE_$c"); done
for c in "${CATEGORIES[@]}"; do SWITCH_KEYS+=("ANONYMIZE_${c}_DESCRIPTION"); done
for c in "${CATEGORIES[@]}"; do SWITCH_KEYS+=("ANONYMIZE_${c}_ATTRIBUTES"); done
unset c

# The version of the engine this tool installs, in TOOL_VERSION.
tool_version() {
    local line re="c_version[[:space:]]+CONSTANT[[:space:]]+VARCHAR2[(][0-9]+[)][[:space:]]*:=[[:space:]]*'([^']+)'"
    TOOL_VERSION=''
    shopt -s nocasematch
    while IFS= read -r line; do
        if [[ $line =~ $re ]]; then TOOL_VERSION=${BASH_REMATCH[1]}; break; fi
    done < "$SQL_DIR/30_install_engine.sql"
    shopt -u nocasematch
}

# ----------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------

# One line typed by the operator, in ANSWER; 1 when there is none - Ctrl+C at
# the question, or an input with no more lines. On a terminal the line is
# read once it is complete, and Ctrl+C is looked for meanwhile, a fifth of a
# second at a time: it cancels the question rather than the tool. When the
# input is a file or a pipe, its next line.
read_console_line() {
    local status
    ANSWER=''
    if [ ! -t 0 ]; then
        # Nothing is echoed: the prompt's line is ended here.
        if IFS= read -r ANSWER || [ -n "$ANSWER" ]; then
            ANSWER=${ANSWER%$'\r'}
            console_text ''
            return 0
        fi
        console_text ''
        return 1
    fi
    while :; do
        if (( PENDING_STOP > 0 )); then
            PENDING_STOP=0
            STOP_ASKED=1
            status=1
            break
        fi
        # A whole line typed, or the end of the input: read -t 0 reads
        # nothing, so no part of a line is lost to a time limit.
        if read -r -t 0; then
            IFS= read -r ANSWER
            status=$?
            break
        fi
        pause 0.2
    done
    if [ -n "$TTY_SAVED" ]; then
        # What was typed was not shown, its Enter neither.
        stty "$TTY_SAVED" 2> /dev/null
        TTY_SAVED=''
        console_text ''
    elif (( status != 0 )); then
        console_text ''
    fi
    (( status == 0 ))
}

# A divider before a question, so that each one stands apart.
write_ask() {
    local text=" -- $1 " fill n
    n=$((WIDTH - ${#text}))
    (( n < 3 )) && n=3
    printf -v fill '%*s' "$n" ''
    write_out ''
    write_out "$text${fill// /-}" DarkCyan
}

# Writes a prompt, marked ">" and in colour, and reads the answer (ANSWER).
# With mask, the terminal stops showing what is typed before the prompt
# appears, so that no part of a password typed at once is shown.
read_prompt() {   # LABEL [mask]
    clear_status
    if [ "${2:-}" = mask ] && [ -t 0 ]; then
        TTY_SAVED=$(stty -g 2> /dev/null)
        stty -echo 2> /dev/null
    fi
    console_text " > $1: " Cyan ''
    read_console_line
}

# The operator stopped at a question (Ctrl+C, or an input with no more
# lines): nothing has changed yet.
stop_at_question() {
    exit_tool $EXIT_STOPPED "Stopped at the question \"$1\". Nothing was changed."
}

# A value (ANSWER): asked until one is given; Enter takes the default.
read_answer() {   # PROMPT [DEFAULT] [PATTERN] [HINT]
    local prompt=$1 default=${2:-} pattern=${3:-} hint=${4:-a value is required} label=$1 answer
    [ -n "$default" ] && label+=" [$default]"
    while :; do
        read_prompt "$label" || stop_at_question "$prompt"
        trim answer "$ANSWER"
        [ -z "$answer" ] && answer=$default
        trim answer "$answer"
        if [ -n "$answer" ] && { [ -z "$pattern" ] || [[ $answer =~ $pattern ]]; }; then
            write_log " > $label: $answer"
            ANSWER=$answer
            return 0
        fi
        write_out "   $hint" Yellow nolog
    done
}

# y or n (ANSWER).
read_yes_no_answer() {   # PROMPT [DEFAULT]
    local prompt=$1 default=${2:-y} answer value
    while :; do
        read_prompt "$prompt [$default]" || stop_at_question "$prompt"
        trim answer "$ANSWER"
        [ -z "$answer" ] && answer=$default
        to_yes_no value "$answer"
        if [ -n "$value" ]; then
            write_log " > $prompt [$default]: $value"
            ANSWER=$value
            return 0
        fi
        write_out '   y or n' Yellow nolog
    done
}

# A password (PASSWORD), not shown. Kept in this tool's memory until it is
# written on the input of a sqlplus session.
read_password() {   # PROMPT
    while :; do
        read_prompt "$1" mask || stop_at_question "$1"
        if [ -n "$ANSWER" ]; then
            write_log " > $1: ********"
            PASSWORD=$ANSWER
            ANSWER=''
            return 0
        fi
        write_out '   a value is required' Yellow nolog
    done
}

# ----------------------------------------------------------------------------
# The inventory
# ----------------------------------------------------------------------------

# The rows of an inventory CSV, added to the INV_ arrays:
# table,column,rule,category,source,notes. Lines starting with # and blank
# lines are skipped, and the header line. The notes are the rest of the
# line, commas included. A line that is not a valid row stops the run, with
# its file and line number.
read_inventory_csv() {   # PATH SOURCE
    local path=$1 source=$2 line text n=0 bad table column rule category notes
    local re_name='^[A-Za-z][A-Za-z0-9_$#]*$' re_word='^[A-Za-z_]+$'
    local -a field
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        (( n == 1 )) && line=${line#$'\xEF\xBB\xBF'}
        trim text "$line"
        [ -z "$text" ] && continue
        [[ $text == '#'* ]] && continue
        field=()
        while (( ${#field[@]} < 5 )) && [[ $text == *,* ]]; do
            field+=("${text%%,*}")
            text=${text#*,}
        done
        field+=("$text")
        trim table "${field[0]}"
        [ "${table,,}" = table_name ] && continue
        trim column "${field[1]:-}"
        trim rule "${field[2]:-}"
        trim category "${field[3]:-}"
        bad=''
        if (( ${#field[@]} < 4 )); then
            bad='expected table,column,rule,category,source,notes'
        elif ! [[ $table =~ $re_name && $column =~ $re_name ]]; then
            bad='a table or column name has characters a name cannot have'
        elif ! [[ $rule =~ $re_word && $category =~ $re_word ]]; then
            bad='the rule or the category is not a single word'
        fi
        if [ -n "$bad" ]; then
            exit_tool $EXIT_ERROR "${path##*/}, line $n: $bad. Correct the line, or comment it out with #."
        fi
        notes=''
        (( ${#field[@]} >= 6 )) && trim notes "${field[5]}"
        INV_TABLE+=("$table"); INV_COLUMN+=("$column"); INV_RULE+=("$rule"); INV_CATEGORY+=("$category")
        INV_NOTES+=("$notes"); INV_SOURCE+=("$source")
    done < "$path"
}

# The inventory read so far, forgotten.
clear_inventory() {
    INV_TABLE=(); INV_COLUMN=(); INV_RULE=(); INV_CATEGORY=(); INV_NOTES=(); INV_SOURCE=()
}

# The inventory as SQL, in INV_SQL: one INSERT per row, numbered in file
# order. A site row (CUSTOM) replaces the shipped row of the same column: the
# custom file comes second, and its DELETE goes first. Quotes in the notes
# are doubled.
new_inventory_sql() {
    local i q="'" table column
    INV_SQL=('SET DEFINE OFF' 'SET FEEDBACK OFF')
    for (( i = 0; i < ${#INV_TABLE[@]}; i++ )); do
        table=${INV_TABLE[i]//$q/}
        column=${INV_COLUMN[i]//$q/}
        if [ "${INV_SOURCE[i]}" = CUSTOM ]; then
            INV_SQL+=("DELETE FROM anon_meta.anon_inventory WHERE table_name=UPPER('$table') AND column_name=UPPER('$column');")
        fi
        INV_SQL+=("INSERT INTO anon_meta.anon_inventory (table_name,column_name,rule,category,source,notes,seq) VALUES (UPPER('$table'),UPPER('$column'),UPPER('${INV_RULE[i]}'),UPPER('${INV_CATEGORY[i]}'),'${INV_SOURCE[i]}','${INV_NOTES[i]//$q/$q$q}',$((i + 1)));")
    done
    INV_SQL+=('COMMIT;' 'SET DEFINE ON')
}

# The site inventory file named by CUSTOM_INVENTORY, in config/.
custom_inventory_path() {   # VAR
    local _name=inventory_op_custom.csv
    test_given CUSTOM_INVENTORY && _name=${SET[CUSTOM_INVENTORY]}
    printf -v "$1" '%s' "$CONFIG_DIR/$_name"
}

# --inventory <file>: the inventory as SQL, written to a file; no database.
invoke_inventory_only() {   # FILE
    local target=$1 base custom key
    SET=()
    if read_config_file "$CONFIG_FILE"; then
        for key in "${!FILE_SETTINGS[@]}"; do SET[$key]=${FILE_SETTINGS[$key]}; done
    fi
    base=$CONFIG_DIR/inventory_op.csv
    [ -f "$base" ] || exit_tool $EXIT_ERROR "The inventory was not found: $base"
    custom_inventory_path custom
    clear_inventory
    read_inventory_csv "$base" BASE
    [ -f "$custom" ] && read_inventory_csv "$custom" CUSTOM
    new_inventory_sql
    [[ $target == /* ]] || target=$PWD/$target
    printf '%s\n' "${INV_SQL[@]}" > "$target" || exit_tool $EXIT_ERROR "The inventory could not be written to $target."
    write_out " Inventory written to $target"
    exit $EXIT_PASS
}

# The columns a label or attribute switch covers, for its question
# (SWITCH_COLUMNS): its own rows, the PARTY rows for a party category, and
# the structure rows.
switch_columns() {   # RULE CATEGORY
    local i cat tag name
    SWITCH_COLUMNS=()
    for (( i = 0; i < ${#INV_TABLE[@]}; i++ )); do
        [ "${INV_RULE[i]^^}" = "$1" ] || continue
        cat=${INV_CATEGORY[i]^^}
        tag=''
        [ "${INV_SOURCE[i]}" = CUSTOM ] && tag=' [site]'
        name="${INV_TABLE[i],,}.${INV_COLUMN[i],,}$tag"
        if [ "$cat" = "$2" ]; then
            SWITCH_COLUMNS+=("$name")
        elif [ "$cat" = PARTY ] && [ "$2" != BANK_ACCOUNT ]; then
            SWITCH_COLUMNS+=("$name (every party)")
        elif [ "$cat" = NODE_ROLE ]; then
            SWITCH_COLUMNS+=("$name (its structure nodes)")
        fi
    done
}

# ----------------------------------------------------------------------------
# sqlplus sessions
# ----------------------------------------------------------------------------

find_sqlplus() {
    SQLPLUS=$(type -P sqlplus 2> /dev/null)
    if [ -z "$SQLPLUS" ] && [ -n "${ORACLE_HOME:-}" ] && [ -x "$ORACLE_HOME/bin/sqlplus" ]; then
        SQLPLUS=$ORACLE_HOME/bin/sqlplus
    fi
    [ -n "$SQLPLUS" ]
}

# The environment of a process this tool starts: the operator's locale.
child_environment() {
    if [ -n "$ORIGINAL_LC_ALL_SET" ]; then export LC_ALL=$ORIGINAL_LC_ALL; else unset LC_ALL; fi
}

# sqlplus starts: a client missing its libraries (ORACLE_HOME, or
# LD_LIBRARY_PATH for an Instant Client) is said here, not as a failed
# connection later.
check_sqlplus() {
    local output first line
    output=$(child_environment; cd "$OP_DIR" && "$SQLPLUS" -V 2>&1)
    [[ $output == *'SQL*Plus'* ]] && return 0
    first=''
    while IFS= read -r line; do
        [[ $line == *[![:space:]]* ]] && { trim first "$line"; break; }
    done <<< "$output"
    printf -v line '   %-19s%s' sqlplus "$SQLPLUS"
    write_out "$line" Red
    exit_tool $EXIT_ERROR "sqlplus does not start (${first:-no output}). Check ORACLE_HOME and, for an Instant Client, LD_LIBRARY_PATH."
}

# The CONNECT line written on the input of a session. The password is quoted,
# so that one with @ or / is not read as part of the connect string.
connect_line() {   # VAR SYS|OP
    local _line="CONNECT ${L_USER[$2]}/\"${L_SECRET[$2]}\"@$L_TNS"
    (( L_SYSDBA[$2] )) && _line+=' AS SYSDBA'
    printf -v "$1" '%s' "$_line"
}

# A sqlplus process for a session (SESSION): its input a FIFO this tool
# writes to, its output a file this tool reads as it grows. It runs in a
# process group of its own, so that Ctrl+C at the terminal reaches this tool
# only - sqlplus would cancel the statement under way.
session_start() {   # NAME
    local i=${#S_NAME[@]} dir fdin fdout
    dir=$TMP_DIR/session$i
    if ! mkdir "$dir" || ! mkfifo "$dir/in" || ! : > "$dir/out"; then
        exit_tool $EXIT_ERROR "A sqlplus session could not be started: $dir could not be made."
    fi
    set -m
    session_child "$dir" &
    S_PID[i]=$!
    set +m
    exec {fdin}<> "$dir/in"
    exec {fdout}< "$dir/out"
    S_NAME[i]=$1; S_IN[i]=$fdin; S_OUT[i]=$fdout; S_DIR[i]=$dir; S_PART[i]=''; S_ENDED[i]=0; S_OK[i]=0; S_ERROR[i]=''
    SESSION=$i
}

# The process of a session, which becomes its sqlplus. It keeps none of the
# other sessions' descriptors, so that each input ends when this tool closes
# it.
session_child() {   # DIR
    local fd
    for fd in "${S_IN[@]}" "${S_OUT[@]}" "$PAUSE_FD"; do
        [ -n "$fd" ] && exec {fd}>&-
    done
    child_environment
    cd "$OP_DIR" || exit 1
    exec "$SQLPLUS" -S -L /nolog < "$1/in" > "$1/out" 2>&1
}

# The next complete line a session printed, in LINE; 1 when there is none
# yet. With end - once sqlplus has ended - a last line without its newline
# counts as one.
session_read() {   # SESSION [end]
    local _i=$1 _chunk
    if IFS= read -r _chunk <&"${S_OUT[_i]}"; then
        LINE=${S_PART[_i]}$_chunk
        S_PART[_i]=''
        LINE=${LINE%$'\r'}
        return 0
    fi
    S_PART[_i]+=$_chunk
    if [ "${2:-}" = end ] && [ -n "${S_PART[_i]}" ]; then
        LINE=${S_PART[_i]%$'\r'}
        S_PART[_i]=''
        return 0
    fi
    return 1
}

session_alive() { kill -0 "${S_PID[$1]}" 2> /dev/null; }

# A sqlplus session connected as $1 (SYS or OP), in SESSION. Only the CONNECT
# line goes first, with a marker after it: sqlplus prints the marker once the
# CONNECT has finished, whether it succeeded or not. S_OK says whether it is
# connected; S_ERROR the ORA- or SP2- line of a CONNECT that failed; OUT
# holds every line it printed.
session_open() {   # SYS|OP NAME
    local i line deadline at_end=''
    local -a _so_lines=()
    session_start "$2"
    i=$SESSION
    connect_line line "$1"
    printf '%s\nPROMPT %s\n' "$line" "$READY_MARKER" >&"${S_IN[i]}"
    line=''
    now
    deadline=$((NOW + CONNECT_TIMEOUT_S))
    while :; do
        if session_read "$i" $at_end; then
            if [ "$LINE" = "$READY_MARKER" ]; then
                if [ -z "${S_ERROR[i]}" ]; then S_OK[i]=1; else session_close "$i" kill; fi
                break
            fi
            _so_lines+=("$LINE")
            if [ -z "${S_ERROR[i]}" ] && [[ $LINE =~ $RE_ORACLE_ERROR ]] && ! [[ $LINE =~ $CONNECT_WARNINGS ]]; then
                trim "S_ERROR[$i]" "${BASH_REMATCH[0]}"
            fi
            continue
        fi
        if [ -n "$at_end" ]; then
            S_ENDED[i]=1
            if [ -z "${S_ERROR[i]}" ]; then
                S_ERROR[i]='sqlplus ended before it connected.'
                for line in "${_so_lines[@]}"; do
                    if [[ $line == *[![:space:]]* ]]; then trim line "$line"; S_ERROR[i]="sqlplus ended before it connected: $line"; break; fi
                done
            fi
            break
        fi
        if ! session_alive "$i"; then at_end=end; continue; fi
        check_stop
        now
        if (( NOW >= deadline )); then
            S_ERROR[i]="no answer from $L_TNS within $CONNECT_TIMEOUT_S s"
            session_close "$i" kill
            break
        fi
        pause 0.25
    done
    OUT=("${_so_lines[@]}")
}

# A session's descriptors closed and its files removed.
session_dispose() {   # SESSION
    local fd
    fd=${S_IN[$1]}
    [ -n "$fd" ] && exec {fd}>&-
    fd=${S_OUT[$1]}
    [ -n "$fd" ] && exec {fd}<&-
    S_IN[$1]=''; S_OUT[$1]=''; S_ENDED[$1]=1
    [ -n "${S_DIR[$1]}" ] && rm -rf "${S_DIR[$1]}"
    S_DIR[$1]=''
}

# Ends a session: EXIT on its input, then up to 15 s for sqlplus to end;
# with kill, or when it does not end, its process is ended.
session_close() {   # SESSION [kill]
    local i=$1 fd n
    (( i >= 0 )) || return 0
    [ -n "${S_DIR[i]}" ] || return 0
    if session_alive "$i"; then
        if [ "${2:-}" = kill ]; then
            kill "${S_PID[i]}" 2> /dev/null
        else
            fd=${S_IN[i]}
            if [ -n "$fd" ]; then
                printf 'EXIT\n' >&"$fd"
                exec {fd}>&-
                S_IN[i]=''
            fi
            for (( n = 0; n < 60; n++ )); do
                session_alive "$i" || break
                pause 0.25
            done
            session_alive "$i" && kill "${S_PID[i]}" 2> /dev/null
        fi
    fi
    session_dispose "$i"
}

# Ends every sqlplus session still running, so that none outlives the tool.
stop_children() {
    local i
    for (( i = 0; i < ${#S_PID[@]}; i++ )); do
        if session_alive "$i"; then
            kill "${S_PID[i]}" 2> /dev/null || write_log " A sqlplus session could not be ended (PID ${S_PID[i]})."
        fi
    done
}

# A script of this tool, as sqlplus runs it: @"<path>" and its arguments.
script_line() {   # VAR PATH ARGUMENTS...
    local _line="@\"$2\"" _a
    for _a in "${@:3}"; do _line+=" $_a"; done
    printf -v "$1" '%s' "$_line"
}

# Sends commands to an open session and reads what it prints up to an end
# marker, into OUT. $3, when given, runs about every two seconds meanwhile
# (the live view), and Ctrl+C is acted on meanwhile; without it (the
# monitor's own commands) a Ctrl+C is left for the wait that called it. A
# session that ends before the marker (its connection lost, sqlplus ended)
# sets S_ENDED. $2: seconds to wait at most, 0 as long as the command takes;
# 2 is returned when they run out, OUT_ERROR saying so.
session_command() {   # SESSION TIMEOUT ON_WAIT COMMANDS...
    local i=$1 timeout=$2 on_wait=$3 marker next deadline=0 at_end='' waiting
    local -a _sc_lines=()
    shift 3
    OUT=()
    if (( S_ENDED[i] )) || ! session_alive "$i"; then
        S_ENDED[i]=1
        return 0
    fi
    MARKER_SEQ=$((MARKER_SEQ + 1))
    marker=ANON_END_$$_${MARKER_SEQ}_$RANDOM$RANDOM
    printf '%s\n' "$@" "PROMPT $marker" >&"${S_IN[i]}"
    now
    next=$((NOW + 2))
    (( timeout > 0 )) && deadline=$((NOW + timeout))
    while :; do
        waiting=0
        if session_read "$i" $at_end; then
            [ "$LINE" = "$marker" ] && break
            _sc_lines+=("$LINE")
        elif [ -n "$at_end" ]; then
            S_ENDED[i]=1
            break
        elif ! session_alive "$i"; then
            at_end=end
            continue
        else
            waiting=1
        fi
        [ -n "$on_wait" ] && check_stop
        now
        if [ -n "$on_wait" ] && (( NOW >= next )); then
            $on_wait
            now
            next=$((NOW + 2))
        fi
        if (( deadline > 0 && NOW >= deadline )); then
            OUT=("${_sc_lines[@]}")
            OUT_ERROR="The ${S_NAME[i]} session did not answer within $timeout s."
            return 2
        fi
        (( waiting )) && pause 0.25
    done
    OUT=("${_sc_lines[@]}")
    return 0
}

# One script in a session of its own: connect, run, EXIT. Sets SCRIPT_EXIT
# (1 when the session could not connect), SCRIPT_ERROR, and OUT: every line
# it printed. $3 as for session_command.
sql_script() {   # SYS|OP NAME ON_WAIT COMMANDS...
    local on_wait=$3 i fd next at_end='' waiting
    local -a _ss_lines=()
    session_open "$1" "$2"
    i=$SESSION
    shift 3
    _ss_lines=("${OUT[@]}")
    SCRIPT_ERROR=''
    if (( ! S_OK[i] )); then
        SCRIPT_EXIT=$EXIT_ERROR
        SCRIPT_ERROR=${S_ERROR[i]}
        session_dispose "$i"
        OUT=("${_ss_lines[@]}")
        return
    fi
    fd=${S_IN[i]}
    printf '%s\n' "$@" EXIT >&"$fd"
    exec {fd}>&-
    S_IN[i]=''
    now
    next=$((NOW + 2))
    while :; do
        waiting=0
        if session_read "$i" $at_end; then
            _ss_lines+=("$LINE")
        elif [ -n "$at_end" ]; then
            break
        elif ! session_alive "$i"; then
            at_end=end
            continue
        else
            waiting=1
        fi
        check_stop
        now
        if [ -n "$on_wait" ] && (( NOW >= next )); then
            $on_wait
            now
            next=$((NOW + 2))
        fi
        (( waiting )) && pause 0.25
    done
    # The exit code of sqlplus; a signal that interrupts the wait is not one.
    while :; do
        wait "${S_PID[i]}" 2> /dev/null
        SCRIPT_EXIT=$?
        (( SCRIPT_EXIT > 128 )) && session_alive "$i" && continue
        break
    done
    session_dispose "$i"
    OUT=("${_ss_lines[@]}")
}

# Connects as $1 and says what to (ANON_SESSION of run/session.sql): TEST_OK,
# TEST_DATABASE and TEST_VERSION, or TEST_ERROR.
test_login() {   # SYS|OP
    local cmd line re='^ANON_SESSION[|]([^|]*)[|]([^|]*)[|]([^|]*)[|]([^|]*)[|](.*)$'
    script_line cmd "$RUN_SQL_DIR/session.sql"
    sql_script "$1" "test ${L_USER[$1]}" '' "$cmd"
    for line in "${OUT[@]}"; do
        if [[ $line =~ $re ]]; then
            TEST_OK=1
            TEST_DATABASE=${BASH_REMATCH[2]}; TEST_VERSION=${BASH_REMATCH[4]}; TEST_ERROR=''
            return
        fi
    done
    TEST_OK=0
    TEST_ERROR=$SCRIPT_ERROR
    if [ -z "$TEST_ERROR" ]; then
        for line in "${OUT[@]}"; do
            if [[ $line =~ $RE_ORACLE_ERROR ]]; then trim TEST_ERROR "${BASH_REMATCH[0]}"; break; fi
        done
    fi
    [ -z "$TEST_ERROR" ] && TEST_ERROR='the connection test printed nothing it could read'
}

# ----------------------------------------------------------------------------
# Ctrl+C
# ----------------------------------------------------------------------------
# Ctrl+C (SIGINT) - and SIGTERM, from kill - is counted here and acted on
# where the tool waits for a session (check_stop) or at a question: it never
# ends the tool while a session works, and so never leaves OP's triggers
# disabled. sqlplus does not receive it: each session runs in a process group
# of its own (session_start). A closed terminal (SIGHUP) stops nothing: it is
# ignored, by this tool and by every process it starts, and the run goes on
# to its end without its screen (the first write to the closed terminal
# fails: console_text) and leaves its folder.

on_stop_signal() { PENDING_STOP=$((PENDING_STOP + 1)); }

# The width of the terminal, kept up to date (SIGWINCH).
read_terminal_width() {
    local size re='^[0-9]+ ([0-9]+)$'
    TERM_COLUMNS=${COLUMNS:-80}
    (( OUTPUT_IS_TTY )) || return 0
    size=$(stty size < /dev/tty 2> /dev/null)
    [[ $size =~ $re ]] && TERM_COLUMNS=${BASH_REMATCH[1]}
    (( TERM_COLUMNS > 0 )) || TERM_COLUMNS=80
}

# Acts on each Ctrl+C counted: the first asks for a stop, once.
check_stop() {
    while (( PENDING_STOP > 0 )); do
        PENDING_STOP=$((PENDING_STOP - 1))
        if (( STOP_ASKED )); then
            write_out ' Stop already asked for: the run stops after the table or column it works on.' Yellow
        else
            STOP_ASKED=1
            request_stop
        fi
    done
}

# The working files of the tool, removed on every way out, with the
# terminal as it was and no sqlplus session left running.
on_exit() {
    clear_status
    stop_children
    [ -n "$TTY_SAVED" ] && stty "$TTY_SAVED" 2> /dev/null
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

# The tool's own working files - the sessions' input and output - in a
# folder only its owner can read.
make_temp_dir() {
    TMP_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/anon_op.XXXXXX" 2> /dev/null) ||
        exit_tool $EXIT_ERROR "A working folder could not be made in ${TMPDIR:-/tmp}."
    if mkfifo "$TMP_DIR/pause" 2> /dev/null; then exec {PAUSE_FD}<> "$TMP_DIR/pause"; fi
}

# ----------------------------------------------------------------------------
# The run
# ----------------------------------------------------------------------------

run_label() { printf -v "$1" 'R-%06d' "$2"; }   # VAR RUN_ID

# op/logs/<date>_<time>_R-<run>: the run's folder. console.log begins with
# every line written so far.
new_run_folder() {
    local stamp label
    printf -v stamp '%(%Y-%m-%d_%H%M%S)T' -1
    run_label label "$RUN_ID"
    RUN_FOLDER=$LOG_ROOT/${stamp}_$label
    mkdir -p "$RUN_FOLDER" || exit_tool $EXIT_ERROR "The run folder could not be made: $RUN_FOLDER"
    LOG_FILE=$RUN_FOLDER/console.log
    if (( ${#BUFFERED[@]} > 0 )); then printf '%s\n' "${BUFFERED[@]}" > "$LOG_FILE"; else : > "$LOG_FILE"; fi
    BUFFERED=()
}

# A folder as the screen shows it: from the current directory when it lies
# below it.
format_folder() {   # VAR PATH
    if [[ $2 == "$PWD"/* ]]; then printf -v "$1" '%s' "${2#"$PWD"/}"; else printf -v "$1" '%s' "$2"; fi
}

write_run_file() {   # NAME LINES...
    [ -n "$RUN_FOLDER" ] || return 0
    if (( $# > 1 )); then printf '%s\n' "${@:2}" > "$RUN_FOLDER/$1"; else : > "$RUN_FOLDER/$1"; fi
}

# Lines of the engine for report.txt: all but the ones this tool reads.
report_add() {   # LINES...
    local line
    local -a keep=()
    for line in "$@"; do [[ $line =~ ^ANON_[A-Z_]+[|] ]] || keep+=("$line"); done
    (( ${#keep[@]} > 0 )) && printf '%s\n' "${keep[@]}" >> "$RUN_REPORT"
    return 0
}

# The ANON_RESULT line of a script's output: RESULT_STATUS and
# RESULT_MESSAGE.
script_result() {   # LINES...
    local line re='^ANON_RESULT[|]([A-Z]+)[|]?([^|]*)[|]?(.*)$'
    for line in "$@"; do
        if [[ $line =~ $re ]]; then
            RESULT_STATUS=${BASH_REMATCH[1]}; RESULT_MESSAGE=${BASH_REMATCH[3]}
            return
        fi
    done
    # No result line: the script did not run to its end (an error before it,
    # or the session ended).
    RESULT_STATUS=FAILED; RESULT_MESSAGE=''
    for line in "$@"; do
        if [[ $line =~ $RE_ORACLE_ERROR ]]; then trim RESULT_MESSAGE "${BASH_REMATCH[0]}"; break; fi
    done
    [ -z "$RESULT_MESSAGE" ] && RESULT_MESSAGE='the session printed no result'
}

# Asks the run to stop (stop.sql in the monitor session). The engine reads the
# request between two tables or columns. Before the work begins, the run is
# stopped by this tool itself once the step under way ends.
request_stop() {
    local cmd line found=''
    if (( RUN_VERIFYING )); then
        write_out ' Ctrl+C: the run is complete; its verification is read-only and ends by itself in a moment.' Yellow
        return
    fi
    if (( RUN_ID == 0 || ! RUN_WORKING )); then
        write_out ' Ctrl+C: stopping once the step under way ends. Nothing has been changed yet.' Yellow
        return
    fi
    write_out ' Ctrl+C: the run stops after the table or column it works on, then enables the triggers of OP again.' Yellow
    if (( MONITOR < 0 )); then
        write_out " The monitor session is not available: run op/sql/run/stop.sql $RUN_ID as OP to stop it." Yellow
        return
    fi
    script_line cmd "$RUN_SQL_DIR/stop.sql" "$RUN_ID"
    if session_command "$MONITOR" 60 '' "$cmd"; then
        for line in "${OUT[@]}"; do
            if [[ $line == 'ANON_STOP|'* ]]; then found=$line; break; fi
        done
        [[ $found == 'ANON_STOP|REQUESTED'* ]] || write_out " The stop could not be asked for: ${OUT[*]}" Yellow
    else
        write_out " The stop could not be asked for: $OUT_ERROR" Yellow
    fi
}

# One look at the run (poll.sql in the monitor session): the steps logged
# since the last look, where the run is now. A monitor that does not answer is
# given up: the live view stops, the run goes on.
update_live_view() {   # [RUN|VERIFY]
    local mode=${1:-RUN} cmd
    if (( MONITOR < 0 || ! RUN_LIVE )); then
        show_flow_status none
        return
    fi
    P_HAS_PROGRESS=0; P_HAS_LONGOP=0; P_VERIFY=()
    # poll.sql returns 500 rows of the log at most: read on until it is
    # caught up.
    POLL_STEPS=500
    while (( POLL_STEPS >= 500 )); do
        script_line cmd "$RUN_SQL_DIR/poll.sql" "$RUN_ID" "$LAST_STEP" "$mode"
        if ! session_command "$MONITOR" 60 '' "$cmd"; then
            RUN_LIVE=0
            write_out " The live view stops: $OUT_ERROR The run goes on." Yellow
            return
        fi
        if (( S_ENDED[MONITOR] )); then
            RUN_LIVE=0
            write_out ' The live view stops: its session ended. The run goes on.' Yellow
            return
        fi
        read_poll_lines "${OUT[@]}"
    done
    show_flow_status poll
}

# The lines of one poll: the steps go to the screen's accounts as they come;
# where the run is, into P_...; POLL_STEPS: how many steps it read.
read_poll_lines() {   # LINES...
    local line rows x ms
    local -a f
    POLL_STEPS=0
    for line in "$@"; do
        if [[ $line == 'ANON_STEP|'* ]]; then
            split_fields f "$line" 10
            (( ${#f[@]} < 10 )) && continue
            POLL_STEPS=$((POLL_STEPS + 1))
            to_int LAST_STEP "${f[1]}"
            to_int rows "${f[4]}"; to_int x "${f[5]}"; to_int ms "${f[6]}"
            add_flow_step "$LAST_STEP" "${f[2]}" "${f[3]}" "$rows" "$x" "$ms" "${f[7]}" "${f[8]}" "${f[9]}"
        elif [[ $line == 'ANON_PROGRESS|'* ]]; then
            split_fields f "$line" 11
            (( ${#f[@]} < 11 )) && continue
            P_HAS_PROGRESS=1
            P_PHASE=${f[1]}; P_STAGE=${f[2]}
            to_int P_DONE "${f[3]}"; to_int P_TOTAL "${f[4]}"; to_int P_WDONE "${f[5]}"; to_int P_WEIGHT "${f[6]}"
            to_int P_WTOTAL "${f[7]}"; to_int P_INPHASE "${f[9]}"
            P_OBJECT=${f[10]}
        elif [[ $line == 'ANON_LONGOP|'* ]]; then
            split_fields f "$line" 4
            if (( ${#f[@]} == 4 )); then
                P_HAS_LONGOP=1
                to_int P_PCT "${f[1]}"
            fi
        elif [[ $line == 'ANON_VERIFY|'* ]]; then
            split_fields f "$line" 0
            (( ${#f[@]} >= 3 )) && to_int "P_VERIFY[${f[1]}]" "${f[2]}"
        elif [[ $line =~ $RE_ORACLE_CODE ]]; then
            write_log " monitor: $line"
        fi
    done
}

# Runs one script in the worker session, with the live view meanwhile; its
# lines in OUT. They go to report.txt (the engine's lines) and, with
# --verbose, to the screen.
invoke_worker() {   # COMMANDS...
    local -a lines
    session_command "$WORKER" 0 update_live_view "$@"
    lines=("${OUT[@]}")
    report_add "${lines[@]}"
    show_lines detail "${lines[@]}"
    OUT=("${lines[@]}")
}

# manifest.txt: the run in key=value lines, for whoever reviews it.
write_manifest() {   # STATUS VERDICT EXIT_CODE
    local key i label stamp stop=N
    local -a m=()
    run_label label "$RUN_ID"
    printf -v stamp '%(%Y-%m-%d %H:%M:%S)T' -1
    (( STOP_ASKED )) && stop=Y
    m+=("run=$label" "mode=$RUN_MODE" "written_at=$stamp" "tool_version=$RUN_VERSION" "database=$RUN_DATABASE" "connect=$RUN_TNS")
    for key in "${SWITCH_KEYS[@]}" APPROVE_STRUCTURE_ONLY_ACCOUNTS PARALLEL_DEGREE FAIL_ON_MISSING_OBJECT CUSTOM_INVENTORY; do
        m+=("${key,,}=${SET[$key]}")
    done
    m+=("inventory_items=$INV_ITEMS" "inventory_shipped=$INV_SHIPPED" "inventory_site=$INV_SITE" "inventory_here=$INV_HERE")
    for (( i = 0; i < ${#D_KEY[@]}; i++ )); do m+=("step.${D_KEY[i]}=${D_STATUS[i]}|${D_SECONDS[i]}"); done
    for (( i = 0; i < ${#C_CODE[@]}; i++ )); do m+=("check.${C_CODE[i],,}=${C_STATUS[i]}|${C_STATE[i]}"); done
    m+=("stop_requested=$stop" "status=$1" "verdict=$2" "exit_code=$3")
    write_run_file manifest.txt "${m[@]}"
}

# Settles every setting (SET): the configuration file, the environment
# (passwords), then the questions for what is still missing. Without
# questions (--auto) a missing value that has no default ends the tool.
get_settings() {
    local interactive=1 key value r category name rule what c custom parallel re_ts='^[A-Za-z][A-Za-z0-9_$#]*$' rows=0
    (( CLI_AUTO )) && interactive=0
    SET=()
    for key in "${!FILE_SETTINGS[@]}"; do SET[$key]=${FILE_SETTINGS[$key]}; done
    [ -n "${ANON_SYS_PASSWORD:-}" ] && SET[SYS_PASSWORD]=$ANON_SYS_PASSWORD
    [ -n "${ANON_OP_PASSWORD:-}" ] && SET[OP_PASSWORD]=$ANON_OP_PASSWORD
    # Read once: no process this tool starts is given them.
    unset ANON_SYS_PASSWORD ANON_OP_PASSWORD

    # Missing without questions: what cannot be defaulted stops the run.
    if (( ! interactive )); then
        for r in 'ORACLE_SID|the database (its alias in tnsnames.ora, or host:port/service)' \
                 'SYS_PASSWORD|the SYS password (or ANON_SYS_PASSWORD in the environment)' \
                 'OP_PASSWORD|the OP password (or ANON_OP_PASSWORD in the environment)' \
                 'TABLESPACE_DATA|the tablespace of the ANON_META tables'; do
            if ! test_given "${r%%|*}"; then
                exit_tool $EXIT_ERROR "${r%%|*} is not set: ${r#*|}. --auto asks nothing: set it in config/anonymization.ini."
            fi
        done
    fi

    if ! test_given ORACLE_SID; then
        write_ask 'Database'
        read_answer 'Database (its alias in tnsnames.ora, or host:port/service)'
        SET[ORACLE_SID]=$ANSWER
    fi
    if ! test_given SYS_PASSWORD || ! test_given OP_PASSWORD; then
        write_ask 'Passwords'
        write_out '   Sent to sqlplus on its input: never on a command line, never written down.'
        if ! test_given SYS_PASSWORD; then read_password 'SYS password'; SECRET[SYS]=$PASSWORD; fi
        if ! test_given OP_PASSWORD; then read_password 'OP password'; SECRET[OP]=$PASSWORD; fi
        PASSWORD=''
    fi
    if ! test_given TABLESPACE_DATA; then
        write_ask 'Tablespaces of ANON_META'
        write_out '   ANON_META holds the translations, the inventory and the run log: a few MB.'
        read_answer 'Tablespace of its tables' '' "$re_ts" 'a tablespace name'
        SET[TABLESPACE_DATA]=$ANSWER
    fi
    if ! test_given TABLESPACE_INDEX; then
        if (( interactive )); then
            read_answer 'Tablespace of its indexes' "${SET[TABLESPACE_DATA]}" "$re_ts" 'a tablespace name'
            SET[TABLESPACE_INDEX]=$ANSWER
        else
            SET[TABLESPACE_INDEX]=${SET[TABLESPACE_DATA]}
        fi
    fi
    for key in TABLESPACE_DATA TABLESPACE_INDEX; do
        [[ ${SET[$key]} =~ $re_ts ]] || exit_tool $EXIT_ERROR "$key must be a tablespace name, not \"${SET[$key]}\"."
    done

    # The switches: the configuration file's, asked when blank (with the
    # columns each one covers), y without questions.
    for key in "${SWITCH_KEYS[@]}"; do
        if test_given "$key"; then
            to_yes_no value "${SET[$key]}"
            if [ -z "$value" ]; then
                exit_tool $EXIT_ERROR "$key must be y or n, not \"${SET[$key]}\" (config/anonymization.ini). Nothing was changed."
            fi
            SET[$key]=$value
            continue
        fi
        if (( ! interactive )); then SET[$key]=y; continue; fi
        if (( ! rows )); then
            rows=1
            clear_inventory
            read_inventory_csv "$CONFIG_DIR/inventory_op.csv" BASE
            custom_inventory_path custom
            [ -f "$custom" ] && read_inventory_csv "$custom" CUSTOM
            write_ask 'What is anonymized'
            write_out '   config/anonymization.ini leaves these switches blank. Free text is always emptied.'
        fi
        category=${key#ANONYMIZE_}
        category=${category%_DESCRIPTION}
        category=${category%_ATTRIBUTES}
        name=${CATEGORY_NAMES[$category]}
        if [[ $key == *_DESCRIPTION || $key == *_ATTRIBUTES ]]; then
            rule=SELF_CODE; what=attributes
            if [[ $key == *_DESCRIPTION ]]; then rule=DESCRIPTION; what=labels; fi
            switch_columns "$rule" "$category"
            write_out "   $name, $what - the columns it covers:"
            (( ${#SWITCH_COLUMNS[@]} == 0 )) && write_out '       none in the inventory: nothing would change' DarkGray
            for c in "${SWITCH_COLUMNS[@]}"; do write_out "       $c" DarkGray; done
            read_yes_no_answer "Mask ${name,,} $what"
        else
            read_yes_no_answer "Rename ${name,,} codes"
        fi
        SET[$key]=$ANSWER
    done

    # Settings with a default, never asked.
    test_given APPROVE_STRUCTURE_ONLY_ACCOUNTS || SET[APPROVE_STRUCTURE_ONLY_ACCOUNTS]=y
    test_given PARALLEL_DEGREE || SET[PARALLEL_DEGREE]=4
    test_given FAIL_ON_MISSING_OBJECT || SET[FAIL_ON_MISSING_OBJECT]=n
    test_given CUSTOM_INVENTORY || SET[CUSTOM_INVENTORY]=inventory_op_custom.csv
    for key in APPROVE_STRUCTURE_ONLY_ACCOUNTS FAIL_ON_MISSING_OBJECT; do
        to_yes_no value "${SET[$key]}"
        [ -z "$value" ] && exit_tool $EXIT_ERROR "$key must be y or n, not \"${SET[$key]}\"."
        SET[$key]=$value
    done
    parallel=${SET[PARALLEL_DEGREE]}
    if ! [[ $parallel =~ ^[+]?[0-9]{1,9}$ ]] || (( 10#${parallel#+} < 1 || 10#${parallel#+} > 32 )); then
        exit_tool $EXIT_ERROR "PARALLEL_DEGREE must be a whole number from 1 to 32, not \"${SET[PARALLEL_DEGREE]}\"."
    fi
    if [[ ${SET[CUSTOM_INVENTORY]} == *[\\/:]* ]]; then
        exit_tool $EXIT_ERROR "CUSTOM_INVENTORY names a file in config/, not a path: \"${SET[CUSTOM_INVENTORY]}\"."
    fi
}

# Connects as SYS and as OP, before anything else: a wrong alias or password
# is a line here, not an error later. A password refused at a question is
# asked again (three times at most).
connect_database() {   # INTERACTIVE
    local interactive=$1 tns=${SET[ORACLE_SID]} who attempt refused hint line
    L_TNS=$tns
    for who in SYS OP; do
        L_USER[$who]=${who,,}
        L_SYSDBA[$who]=0
        [ "$who" = SYS ] && L_SYSDBA[$who]=1
        if [ -n "${SECRET[$who]+x}" ]; then L_SECRET[$who]=${SECRET[$who]}; else L_SECRET[$who]=${SET[${who}_PASSWORD]}; fi
        attempt=0
        while :; do
            attempt=$((attempt + 1))
            show_status "   Database           connecting as $who to $tns"
            test_login "$who"
            if (( TEST_OK )); then
                if [ "$who" = SYS ]; then SYS_VERSION=$TEST_VERSION; SYS_DATABASE=$TEST_DATABASE; fi
                break
            fi
            refused=0
            [[ $TEST_ERROR =~ ORA-01017|ORA-01005 ]] && refused=1
            printf -v line '   %-19sthe connection as %s to %s failed: %s' Database "$who" "$tns" "$TEST_ERROR"
            write_out "$line" Red
            if (( refused && interactive && attempt < 3 )); then
                read_password "$who password (again)"
                L_SECRET[$who]=$PASSWORD
                PASSWORD=''
                continue
            fi
            hint='Check the database alias (ORACLE_SID in config/anonymization.ini) and that the database is open.'
            (( refused )) && hint="Check the $who password."
            exit_tool $EXIT_ERROR "$hint Nothing was changed."
        done
    done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

invoke_main() {
    local mode=run left banner line config_text
    read_arguments "$@"
    (( CLI_NO_COLOR )) && USE_COLOR=0
    if (( CLI_HELP )); then show_help; exit $EXIT_PASS; fi
    (( CLI_HAS_INVENTORY )) && invoke_inventory_only "$CLI_INVENTORY"
    VERBOSE=$CLI_VERBOSE
    STATUS_LINE=$OUTPUT_IS_TTY
    [ -t 0 ] && STOP_KEYS=1
    read_terminal_width
    (( OUTPUT_IS_TTY )) && trap read_terminal_width WINCH
    tool_version
    (( CLI_DRYRUN )) && mode='dry run'

    left=" OP Anonymization $TOOL_VERSION"
    printf -v banner '%s%*s' "$left" $((WIDTH - ${#left} > 1 ? WIDTH - ${#left} : 1)) "$mode"
    printf -v line '%*s' $((WIDTH - 1)) ''
    write_out ''
    write_out "$banner" White
    write_out " ${line// /-}"
    write_out ''
    write_out ' Getting ready' White
    now
    READY_STARTED=$NOW
    make_temp_dir

    if ! find_sqlplus; then
        printf -v line '   %-19snot found' sqlplus
        write_out "$line" Red
        exit_tool $EXIT_ERROR 'sqlplus is neither in PATH nor in ORACLE_HOME/bin. Install the Oracle client, or add its bin folder to PATH.'
    fi
    check_sqlplus
    write_kv sqlplus "$SQLPLUS"

    config_text='config/anonymization.ini'
    if ! read_config_file "$CONFIG_FILE"; then
        (( CLI_AUTO )) && exit_tool $EXIT_ERROR "--auto needs config/anonymization.ini, and there is none: $CONFIG_FILE"
        config_text='none (config/anonymization.ini): every value is asked for'
    fi
    if [ -n "${ANON_SYS_PASSWORD:-}" ] || [ -n "${ANON_OP_PASSWORD:-}" ]; then config_text+='; passwords from the environment'; fi
    write_kv Configuration "$config_text"
    get_settings
    invoke_run
}

# Runs the anonymization, or its dry run, from getting ready to its report.
invoke_run() {
    local tns=${SET[ORACLE_SID]} oracle cmd cmd2 line clock what engine n i t key custom inv label shown text
    local -a f load_errors=() shown_lines=() results=()
    connect_database $((! CLI_AUTO))
    oracle=$SYS_VERSION
    [[ $oracle =~ ^([0-9]+[.][0-9]+) ]] && oracle=${BASH_REMATCH[1]}
    write_kv Database "$tns: connected as SYS and as OP (Oracle $oracle)"
    new_run_state "$TOOL_VERSION" "$CLI_DRYRUN" "$tns" "$SYS_DATABASE"

    # ANON_META, created or brought up to date (as SYS).
    now
    STEP_STARTED=$NOW
    script_line cmd "$SQL_DIR/10_create_metadata_schema.sql" "${SET[TABLESPACE_DATA]}" "${SET[TABLESPACE_INDEX]}"
    sql_script SYS SYS status_metadata 'WHENEVER SQLERROR EXIT FAILURE' "$cmd" 'EXIT SUCCESS'
    (( ${#OUT[@]} > 0 )) && printf '%s\n' "${OUT[@]}" >> "$RUN_REPORT"
    show_lines detail "${OUT[@]}"
    if (( SCRIPT_EXIT != 0 )); then
        printf -v line '   %-19sANON_META could not be prepared:' Metadata
        write_out "$line" Red
        n=0
        for line in "${OUT[@]}"; do
            [[ $line =~ $RE_ORACLE_CODE ]] || continue
            write_out "     $line" Red
            n=$((n + 1))
            (( n >= 5 )) && break
        done
        exit_tool $EXIT_ERROR 'Nothing in OP was changed.'
    fi
    what='up to date'
    shopt -s nocasematch
    for line in "${OUT[@]}"; do
        if [[ $line =~ ^[[:space:]]+created\ user\ anon_meta ]]; then what='created now'; break; fi
    done
    if [ "$what" = 'up to date' ]; then
        for line in "${OUT[@]}"; do
            if [[ $line =~ ^[[:space:]]+(migrated|created\ anon_meta|dropped) ]]; then what=upgraded; break; fi
        done
    fi
    shopt -u nocasematch
    now
    fmt_clock clock $((NOW - STEP_STARTED))
    write_kv Metadata "ANON_META on tablespace ${SET[TABLESPACE_DATA]}: $what ($clock)"
    (( STOP_ASKED )) && exit_tool $EXIT_STOPPED 'Stopped before the run began. Nothing in OP was changed.'

    # The worker session (as OP): the engine, the inventory, then the run.
    now
    STEP_STARTED=$NOW
    session_open OP worker
    (( S_OK[SESSION] )) || exit_tool $EXIT_ERROR "The worker session did not connect as OP: ${S_ERROR[SESSION]}"
    WORKER=$SESSION
    script_line cmd "$SQL_DIR/30_install_engine.sql"
    script_line cmd2 "$RUN_SQL_DIR/engine.sql"
    session_command "$WORKER" 0 status_engine "$cmd" "$cmd2"
    report_add "${OUT[@]}"
    show_lines detail "${OUT[@]}"
    engine=''
    for line in "${OUT[@]}"; do
        if [[ $line =~ ^ANON_ENGINE[|]VALID[|]VALID[|].+$ ]]; then engine=$line; break; fi
    done
    if [ -z "$engine" ]; then
        printf -v line '   %-19sit did not compile:' Engine
        write_out "$line" Red
        n=0
        for line in "${OUT[@]}"; do
            [[ $line =~ PLS-|ORA-|SP2-|LINE/COL|^[0-9]+/[0-9]+ ]] || continue
            write_out "     $line" Red
            n=$((n + 1))
            (( n >= 8 )) && break
        done
        exit_tool $EXIT_ERROR 'Nothing in OP was changed.'
    fi
    split_fields f "$engine" 0
    now
    fmt_clock clock $((NOW - STEP_STARTED))
    write_kv Engine "version ${f[3]} (installed, $clock)"
    (( STOP_ASKED )) && exit_tool $EXIT_STOPPED 'Stopped before the run began. Nothing in OP was changed.'

    # The inventory: the CSVs as INSERT statements on the worker's input, in
    # parts, then validated.
    clear_inventory
    read_inventory_csv "$CONFIG_DIR/inventory_op.csv" BASE
    custom_inventory_path custom
    [ -f "$custom" ] && read_inventory_csv "$custom" CUSTOM
    new_inventory_sql
    for (( i = 0; i < ${#INV_SQL[@]}; i += 100 )); do
        session_command "$WORKER" 0 '' 'WHENEVER SQLERROR CONTINUE' "${INV_SQL[@]:i:100}"
        for line in "${OUT[@]}"; do [[ $line =~ $RE_ORACLE_CODE ]] && load_errors+=("$line"); done
    done
    script_line cmd "$SQL_DIR/21_validate_inventory.sql"
    script_line cmd2 "$RUN_SQL_DIR/inventory.sql"
    session_command "$WORKER" 0 '' "$cmd" "$cmd2"
    report_add "${OUT[@]}"
    show_lines detail "${OUT[@]}"
    inv=''
    for line in "${OUT[@]}"; do
        if [[ $line == 'ANON_INVENTORY|'* ]]; then inv=$line; break; fi
    done
    n=0
    shopt -s nocasematch
    for line in "${OUT[@]}"; do [[ $line =~ ^[[:space:]]+INVALID|ORA-[0-9]{5} ]] && n=$((n + 1)); done
    if (( ${#load_errors[@]} > 0 || n > 0 )) || [ -z "$inv" ]; then
        # Each INVALID line of 21_validate_inventory.sql is followed by the
        # reason, indented.
        printf -v line '   %-19sit cannot be used as written:' Inventory
        write_out "$line" Red
        shown_lines=("${load_errors[@]}")
        for (( i = 0; i < ${#OUT[@]}; i++ )); do
            if [[ ${OUT[i]} =~ ^[[:space:]]+INVALID ]]; then
                trim t "${OUT[i]}"
                shown_lines+=("$t")
                if (( i + 1 < ${#OUT[@]} )); then trim t "${OUT[i + 1]}"; shown_lines+=("  $t"); fi
            elif [[ ${OUT[i]} =~ ORA-[0-9]{5} ]]; then
                trim t "${OUT[i]}"
                shown_lines+=("$t")
            fi
        done
        shopt -u nocasematch
        for line in "${shown_lines[@]:0:16}"; do write_out "     $line" Red; done
        exit_tool $EXIT_ERROR 'Correct the inventory (config/inventory_op_custom.csv for a site row). Nothing in OP was changed.'
    fi
    shopt -u nocasematch
    split_fields f "$inv" 0
    to_int INV_ITEMS "${f[1]}"; to_int INV_SHIPPED "${f[2]}"; to_int INV_SITE "${f[3]}"; to_int INV_HERE "${f[4]}"
    to_int INV_NOT_HERE "${f[5]}"
    local items shipped here nothere
    fmt_count items "$INV_ITEMS"; fmt_count shipped "$INV_SHIPPED"; fmt_count here "$INV_HERE"
    text="$items items ($shipped shipped, $INV_SITE of this site): $here in this database"
    if (( INV_NOT_HERE > 0 )); then
        write_kv Inventory "$text,"
        fmt_count nothere "$INV_NOT_HERE"
        write_out "                      $nothere not here (they are skipped)"
    else
        write_kv Inventory "$text"
    fi
    (( STOP_ASKED )) && exit_tool $EXIT_STOPPED 'Stopped before the run began. Nothing in OP was changed.'

    show_switches
    now
    D_KEY+=(READY); D_STATUS+=(DONE); D_SECONDS+=($((NOW - READY_STARTED)))

    # The run begins: its id, its folder, the monitor session.
    write_out ''
    if (( RUN_DRY )); then
        write_out ' Dry run: what a run would change. Nothing is changed.'
    else
        write_out " Run: anonymization of OP on $tns."
    fi
    local -a start_args=("$RUN_MODE")
    for key in "${SWITCH_KEYS[@]}"; do start_args+=("${SET[$key]}"); done
    start_args+=("${SET[PARALLEL_DEGREE]}" "${SET[FAIL_ON_MISSING_OBJECT]}" "${SET[APPROVE_STRUCTURE_ONLY_ACCOUNTS]}")
    script_line cmd "$RUN_SQL_DIR/start.sql" "${start_args[@]}"
    invoke_worker "$cmd"
    script_result "${OUT[@]}"
    line=''
    for t in "${OUT[@]}"; do
        if [[ $t == 'ANON_RUN|'* ]]; then line=$t; break; fi
    done
    if [ "$RESULT_STATUS" != OK ] || [ -z "$line" ]; then
        exit_tool $EXIT_ERROR "The run could not be opened: $RESULT_MESSAGE Nothing in OP was changed."
    fi
    split_fields f "$line" 0
    to_int RUN_ID "${f[1]}"
    new_run_folder
    write_run_file inventory.sql "${INV_SQL[@]}"
    run_label label "$RUN_ID"
    format_folder shown "$RUN_FOLDER"
    write_out " Run $label   $shown"

    session_open OP monitor
    if (( S_OK[SESSION] )); then
        MONITOR=$SESSION
    else
        RUN_LIVE=0
        write_out " The live view is not available (${S_ERROR[SESSION]}): the steps are shown as they end." Yellow
    fi

    RUN_STATUS=FAILED
    VERIFY_CODE=''
    VERIFY_LINES=()
    invoke_run_steps
    if [ "$RUN_STATUS" = COMPLETED ] && (( ! RUN_DRY )); then invoke_verification; fi

    # The figures of the run, read from what it recorded: in the monitor
    # session, or in a session of their own when the monitor is not there.
    script_line cmd "$RUN_SQL_DIR/results.sql" "$RUN_ID"
    if (( MONITOR >= 0 )) && (( ! S_ENDED[MONITOR] )); then
        if session_command "$MONITOR" 900 '' "$cmd"; then
            results=("${OUT[@]}")
        else
            write_out " The figures of the run could not be read: $OUT_ERROR" Yellow
        fi
    else
        sql_script OP results '' "$cmd"
        results=("${OUT[@]}")
    fi
    session_close "$MONITOR"
    session_close "$WORKER"

    local -a figures=()
    for line in "${results[@]}"; do [[ $line == ANON_R_* ]] && figures+=("$line"); done
    write_run_file results.txt "${figures[@]}"
    cp "$RUN_REPORT" "$RUN_FOLDER/report.txt"
    (( ${#VERIFY_LINES[@]} > 0 )) && write_run_file verify.txt "${VERIFY_LINES[@]}"

    run_end "$RUN_STATUS" "$VERIFY_CODE"
    write_manifest "$RUN_STATUS" "$END_VERDICT" "$END_CODE"
    # The run is over: a Ctrl+C now would only cut its report short.
    trap '' INT TERM
    show_run_end "$RUN_STATUS"
    show_html_report
    format_folder shown "$RUN_FOLDER"
    text='report.txt'
    (( ${#VERIFY_LINES[@]} > 0 )) && text+=', verify.txt'
    write_out "  Files    $shown   ($text, console.log)" DarkGray
    write_out "  Exit code $END_CODE: $END_WORDS." "$END_COLOR"
    stop_children
    exit "$END_CODE"
}

# What the status line says while ANON_META is prepared and the engine is
# installed.
status_metadata() { local c; now; fmt_clock c $((NOW - STEP_STARTED)); show_status "   Metadata           ANON_META $c"; }
status_engine() { local c; now; fmt_clock c $((NOW - STEP_STARTED)); show_status "   Engine             installing $c"; }

# The steps of the run after it was opened: checks and plan, then the count
# of a dry run, or the confirmation, the translations and the work of a run.
# The status the run ended with, in RUN_STATUS.
invoke_run_steps() {
    local cmd word count a b c
    local -a lines
    if (( RUN_DRY )); then
        start_flow 'CHECK|Checking and planning (read-only)|0' 'COUNT|Counting what a run would change|1'
    else
        start_flow 'CHECK|Checking and planning (read-only)|0' 'RECORD|Recording the translations|0' \
                   'APPLY|Anonymizing|1' 'VERIFY|Verifying (read-only)|0'
    fi

    # 1. Checks and plan.
    start_flow_step CHECK
    script_line cmd "$RUN_SQL_DIR/plan.sql"
    invoke_worker "$cmd"
    lines=("${OUT[@]}")
    update_live_view
    script_result "${lines[@]}"
    read_check_lines "${lines[@]}"
    read_plan_lines "${lines[@]}"
    if [ "$RESULT_STATUS" = FAILED ]; then
        complete_flow_step FAILED
        write_flow_error "$RESULT_MESSAGE"
        if (( S_ENDED[WORKER] )); then repair_run FAILED; return; fi
        RUN_STATUS=FAILED
        return
    fi
    complete_flow_step 'done'
    if (( PLAN_IDS )); then
        fmt_count a $((PLAN_PARTIES + PLAN_ACCOUNTS)); fmt_count b "$PLAN_PARTIES"; fmt_count c "$PLAN_ACCOUNTS"
        write_out "         $a identities: $b parties, $c bank accounts"
    fi
    show_checks "$RUN_DRY"
    if [ "$RESULT_STATUS" = REFUSED ]; then
        RUN_REFUSAL=$RESULT_MESSAGE
        RUN_STATUS=REFUSED
        return
    fi
    if (( STOP_ASKED )); then stop_run; return; fi

    if (( RUN_DRY )); then
        # 2. What a run would change.
        start_flow_step COUNT
        (( STOP_KEYS )) && write_flow_note 'Ctrl+C stops the count after the table or column it works on.' DarkGray
        RUN_WORKING=1
        script_line cmd "$RUN_SQL_DIR/count.sql"
        invoke_worker "$cmd"
        lines=("${OUT[@]}")
        RUN_WORKING=0
        update_live_view
        script_result "${lines[@]}"
        complete_kinds "$RESULT_STATUS"
        step_word word "$RESULT_STATUS"
        complete_flow_step "$word"
        [ "$RESULT_STATUS" = FAILED ] && write_flow_error "$RESULT_MESSAGE"
        if (( S_ENDED[WORKER] )) && [ "$RESULT_STATUS" = FAILED ]; then repair_run FAILED; return; fi
        RUN_STATUS=$RESULT_STATUS
        return
    fi

    # The confirmation: after the checks, with what the run will do.
    show_ready_banner
    if (( ! CLI_FORCE )); then
        if ! read_prompt 'Type YES to start' || { trim word "$ANSWER"; [ "${word^^}" != YES ]; }; then
            write_log " > Type YES to start: $ANSWER"
            script_line cmd "$RUN_SQL_DIR/finish.sql" CANCELLED
            invoke_worker "$cmd"
            RUN_STATUS=CANCELLED
            return
        fi
        write_log ' > Type YES to start: YES'
        write_out ''
    fi

    # 2. The translations, recorded before anything in OP changes.
    start_flow_step RECORD
    script_line cmd "$RUN_SQL_DIR/record.sql"
    invoke_worker "$cmd"
    lines=("${OUT[@]}")
    update_live_view
    script_result "${lines[@]}"
    if [ "$RESULT_STATUS" != OK ]; then
        step_word word "$RESULT_STATUS"
        complete_flow_step "$word"
        [ "$RESULT_STATUS" = FAILED ] && write_flow_error "$RESULT_MESSAGE"
        if (( S_ENDED[WORKER] )); then repair_run FAILED; return; fi
        RUN_STATUS=$RESULT_STATUS
        return
    fi
    complete_flow_step 'done'
    fmt_count count "$MAPPING_NEW"
    write_out "         $count new translations recorded"
    if (( STOP_ASKED )); then stop_run; return; fi

    # 3. The work.
    start_flow_step APPLY
    (( STOP_KEYS )) && write_flow_note 'Ctrl+C stops safely after the table or column it works on.' DarkGray
    RUN_WORKING=1
    script_line cmd "$RUN_SQL_DIR/apply.sql"
    invoke_worker "$cmd"
    lines=("${OUT[@]}")
    RUN_WORKING=0
    update_live_view
    script_result "${lines[@]}"
    complete_kinds "$RESULT_STATUS"
    if (( S_ENDED[WORKER] )) && [ "$RESULT_STATUS" = FAILED ]; then
        complete_flow_step FAILED
        repair_run FAILED
        return
    fi
    step_word word "$RESULT_STATUS"
    complete_flow_step "$word"
    [ "$RESULT_STATUS" = FAILED ] && write_flow_error "$RESULT_MESSAGE"
    RUN_STATUS=$RESULT_STATUS
}

# A stop asked for between two steps, before the work began: the run ends
# STOPPED, nothing in OP changed.
stop_run() {
    local cmd
    script_line cmd "$RUN_SQL_DIR/finish.sql" STOPPED
    invoke_worker "$cmd"
    RUN_STATUS=STOPPED
}

# The worker session was lost while the run was RUNNING (run/recover.sql in
# the monitor session): while the run's own database session is still there,
# its call goes on and ends the run by itself; otherwise the run is recorded
# FAILED and, when it had disabled the triggers of OP, they are enabled again.
# RUN_STATUS: $1.
repair_run() {   # STATUS
    local byhand="op/sql/run/recover.sql $RUN_ID" cmd line what re='^ANON_RECOVER[|]ENDED[|]([0-9]+)[|]([0-9]+)[|]'
    RUN_STATUS=$1
    if (( MONITOR < 0 || RUN_ID == 0 )) || (( S_ENDED[MONITOR] )); then
        write_out " The run could not be checked. Once it has ended, run $byhand as OP: it enables the triggers of OP again if needed." Red
        return
    fi
    script_line cmd "$RUN_SQL_DIR/recover.sql" "$RUN_ID"
    if ! session_command "$MONITOR" 300 '' "$cmd"; then
        write_out " The run could not be checked: $OUT_ERROR Once it has ended, run $byhand as OP." Red
        return
    fi
    for line in "${OUT[@]}"; do
        if [[ $line == 'ANON_RECOVER|ACTIVE|'* ]]; then
            write_wrapped '         ' 'The worker session was lost, but the run still works in the database: it ends by itself and enables the triggers of OP again. anon_meta.anon_run says when; then a new run resumes.' Yellow
        elif [[ $line =~ $re ]]; then
            what='the run is recorded as failed'
            (( BASH_REMATCH[2] > 0 )) && what+=", and ${BASH_REMATCH[2]} triggers of OP were enabled again"
            write_wrapped '         ' "The worker session was lost: $what." Yellow
        fi
    done
}

# 4. The verification of a completed run, in a session of its own, with its
# progress meanwhile: VERIFY_CODE, VERIFY_LINES.
invoke_verification() {
    local cmd line
    start_flow_step VERIFY
    RUN_VERIFYING=1
    script_line cmd "$VERIFY_SQL"
    sql_script OP verifier 'update_live_view VERIFY' "$cmd"
    VERIFY_CODE=$SCRIPT_EXIT
    VERIFY_LINES=("${OUT[@]}")
    RUN_VERIFYING=0
    update_live_view VERIFY
    case $VERIFY_CODE in
        0|2|3|4)
            complete_flow_step 'done' ;;
        *)
            complete_flow_step FAILED
            for line in "${VERIFY_LINES[@]}"; do
                if [[ $line =~ $RE_ORACLE_CODE ]]; then
                    trim line "$line"
                    write_flow_error "The verification could not run: $line"
                    break
                fi
            done ;;
    esac
}

# How the run ends: END_CODE, the verdict in a word (END_VERDICT), the code in
# words (END_WORDS) and its colour.
run_end() {   # STATUS VERIFY_CODE
    END_CODE=$EXIT_ERROR; END_VERDICT=$1; END_WORDS=failed; END_COLOR=Red
    case $1 in
        REFUSED)   END_VERDICT='NOT STARTED'; END_WORDS='not started, its checks refused it' ;;
        CANCELLED) END_VERDICT='NOT STARTED'; END_WORDS='not started, it was not confirmed' ;;
        STOPPED)   END_CODE=$EXIT_STOPPED; END_VERDICT=STOPPED; END_WORDS='stopped with Ctrl+C'; END_COLOR=Yellow ;;
        COMPLETED)
            if (( RUN_DRY )); then
                END_CODE=$EXIT_PASS; END_VERDICT='DRY RUN'; END_WORDS='the dry run completed'; END_COLOR=Green
            else
                case $2 in
                    0) END_CODE=$EXIT_PASS; END_VERDICT=PASS; END_WORDS='done, verified: PASS'; END_COLOR=Green ;;
                    2) END_CODE=$EXIT_VERIFY_FAIL; END_VERDICT=FAIL; END_WORDS='done, verification FAILED: client data is still present' ;;
                    3) END_CODE=$EXIT_REVIEW; END_VERDICT='REVIEW REQUIRED'; END_WORDS='done, review required'; END_COLOR=Yellow ;;
                    4) END_CODE=$EXIT_INCOMPLETE; END_VERDICT=INCOMPLETE; END_WORDS='done, incomplete: a protection was switched off'
                       END_COLOR=Yellow ;;
                    *) # Changed but not verified: not a pass until it is.
                       END_CODE=$EXIT_VERIFY_FAIL; END_VERDICT='NOT VERIFIED'; END_WORDS='done, but the verification could not run' ;;
                esac
            fi ;;
    esac
}

trap on_stop_signal INT TERM
trap '' HUP PIPE
trap on_exit EXIT
invoke_main "$@"
