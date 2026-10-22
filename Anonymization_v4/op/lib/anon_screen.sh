# ============================================================================
# OP Anonymization - The screen of a run
# ============================================================================
# Purpose : What a run shows: its steps by what they do, each with its time;
#           while the work runs, one live line for each kind of work (free
#           text, identifiers, labels and attributes) with its bar, what it
#           works on, the rows so far and the time left; the switches and the
#           checks as tables, and what a run will change before it is
#           confirmed. The end of the run comes from anon_end.awk and
#           report.html from anon_html.awk. The same screen as anon_screen.ps1
#           on Windows. --verbose adds every line of the engine; console.log
#           and report.txt always keep them.
# Usage   : Sourced by anon.sh, whose output functions it uses.
# Requires: bash 4.2 or later.
# ============================================================================

# The five categories of identity, and their names on the screen and in the
# report.
CATEGORIES=(ENTITY PORTFOLIO COUNTERPARTY UNCLASSIFIED_PARTY BANK_ACCOUNT)
declare -A CATEGORY_NAMES=(
    [ENTITY]='Entity (E_)' [PORTFOLIO]='Portfolio (P_)' [COUNTERPARTY]='Counterparty (T_)'
    [UNCLASSIFIED_PARTY]='Unclassified party (X_)' [BANK_ACCOUNT]='Bank account (CB_)'
)

# The three kinds of work, as the live lines show them, and what each has
# done so far (K_...: by kind; K_OBJ: the tables or columns worked on).
KINDS=(NULL_OUT CODE LABELS)
declare -A K_NAME=([NULL_OUT]='Free text' [CODE]='Identifiers' [LABELS]='Labels and attributes')
declare -A K_UNIT=([NULL_OUT]=tables [CODE]=columns [LABELS]=columns)
declare -A K_SEEN K_SHOWN K_DONE K_TOTAL K_ROWS K_X K_MS K_PPM K_OBJECTS K_OBJ

# What the last look at the run saw (poll.sql).
declare -A P_VERIFY

# ----------------------------------------------------------------------------
# Formats
# ----------------------------------------------------------------------------
# Each one sets the variable named first.

trim() {
    local _t=$2
    _t=${_t#"${_t%%[![:space:]]*}"}
    printf -v "$1" '%s' "${_t%"${_t##*[![:space:]]}"}"
}
rtrim() { printf -v "$1" '%s' "${2%"${2##*[![:space:]]}"}"; }

# The fields of a line separated by |, into the array named first: at most $3
# of them (0: all), the last one keeping the rest of the line.
split_fields() {   # ARRAY LINE MAX
    local _rest=$2 _max=${3:-0}
    local -a _f=()
    while [[ $_rest == *'|'* ]] && (( _max == 0 || ${#_f[@]} < _max - 1 )); do
        _f+=("${_rest%%|*}")
        _rest=${_rest#*|}
    done
    _f+=("$_rest")
    eval "$1=(\"\${_f[@]}\")"
}

# The items after the second, joined by the second: "a, b, c".
join_by() {   # VAR SEPARATOR ITEMS...
    local _var=$1 _sep=$2 _joined='' _n=0 _item
    shift 2
    for _item in "$@"; do
        (( _n++ )) && _joined+=$_sep
        _joined+=$_item
    done
    printf -v "$_var" '%s' "$_joined"
}

# A number printed by sqlplus, as a whole number; 0 when there is none.
to_int() {
    local _t=${2//,/} _n _re='^([-+]?)([0-9]*)([.][0-9]*)?$'
    _t=${_t//[[:space:]]/}
    if [[ $_t =~ $_re && -n ${BASH_REMATCH[2]}${BASH_REMATCH[3]} ]]; then
        _n=$((10#${BASH_REMATCH[2]:-0}))
        [ "${BASH_REMATCH[1]}" = - ] && _n=$((-_n))
        printf -v "$1" '%s' "$_n"
    else
        printf -v "$1" '%s' 0
    fi
}

# 19,279,194 for a count.
fmt_count() {
    local _n=$2 _sign='' _groups=''
    if [[ $_n == -* ]]; then _sign=-; _n=${_n#-}; fi
    while (( ${#_n} > 3 )); do
        _groups=,${_n: -3}$_groups
        _n=${_n:0:${#_n}-3}
    done
    printf -v "$1" '%s' "$_sign$_n$_groups"
}

# 0:05, 12:34, 1:02:03 - for seconds; fmt_clock_ms for milliseconds, rounded
# to the second half to even.
fmt_clock() {
    local _s=$2
    (( _s < 0 )) && _s=0
    if (( _s >= 3600 )); then
        printf -v "$1" '%d:%02d:%02d' $((_s / 3600)) $((_s % 3600 / 60)) $((_s % 60))
    else
        printf -v "$1" '%d:%02d' $((_s / 60)) $((_s % 60))
    fi
}
fmt_clock_ms() {
    local _q=$(($2 / 1000)) _r=$(($2 % 1000))
    if (( _r > 500 || (_r == 500 && _q % 2 == 1) )); then _q=$((_q + 1)); fi
    fmt_clock "$1" "$_q"
}

# "less than a minute", "about 8 minutes", "about 1 h 20 min".
fmt_about() {
    local _m=$(($2 / 60)) _r=$(($2 % 60))
    if (( $2 < 45 )); then printf -v "$1" '%s' 'less than a minute'; return; fi
    if (( _r > 30 || (_r == 30 && _m % 2 == 1) )); then _m=$((_m + 1)); fi
    (( _m < 1 )) && _m=1
    if (( _m >= 90 )); then
        printf -v "$1" 'about %d h %d min' $((_m / 60)) $((_m % 60))
    elif (( _m == 1 )); then
        printf -v "$1" '%s' 'about 1 minute'
    else
        printf -v "$1" 'about %d minutes' "$_m"
    fi
}

# "1 column", "3 columns".
fmt_plural() {
    local _count
    if (( $2 == 1 )); then printf -v "$1" '1 %s' "$3"; return; fi
    fmt_count _count "$2"
    printf -v "$1" '%s %s' "$_count" "${4:-${3}s}"
}

# [########............] for a part given in millionths.
get_bar() {
    local _p=$2 _full _done _left
    (( _p < 0 )) && _p=0
    (( _p > 1000000 )) && _p=1000000
    _full=$((20 * _p / 1000000))
    printf -v _done '%*s' "$_full" ''
    printf -v _left '%*s' $((20 - _full)) ''
    printf -v "$1" '[%s%s]' "${_done// /#}" "${_left// /.}"
}

# Columns a wrapped text may take: the terminal's, from 80 to 120; 100 when
# the output is not a terminal.
wrap_width() {
    local _w=100
    (( OUTPUT_IS_TTY )) && _w=$((TERM_COLUMNS - 1))
    (( _w < 80 )) && _w=80
    (( _w > 120 )) && _w=120
    printf -v "$1" '%s' "$_w"
}

# A text wrapped at the width of the screen: its first line after $1, the
# others under it (or indented by $4). Logged as it is shown.
write_wrapped() {
    local first=$1 text=$2 color=${3:-} indent=${4:--1} width pad line word
    local -a words=()
    wrap_width width
    if (( indent >= 0 )); then printf -v pad '%*s' "$indent" ''; else printf -v pad '%*s' "${#first}" ''; fi
    line=$first
    IFS=' ' read -r -a words <<< "$text"
    for word in "${words[@]}"; do
        if (( ${#line} + ${#word} > width )) && [[ $line == *[![:space:]]* ]] && (( ${#line} > ${#pad} )); then
            rtrim line "$line"
            write_out "$line" "$color"
            line=$pad
        fi
        line+="$word "
    done
    if [[ $line == *[![:space:]]* ]]; then
        rtrim line "$line"
        write_out "$line" "$color"
    fi
}

write_rule() {
    local line
    printf -v line '%79s' ''
    write_out " ${line// /=}" "${1:-White}"
}

# "   Database           OPDB: connected as SYS and as OP"
write_kv() {
    local line
    printf -v line '   %-19s%s' "$1" "$2"
    write_out "$line" "${3:-}"
}

# ----------------------------------------------------------------------------
# The run's state
# ----------------------------------------------------------------------------

new_run_state() {   # VERSION DRY TNS DATABASE
    RUN_VERSION=$1
    RUN_DRY=$2
    RUN_TNS=$3
    RUN_DATABASE=$4
    RUN_MODE=EXECUTE
    (( RUN_DRY )) && RUN_MODE=DRYRUN
    RUN_ID=0
    RUN_FOLDER=''
    WORKER=-1
    MONITOR=-1
    RUN_LIVE=1
    LAST_STEP=0
    RUN_WORKING=0
    RUN_VERIFYING=0
    RUN_REPORT=$TMP_DIR/report.txt
    : > "$RUN_REPORT"
    RUN_ERRORS=()
    RUN_REFUSAL=''
    MAPPING_NEW=0
    D_KEY=(); D_STATUS=(); D_SECONDS=()
    CHECK_LINES=()
    INV_ITEMS=0; INV_SHIPPED=0; INV_SITE=0; INV_HERE=0; INV_NOT_HERE=0
    FLOW_ON=0
}

# The checks of plan.sql (its ANON_CHECK lines): C_... from 0, and the lines
# themselves in CHECK_LINES.
read_check_lines() {   # LINES...
    local line
    local -a f
    C_CODE=(); C_NEEDED=(); C_STATUS=(); C_STATE=(); C_TITLE=(); C_MEASURE=(); C_HAPPENS=(); C_TODO=()
    CHECK_LINES=()
    for line in "$@"; do
        [[ $line == ANON_CHECK\|* ]] || continue
        split_fields f "$line" 10
        (( ${#f[@]} < 10 )) && continue
        CHECK_LINES+=("$line")
        C_CODE+=("${f[2]}"); C_NEEDED+=("${f[3]}"); C_STATUS+=("${f[4]}"); C_STATE+=("${f[5]}"); C_TITLE+=("${f[6]}")
        C_MEASURE+=("${f[7]}"); C_HAPPENS+=("${f[8]}"); C_TODO+=("${f[9]}")
    done
}

# What plan.sql says besides the checks: the identities (PLAN_IDS), the scope
# (PLAN_SCOPE), the estimate (PLAN_EST).
read_plan_lines() {   # LINES...
    local line
    local -a f
    PLAN_IDS=0; PLAN_SCOPE=0; PLAN_EST=0
    for line in "$@"; do
        split_fields f "$line" 0
        if [ "${f[0]}" = ANON_IDENTITIES ] && (( ${#f[@]} >= 5 )); then
            PLAN_IDS=1
            to_int PLAN_PARTIES "${f[1]}"; to_int PLAN_ACCOUNTS "${f[2]}"; to_int PLAN_KNOWN "${f[4]}"
        elif [ "${f[0]}" = ANON_SCOPE ] && (( ${#f[@]} >= 5 )); then
            PLAN_SCOPE=1
            to_int PLAN_CODE "${f[1]}"; to_int PLAN_FREE "${f[2]}"; to_int PLAN_LABELS "${f[3]}"; to_int PLAN_ATTRS "${f[4]}"
        elif [ "${f[0]}" = ANON_ESTIMATE ] && (( ${#f[@]} >= 4 )); then
            PLAN_EST=1
            to_int PLAN_EST_SECONDS "${f[1]}"
            PLAN_EST_DRYRUN=${f[3]}
        fi
    done
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

# Starts the steps of the run, given in order as KEY|Text|header - header 1
# for a step that is a heading over the live lines of its work. The three
# kinds of work each get a live line under the heading.
start_flow() {
    local s k
    F_KEY=(); F_TEXT=(); F_HEADER=()
    for s in "$@"; do
        F_KEY+=("${s%%|*}")
        s=${s#*|}
        F_TEXT+=("${s%|*}")
        F_HEADER+=("${s##*|}")
    done
    for k in "${KINDS[@]}"; do
        K_SEEN[$k]=0; K_SHOWN[$k]=0; K_DONE[$k]=0; K_TOTAL[$k]=0; K_ROWS[$k]=0; K_X[$k]=0; K_MS[$k]=0
        K_PPM[$k]=0; K_OBJECTS[$k]=0
    done
    K_OBJ=()
    FLOW_ON=1
    FLOW_N=0
    now
    FLOW_STARTED=$NOW
    FLOW_OPEN=0
    FLOW_STAGE=''
    FLOW_TRIGGERS_ON=''
    FLOW_NOTES=(); FLOW_NOTE_COLORS=()
}

flow_index() {   # VAR KEY
    local _i
    for (( _i = 0; _i < ${#F_KEY[@]}; _i++ )); do
        if [ "${F_KEY[_i]}" = "$2" ]; then printf -v "$1" '%s' $((_i + 1)); return; fi
    done
    printf -v "$1" '%s' 0
}

# " 1 of 2  Checking and planning (read-only)                       done    0:41"
flow_line() {   # VAR STATE TIME [N]
    local _n=${4:-$FLOW_N} _t
    printf -v _t ' %s of %s  %s' "$_n" "${#F_KEY[@]}" "${F_TEXT[_n - 1]}"
    printf -v _t '%-66s %-7s%5s' "$_t" "$2" "$3"
    rtrim "$1" "$_t"
}

# Starts the step $1, ending the one that runs.
start_flow_step() {
    local n line
    flow_index n "$1"
    (( n == 0 )) && return
    (( FLOW_OPEN )) && complete_flow_step
    FLOW_N=$n
    now
    FLOW_STARTED=$NOW
    FLOW_OPEN=1
    FLOW_STAGE=''
    write_log ''
    if (( F_HEADER[n - 1] )); then
        write_out ''
        flow_line line '' ''
        write_out "$line" White
    else
        flow_line line running 0:00
        show_status "$line"
    fi
}

# Ends the running step with its time: done, FAILED, stopped... A heading
# gets a line only when it did not end well. The step's duration goes to the
# report.
complete_flow_step() {
    local state=${1:-'done'} seconds color clock line i
    (( FLOW_ON && FLOW_OPEN )) || return 0
    FLOW_OPEN=0
    now
    seconds=$((NOW - FLOW_STARTED))
    D_KEY+=("${F_KEY[FLOW_N - 1]}"); D_STATUS+=("${state^^}"); D_SECONDS+=("$seconds")
    color=Green
    if [ "$state" = FAILED ]; then color=Red; elif [ "$state" != 'done' ]; then color=Yellow; fi
    fmt_clock clock "$seconds"
    if (( F_HEADER[FLOW_N - 1] )); then
        clear_status
        [ "$state" != 'done' ] && write_out "         $state after $clock" "$color"
    else
        flow_line line "$state" "$clock"
        write_out "$line" "$color"
    fi
    for (( i = 0; i < ${#FLOW_NOTES[@]}; i++ )); do write_wrapped '         ' "${FLOW_NOTES[i]}" "${FLOW_NOTE_COLORS[i]}"; done
    FLOW_NOTES=(); FLOW_NOTE_COLORS=()
}

# A line under the running step: written when a step ends, at once under a
# heading.
write_flow_note() {   # TEXT [COLOR]
    if (( FLOW_OPEN )) && (( ! F_HEADER[FLOW_N - 1] )); then
        FLOW_NOTES+=("$1"); FLOW_NOTE_COLORS+=("${2:-}")
        return
    fi
    write_wrapped '         ' "$1" "${2:-}"
}

write_flow_error() {   # MESSAGE
    [ -z "$1" ] && return
    RUN_ERRORS+=("$1")
    write_wrapped '         ' "$1" Red
}

# The word a step ends with, for the status a script returned.
step_word() {   # VAR STATUS
    case $2 in
        OK|COMPLETED) printf -v "$1" '%s' 'done' ;;
        STOPPED)      printf -v "$1" '%s' stopped ;;
        *)            printf -v "$1" '%s' FAILED ;;
    esac
}

# The kind of work a phase of the engine belongs to: NULL_OUT, CODE, LABELS.
kind_key() {   # VAR PHASE
    case $2 in
        NULL_OUT)                     printf -v "$1" '%s' NULL_OUT ;;
        CODE)                         printf -v "$1" '%s' CODE ;;
        LABELS|DESCRIPTION|SELF_CODE) printf -v "$1" '%s' LABELS ;;
        *)                            printf -v "$1" '%s' '' ;;
    esac
}

# One row the engine logged (anon_step_log), as the monitor read it: added up
# under its kind of work; with --verbose shown as it comes; the triggers of OP
# said when they are disabled and enabled again.
add_flow_step() {   # ID PHASE STATUS ROWS X MS RULE OBJECT MESSAGE
    local phase=$2 status=$3 rows=$4 x=$5 ms=$6 object=$8 message=$9 key text count o
    if [ "$phase" = MAPPING ] && [ "$status" = OK ]; then MAPPING_NEW=$((MAPPING_NEW + rows)); fi
    if (( VERBOSE )); then
        count=''
        if (( rows != 0 )) || [ "$status" = OK ] || [ "$status" = DRYRUN ]; then fmt_count count "$rows"; fi
        printf -v text '   %-11s%-9s%12s  %s' "$phase" "$status" "$count" "$object"
        write_out "$text" DarkGray nolog
    fi
    [ "$status" = ERROR ] && RUN_ERRORS+=("$object: $message")
    (( FLOW_ON )) || return 0
    if [ "$phase" = TRIGGERS ]; then
        # Enabled again at the end of the work, whether it completed or not:
        # said after the lines of the work, which complete_kinds closes with
        # how it ended.
        if [ "$object" = ENABLE ]; then
            FLOW_TRIGGERS_ON=$rows
            return 0
        fi
        clear_status
        if (( rows == 0 )); then
            write_out '         triggers of OP: none'
        else
            fmt_count count "$rows"
            write_out "         triggers of OP: $count disabled until the end of the run"
        fi
        return 0
    fi
    kind_key key "$phase"
    [ -z "$key" ] && return 0
    # A kind that logs a row has begun: the kinds before it have ended.
    show_ended_kinds "$key"
    K_SEEN[$key]=1
    if [ "$status" = OK ] || [ "$status" = DRYRUN ]; then
        K_ROWS[$key]=$((K_ROWS[$key] + rows))
        K_X[$key]=$((K_X[$key] + x))
    fi
    K_MS[$key]=$((K_MS[$key] + ms))
    if [ "$status" != SKIPPED ] && [ "$status" != DISABLED ]; then
        step_objects "$phase" "$object"
        for o in "${STEP_OBJECTS[@]}"; do
            if [ -z "${K_OBJ["$key/${o,,}"]:-}" ]; then
                K_OBJ["$key/${o,,}"]=1
                K_OBJECTS[$key]=$((K_OBJECTS[$key] + 1))
            fi
        done
    fi
}

# What one logged row worked on (STEP_OBJECTS), as its kind counts it: the
# table of a free-text statement, the column of an identifier step, the
# columns of a label or attribute statement ("tiers.[description,fax] [party
# nodes]").
step_objects() {   # PHASE OBJECT
    local object=$2 table col re='^([^.]+)[.][[]([^]]*)[]]'
    local -a cols
    STEP_OBJECTS=()
    if [ "$1" = NULL_OUT ]; then STEP_OBJECTS=("${object%%.*}"); return; fi
    if [ "$1" = CODE ]; then STEP_OBJECTS=("${object%% *}"); return; fi
    if [[ $object =~ $re ]]; then
        table=${BASH_REMATCH[1]}
        IFS=, read -r -a cols <<< "${BASH_REMATCH[2]}"
        for col in "${cols[@]}"; do
            [[ ${col,,} == *'(masked)' ]] && col=${col:0:${#col}-8}
            trim col "$col"
            STEP_OBJECTS+=("$table.$col")
        done
        return
    fi
    STEP_OBJECTS=("${object%% *}")
}

# The done line of every kind before $1 that has begun and is not shown.
show_ended_kinds() {
    local k
    for k in "${KINDS[@]}"; do
        [ "$k" = "$1" ] && return
        if (( K_SEEN[$k] && ! K_SHOWN[$k] )); then show_kind_line "$k" 'done'; fi
    done
}

# The final line of a kind of work: done, with its rows and time; or how far
# it got when the run stopped or failed during it.
show_kind_line() {   # KIND STATE
    local k=$1 state=$2 count head bar line items rows clock reached color of
    K_SHOWN[$k]=1
    clear_status
    count=${K_TOTAL[$k]}
    (( count == 0 )) && count=${K_OBJECTS[$k]}
    printf -v head '         %-23s' "${K_NAME[$k]}"
    if [ "$state" = 'done' ]; then
        get_bar bar 1000000
        fmt_count items "$count"
        fmt_count rows "${K_ROWS[$k]}"
        fmt_clock_ms clock "${K_MS[$k]}"
        printf -v line '%s%s 100%%   %-13s%17s%7s' "$head" "$bar" "$items ${K_UNIT[$k]}" "$rows rows" "$clock"
        write_out "$line"
        return
    fi
    color=Yellow
    [ "$state" = FAILED ] && color=Red
    # Done: what the last look saw, or the tables and columns logged since,
    # whichever is more.
    reached=${K_DONE[$k]}
    (( K_OBJECTS[$k] > reached )) && reached=${K_OBJECTS[$k]}
    get_bar bar "${K_PPM[$k]}"
    fmt_count items "$reached"
    fmt_count of "$count"
    fmt_count rows "${K_ROWS[$k]}"
    printf -v line '%s%s %3d%%   %s after %s of %s %s . %s rows' "$head" "$bar" $((K_PPM[$k] / 10000)) "$state" "$items" "$of" \
           "${K_UNIT[$k]}" "$rows"
    write_out "$line" "$color"
}

# At the end of the work: the line of every kind not shown yet - done; the
# one the run was in when it stopped or failed, with how far it got; the ones
# it never reached, "not run". Then the triggers of OP, enabled again.
complete_kinds() {   # STATUS
    local ended=0 last='' k word line count
    (( FLOW_ON )) || return 0
    if [ "$1" = COMPLETED ] || [ "$1" = OK ]; then ended=1; fi
    for k in "${KINDS[@]}"; do (( K_SEEN[$k] )) && last=$k; done
    for k in "${KINDS[@]}"; do
        (( K_SHOWN[$k] )) && continue
        if (( ! K_SEEN[$k] )); then
            if (( ! ended )); then
                K_SHOWN[$k]=1
                printf -v line '         %-23snot run' "${K_NAME[$k]}"
                write_out "$line" DarkGray
            fi
            continue
        fi
        if [ "$k" = "$last" ] && (( ! ended )); then
            step_word word "$1"
            show_kind_line "$k" "$word"
        else
            show_kind_line "$k" 'done'
        fi
    done
    if [ -n "$FLOW_TRIGGERS_ON" ]; then
        if (( FLOW_TRIGGERS_ON > 0 )); then
            fmt_count count "$FLOW_TRIGGERS_ON"
            write_out "         triggers of OP: $count enabled again"
        fi
        FLOW_TRIGGERS_ON=''
    fi
}

# What the engine does now, in words, for the line of a running step.
stage_words() {   # VAR poll|none
    local _k _text='' _count
    if [ "$2" != poll ]; then printf -v "$1" '%s' "$FLOW_STAGE"; return; fi
    if [ "${F_KEY[FLOW_N - 1]}" = VERIFY ]; then
        local -A _names=([IDENTITY]='identities' [RESIDUAL]='identifier columns' [FREETEXT]='free text'
                         [LABELS]='labels and attributes' [MAPPING]='mapping integrity' [SETTINGS]='switches'
                         [PREFIX]='prefixes')
        for _k in IDENTITY RESIDUAL FREETEXT LABELS MAPPING SETTINGS PREFIX; do
            if [ -n "${P_VERIFY[$_k]:-}" ]; then
                fmt_count _count "${P_VERIFY[$_k]}"
                _text="${_names[$_k]} ($_count checked)"
            fi
        done
        [ -n "$_text" ] && FLOW_STAGE=$_text
        printf -v "$1" '%s' "$FLOW_STAGE"
        return
    fi
    if (( P_HAS_PROGRESS )) && [ -n "$P_STAGE" ]; then FLOW_STAGE=$P_STAGE; fi
    printf -v "$1" '%s' "$FLOW_STAGE"
}

# The status line of the run, after each look at it: the running step with
# its clock and what the engine does, or under a heading the live line of
# the kind of work in progress. Without a terminal it is written as a line
# once a minute.
show_flow_status() {   # poll|none
    local text='' key longpct ppm part bar reached total count clock words left
    (( FLOW_ON && FLOW_OPEN )) || return 0
    if (( F_HEADER[FLOW_N - 1] )); then
        [ "$1" = poll ] && (( P_HAS_PROGRESS )) || return 0
        kind_key key "$P_PHASE"
        [ -z "$key" ] && return 0
        show_ended_kinds "$key"
        K_SEEN[$key]=1
        K_TOTAL[$key]=$P_TOTAL
        K_DONE[$key]=$P_DONE
        longpct=-1
        if (( P_HAS_LONGOP )); then
            longpct=$P_PCT
            (( longpct > 100 )) && longpct=100
            (( longpct < 0 )) && longpct=0
        fi
        # The part done, in millionths: weighed by the rows of the tables,
        # with the long statement under way counted for its part.
        ppm=0
        if (( P_WTOTAL > 0 )); then
            part=0
            (( longpct >= 0 )) && part=$((P_WEIGHT * longpct))
            ppm=$(( (P_WDONE * 100 + part) * 10000 / P_WTOTAL ))
        elif (( P_TOTAL > 0 )); then
            ppm=$((P_DONE * 1000000 / P_TOTAL))
        fi
        (( ppm < 0 )) && ppm=0
        (( ppm > 1000000 )) && ppm=1000000
        K_PPM[$key]=$ppm
        get_bar bar "$ppm"
        fmt_count reached "$P_DONE"
        fmt_count total "$P_TOTAL"
        printf -v text '         %-23s%s %3d%%   %s of %s %s' "${K_NAME[$key]}" "$bar" $((ppm / 10000)) "$reached" "$total" "${K_UNIT[$key]}"
        if [ -n "$P_OBJECT" ]; then
            text+=" . $P_OBJECT"
            (( longpct >= 0 )) && text+=" $longpct%"
        fi
        if (( K_ROWS[$key] > 0 )); then
            fmt_count count "${K_ROWS[$key]}"
            text+=" . $count rows"
        fi
        if (( ppm >= 30000 && P_INPHASE >= 15 )); then
            left=$(( (2 * P_INPHASE * (1000000 - ppm) + ppm) / (2 * ppm) ))
            fmt_clock clock "$left"
            text+=" . $clock left"
        fi
    else
        stage_words words "$1"
        now
        fmt_clock clock $((NOW - FLOW_STARTED))
        flow_line text running "$clock"
        [ -n "$words" ] && text+=" . $words"
    fi
    if (( STATUS_LINE )); then
        show_status "$text"
    else
        now
        (( NOW - LAST_CONSOLE >= 60 )) && write_out "$text" DarkGray nolog
    fi
}

# ----------------------------------------------------------------------------
# Getting ready: the switches
# ----------------------------------------------------------------------------

# What is anonymized, as one table, and whether it is everything.
show_switches() {
    local c id desc attr color line name list=''
    local -a off=()
    local -A word=([y]=yes [n]=no)
    write_out ''
    write_out '   What is anonymized (config/anonymization.ini)'
    printf -v line '   %-26s%-15s%-9s%s' Category 'Rename codes' Labels Attributes
    write_out "$line"
    for c in "${CATEGORIES[@]}"; do
        id=${SET[ANONYMIZE_$c]}
        desc=${SET[ANONYMIZE_${c}_DESCRIPTION]}
        attr=${SET[ANONYMIZE_${c}_ATTRIBUTES]}
        name=${CATEGORY_NAMES[$c]% (*}
        name=${name,,}
        [ "$id" = n ] && off+=("$name codes")
        [ "$desc" = n ] && off+=("$name labels")
        [ "$attr" = n ] && off+=("$name attributes")
        color=''
        [[ $id == n || $desc == n || $attr == n ]] && color=Yellow
        printf -v line '   %-26s%-15s%-9s%s' "${CATEGORY_NAMES[$c]}" "${word[$id]}" "${word[$desc]}" "${word[$attr]}"
        write_out "$line" "$color"
    done
    printf -v line '   %-26s%s' 'Free text' 'always emptied'
    write_out "$line"
    if (( ${#off[@]} == 0 )); then
        write_out '   Every switch is on: a full anonymization.'
    else
        join_by list ', ' "${off[@]}"
        write_wrapped '   ' "Switched off: $list. Their client data stays, and the verification can be no better than INCOMPLETE." Yellow
    fi
}

# ----------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------

# The checks as a table: each with whether it is needed, its state now and
# what was measured; for each one not met, what happens and what to do.
show_checks() {   # DRY
    local i needed state color line list
    local -a unmet=()
    (( ${#C_CODE[@]} == 0 )) && return
    write_out ''
    printf -v line '   %-38s%-11s%s' Check Needed Now
    write_out "$line" White
    for (( i = 0; i < ${#C_CODE[@]}; i++ )); do
        needed=${C_NEEDED[i],,}
        state=${C_STATE[i]}
        color=''
        if [ "${C_STATUS[i]}" = NOT_MET ]; then
            state='NOT MET'
            if [ "${C_NEEDED[i]}" = REQUIRED ]; then color=Red; unmet+=("${C_TITLE[i]}"); else color=Yellow; fi
        elif [ -z "$state" ]; then
            state=ok
        fi
        printf -v line '   %-38s%-11s%s' "${C_TITLE[i]}" "$needed" "$state"
        write_out "$line" "$color"
        [ -n "${C_MEASURE[i]}" ] && write_wrapped '       ' "${C_MEASURE[i]}" DarkGray
        if [ "${C_STATUS[i]}" = NOT_MET ]; then
            [ -n "${C_HAPPENS[i]}" ] && write_wrapped '       What happens: ' "${C_HAPPENS[i]}" "$color"
            [ -n "${C_TODO[i]}" ] && write_wrapped '       What to do:   ' "${C_TODO[i]}"
        fi
    done
    write_out ''
    if (( ${#unmet[@]} > 0 )); then
        join_by list ', ' "${unmet[@]}"
        write_wrapped '   ' "Required and not met: $list. The run cannot start." Red
    elif (( $1 )); then
        write_out '   Every required check is met: a run can go ahead as things are.'
    else
        write_out '   Every required check is met: the run can go ahead as things are.'
    fi
}

# Before the question to start: what the run will change, and that it cannot
# be undone.
show_ready_banner() {
    local ids before='' text count n key time=''
    write_out ''
    write_rule
    write_out "  Ready. This replaces the client data of OP on $RUN_TNS:" White
    if (( PLAN_IDS && PLAN_SCOPE )); then
        ids=$((PLAN_PARTIES + PLAN_ACCOUNTS))
        if (( PLAN_KNOWN > 0 )); then
            fmt_count count "$PLAN_KNOWN"
            before=" ($count of them translated by an earlier run, with the same value)"
        fi
        fmt_plural text "$ids" identity identities
        fmt_plural count "$PLAN_CODE" 'identifier column'
        write_wrapped '  - ' "$text get their E_, P_, T_, X_ or CB_ value, in $count; their labels and attributes are masked with it$before" White
        fmt_plural text "$PLAN_FREE" 'free-text column'
        fmt_plural count $((PLAN_LABELS + PLAN_ATTRS)) 'label and attribute column'
        write_wrapped '  - ' "$text emptied, $count masked" White
    fi
    n=0
    for key in "${SWITCH_KEYS[@]}"; do [ "${SET[$key]}" = n ] && n=$((n + 1)); done
    if (( n > 0 )); then
        fmt_plural text "$n" switch switches
        write_wrapped '  - ' "$text off: their client data stays, and the result is INCOMPLETE" Yellow
    fi
    if (( PLAN_EST && PLAN_EST_SECONDS > 0 )); then
        fmt_about time "$PLAN_EST_SECONDS"
        time="${time^}, from the dry run $PLAN_EST_DRYRUN. "
    fi
    write_wrapped '  ' "${time}It cannot be undone: run it on a restored copy only." White
    write_rule
}

# ----------------------------------------------------------------------------
# The end of a run
# ----------------------------------------------------------------------------

# The end of the run on the screen (anon_end.awk), from its results.txt and
# its state; each line written as write_out writes it.
show_run_end() {   # STATUS
    local state=$TMP_DIR/end_state.txt width line color text i e
    wrap_width width
    {
        printf 'STATUS|%s\nDRY|%s\nTNS|%s\nLAUNCHER|%s\nWIDTH|%s\nVERDICT|%s\nCOLOR|%s\n' \
               "$1" "$RUN_DRY" "$RUN_TNS" "$LAUNCHER" "$width" "$END_VERDICT" "$END_COLOR"
        for (( i = 0; i < ${#D_KEY[@]}; i++ )); do printf 'DURATION|%s|%s|%s\n' "${D_KEY[i]}" "${D_STATUS[i]}" "${D_SECONDS[i]}"; done
        for e in "${RUN_ERRORS[@]}"; do printf 'ERROR|%s\n' "${e//$'\n'/ }"; done
        [ -n "$RUN_REFUSAL" ] && printf 'REFUSAL|%s\n' "${RUN_REFUSAL//$'\n'/ }"
        for line in "${CHECK_LINES[@]}"; do printf '%s\n' "$line"; done
    } > "$state"
    while IFS= read -r line; do
        color=${line%%$'\t'*}
        text=${line#*$'\t'}
        write_out "$text" "$color"
    done < <(ANON_RESULTS="$RUN_FOLDER/results.txt" ANON_STATE="$state" awk -f "$LIB_DIR/anon_results.awk" -f "$LIB_DIR/anon_end.awk")
}

# The report in the browser: written in the run folder, said where it is, and
# opened when somebody is at a desktop (unless --no-open). A report that
# cannot be written or opened never fails the run.
show_html_report() {
    local path=$RUN_FOLDER/report.html opened='' shown
    if ! ANON_FOLDER="$RUN_FOLDER" awk -f "$LIB_DIR/anon_results.awk" -f "$LIB_DIR/anon_html.awk" 2> "$TMP_DIR/report.err"; then
        write_log " report.html was not written: $(head -n 1 "$TMP_DIR/report.err" 2>/dev/null)"
        return
    fi
    if (( ! CLI_NO_OPEN && CONSOLE_OK )) && [ -t 0 ] && [ -t 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] &&
       type -P xdg-open > /dev/null 2>&1; then
        ( xdg-open "$path" > /dev/null 2>&1 & ) && opened='  (opened in your browser)'
    fi
    format_folder shown "$path"
    write_out "  Report   $shown$opened"
}
