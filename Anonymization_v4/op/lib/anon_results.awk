# ============================================================================
# OP Anonymization - The figures of a run
# ============================================================================
# Purpose : For run_op_anonymization.sh: the lines of run/results.sql (the
#           results.txt of a run folder) read into arrays, and the figures
#           that the end of a run (anon_end.awk) and report.html
#           (anon_html.awk) show - by kind of work, what was left for review,
#           what is not in this database, the verification by part, what to
#           know - with the formats both use. The same rules as
#           anon_screen.ps1 on Windows: a run reads the same on both.
# Usage   : The first of two programs, never run alone:
#             awk -f anon_results.awk -f anon_end.awk
#             awk -f anon_results.awk -f anon_html.awk
# Requires: a POSIX awk (gawk, mawk, busybox awk), run with LC_ALL=C.
# ============================================================================

BEGIN {
    # The five categories of identity, and their names on the screen and in
    # the report.
    split("ENTITY PORTFOLIO COUNTERPARTY UNCLASSIFIED_PARTY BANK_ACCOUNT", CATEGORIES, " ")
    CATEGORY_NAME["ENTITY"] = "Entity (E_)"
    CATEGORY_NAME["PORTFOLIO"] = "Portfolio (P_)"
    CATEGORY_NAME["COUNTERPARTY"] = "Counterparty (T_)"
    CATEGORY_NAME["UNCLASSIFIED_PARTY"] = "Unclassified party (X_)"
    CATEGORY_NAME["BANK_ACCOUNT"] = "Bank account (CB_)"
}

# ----------------------------------------------------------------------------
# Formats
# ----------------------------------------------------------------------------

function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }

function rep(c, n,   s) { s = ""; while (n-- > 0) s = s c; return s }
function pad_right(s, n) { return (length(s) >= n) ? s : s rep(" ", n - length(s)) }
function pad_left(s, n) { return (length(s) >= n) ? s : rep(" ", n - length(s)) s }
function capitalize(s) { return toupper(substr(s, 1, 1)) substr(s, 2) }

# A number printed by sqlplus; 0 when there is none.
function to_number(s) {
    gsub(/,/, "", s)
    s = trim(s)
    if (s ~ /^[-+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$/) return s + 0
    return 0
}

# A number rounded to a whole one, half to even as .NET rounds.
function round_even(v,   s) { s = sprintf("%.0f", v); return (s == "-0") ? 0 : s + 0 }

# 19,279,194 for a count.
function fmt_count(v,   s, neg, groups) {
    s = sprintf("%.0f", v)
    if (s == "-0") s = "0"
    neg = (substr(s, 1, 1) == "-")
    if (neg) s = substr(s, 2)
    groups = ""
    while (length(s) > 3) {
        groups = "," substr(s, length(s) - 2) groups
        s = substr(s, 1, length(s) - 3)
    }
    return (neg ? "-" : "") s groups
}

# 0:05, 12:34, 1:02:03.
function fmt_clock(sec,   s) {
    s = round_even(sec)
    if (s < 0) s = 0
    if (s >= 3600) return sprintf("%d:%02d:%02d", int(s / 3600), int((s % 3600) / 60), s % 60)
    return sprintf("%d:%02d", int(s / 60), s % 60)
}

# "less than a minute", "about 8 minutes", "about 1 h 20 min".
function fmt_about(sec,   m) {
    if (sec < 45) return "less than a minute"
    m = round_even(sec / 60)
    if (m < 1) m = 1
    if (m >= 90) return "about " int(m / 60) " h " (m % 60) " min"
    if (m == 1) return "about 1 minute"
    return "about " m " minutes"
}

# "1 column", "3 columns".
function fmt_plural(n, one, many) {
    if (many == "") many = one "s"
    if (n == 1) return "1 " one
    return fmt_count(n) " " many
}

function get_bar(pct, width,   full) {
    if (width == "") width = 20
    if (pct < 0) pct = 0
    if (pct > 100) pct = 100
    full = int(width * pct / 100)
    return "[" rep("#", full) rep(".", width - full) "]"
}

# A number with one decimal, as .NET writes it with "0.0": its first 15
# significant digits, rounded half away from zero. For 0 <= v < 10^15.
function fmt_fixed1(v,   s, digits, e, keep, n) {
    if (v <= 0) return "0.0"
    s = sprintf("%.14e", v)
    digits = substr(s, 1, 1) substr(s, 3, 14)
    e = substr(s, index(s, "e") + 1) + 0
    # The digits up to the first decimal, as a whole number of tenths.
    keep = e + 2
    if (keep <= 0) {
        n = (keep == 0 && substr(digits, 1, 1) >= "5") ? 1 : 0
    } else if (keep >= 15) {
        n = digits * (10 ^ (keep - 15))
    } else {
        n = substr(digits, 1, keep) + 0
        if (substr(digits, keep + 1, 1) >= "5") n++
    }
    return int(n / 10) "." (n % 10)
}

# ----------------------------------------------------------------------------
# Lines
# ----------------------------------------------------------------------------

# The fields of a line separated by |, from f[0]: at most max of them (0: all),
# the last one keeping the rest of the line. Returns how many there are.
function split_fields(line, f, max,   n, p) {
    split("", f)
    n = 0
    while ((max == 0 || n < max - 1) && (p = index(line, "|")) > 0) {
        f[n++] = substr(line, 1, p - 1)
        line = substr(line, p + 1)
    }
    f[n++] = line
    return n
}

# A check of plan.sql (ANON_CHECK) or results.sql (ANON_R_CHECK), added to
# the CHK_ arrays.
function add_check(line,   f) {
    if (line !~ /^ANON_(R_)?CHECK[|]/) return
    if (split_fields(line, f, 10) < 10) return
    CHK_N++
    CHK_SEQ[CHK_N] = round_even(to_number(f[1])); CHK_CODE[CHK_N] = f[2]; CHK_NEEDED[CHK_N] = f[3]
    CHK_STATUS[CHK_N] = f[4]; CHK_STATE[CHK_N] = f[5]; CHK_TITLE[CHK_N] = f[6]; CHK_MEASURE[CHK_N] = f[7]
    CHK_HAPPENS[CHK_N] = f[8]; CHK_TODO[CHK_N] = f[9]
}

# ----------------------------------------------------------------------------
# Results
# ----------------------------------------------------------------------------

# The lines of results.sql, read from a file into the arrays below. A file
# that is missing reads as no results.
#   RUN_*          the run, when there is an ANON_R_RUN line (RUN_SET)
#   SET_*          the switches by category          CHK_*  the checks
#   ID_*           the identities by category        ACC_*  the bank accounts
#   IDN_*          notes on the identities           X_*    unclassified
#   XT_*           where X_ values went, by table    H_*    harvested codes
#   IT_*           the inventory items               ST_*   the logged steps
#   EST_*          the estimate                      TRIGGERS
#   V_*            the verification
function read_results(file,   line, tag, p, f, n, i, j, t) {
    CHK_N = 0; SET_N = 0; ID_N = 0; X_N = 0; XT_N = 0; H_N = 0; IT_N = 0; ST_N = 0; V_N = 0
    RUN_SET = 0; ACC_SET = 0; IDN_SET = 0; EST_SET = 0; TRIGGERS = 0
    if (file == "") return
    while ((getline line < file) > 0) {
        sub(/\r$/, "", line)
        if (substr(line, 1, 7) != "ANON_R_") continue
        p = index(line, "|")
        tag = (p > 0) ? substr(line, 1, p - 1) : ""
        add_check(line)
        if (tag == "ANON_R_RUN") {
            n = split_fields(line, f, 10)
            RUN_SET = 1
            RUN_ID = round_even(to_number(f[1])); RUN_MODE = f[2]; RUN_STATUS = f[3]; RUN_STARTED = f[4]
            RUN_FINISHED = f[5]; RUN_SECONDS = to_number(f[6]); RUN_DATABASE = f[7]; RUN_VERSION = f[8]
            RUN_ERROR = (n >= 10) ? f[9] : ""
        } else if (tag == "ANON_R_SETTING") {
            split_fields(line, f, 0)
            SET_N++
            SET_CAT[SET_N] = f[1]; SET_ID[SET_N] = f[2]; SET_DESC[SET_N] = f[3]; SET_ATTR[SET_N] = f[4]
        } else if (tag == "ANON_R_IDENT") {
            split_fields(line, f, 0)
            ID_N++
            ID_CAT[ID_N] = f[1]; ID_FOUND[ID_N] = to_number(f[2]); ID_NEW[ID_N] = to_number(f[3])
            ID_REUSED[ID_N] = to_number(f[4]); ID_FOUNDNOW[ID_N] = to_number(f[5])
        } else if (tag == "ANON_R_ACCOUNTS") {
            split_fields(line, f, 0)
            ACC_SET = 1
            ACC_MASTER = to_number(f[1]); ACC_BOTH = to_number(f[2]); ACC_STRUCTURE = to_number(f[3])
            ACC_REFERENCE = to_number(f[4])
        } else if (tag == "ANON_R_IDNOTES") {
            split_fields(line, f, 0)
            IDN_SET = 1
            IDN_SAME = to_number(f[1]); IDN_PRECEDENCE = to_number(f[2]); IDN_DRIFT = to_number(f[3])
            IDN_SUPERSEDED = to_number(f[4])
        } else if (tag == "ANON_R_XREASON") {
            split_fields(line, f, 11)
            X_N++
            X_CODE[X_N] = f[1]; X_SORT[X_N] = to_number(f[2]); X_LABEL[X_N] = f[3]
            X_PARTIES[X_N] = to_number(f[4]); X_INTIERS[X_N] = to_number(f[5]); X_PARTYNODE[X_N] = to_number(f[6])
            X_OTHER[X_N] = to_number(f[7]); X_REFS[X_N] = to_number(f[8]); X_BRIEF[X_N] = f[9]
            X_WHY[X_N] = ""; X_FIX[X_N] = ""; X_SQLN[X_N] = 0
            X_INDEX[tolower(f[1])] = X_N
        } else if (tag == "ANON_R_XWHY" || tag == "ANON_R_XFIX" || tag == "ANON_R_XSQL") {
            if (split_fields(line, f, 3) < 3 || !(tolower(f[1]) in X_INDEX)) continue
            i = X_INDEX[tolower(f[1])]
            if (tag == "ANON_R_XWHY") X_WHY[i] = f[2]
            else if (tag == "ANON_R_XFIX") X_FIX[i] = f[2]
            else X_SQL[i, ++X_SQLN[i]] = f[2]
        } else if (tag == "ANON_R_XTABLE") {
            split_fields(line, f, 0)
            XT_N++
            XT_TABLE[XT_N] = f[1]; XT_ROWS[XT_N] = to_number(f[2]); XT_COLUMNS[XT_N] = to_number(f[3])
        } else if (tag == "ANON_R_HARVEST") {
            split_fields(line, f, 0)
            H_N++
            H_DOMAIN[H_N] = f[1]; H_CODES[H_N] = to_number(f[2]); H_COLUMNS[H_N] = to_number(f[3])
            H_ROWS[H_N] = to_number(f[4])
        } else if (tag == "ANON_R_ITEM") {
            split_fields(line, f, 0)
            IT_N++
            IT_SEQ[IT_N] = round_even(to_number(f[1])); IT_TABLE[IT_N] = f[2]; IT_COLUMN[IT_N] = f[3]
            IT_RULE[IT_N] = f[4]; IT_CATEGORY[IT_N] = f[5]; IT_SOURCE[IT_N] = f[6]; IT_STATE[IT_N] = f[7]
        } else if (tag == "ANON_R_STEP") {
            n = split_fields(line, f, 9)
            ST_N++
            ST_ID[ST_N] = round_even(to_number(f[1])); ST_PHASE[ST_N] = f[2]; ST_STATUS[ST_N] = f[3]
            ST_ROWS[ST_N] = to_number(f[4]); ST_X[ST_N] = to_number(f[5]); ST_MS[ST_N] = to_number(f[6])
            ST_OBJECT[ST_N] = f[7]; ST_MESSAGE[ST_N] = (n >= 9) ? f[8] : ""
        } else if (tag == "ANON_R_ESTIMATE") {
            split_fields(line, f, 0)
            EST_SET = 1
            EST_SECONDS = to_number(f[1]); EST_BASIS = f[2]
        } else if (tag == "ANON_R_TRIGGERS") {
            split_fields(line, f, 0)
            TRIGGERS = to_number(f[1])
        } else if (tag == "ANON_R_V") {
            n = split_fields(line, f, 7)
            V_N++
            V_PART[V_N] = f[1]; V_STATUS[V_N] = f[2]; V_BAD[V_N] = to_number(f[3]); V_TOTAL[V_N] = to_number(f[4])
            V_CHECK[V_N] = f[5]; V_DETAIL[V_N] = (n >= 7) ? f[6] : ""
        }
    }
    close(file)
    # The reasons in their order (X_ORDER): by sort order, ties as they came.
    for (i = 1; i <= X_N; i++) {
        X_ORDER[i] = i
        for (j = i; j > 1 && X_SORT[X_ORDER[j - 1]] > X_SORT[X_ORDER[j]]; j--) {
            t = X_ORDER[j]; X_ORDER[j] = X_ORDER[j - 1]; X_ORDER[j - 1] = t
        }
    }
}

# ----------------------------------------------------------------------------
# Figures
# ----------------------------------------------------------------------------

# The table of what a logged step worked on: its object up to the first dot.
function object_table(o) { sub(/[.].*$/, "", o); return o }
# Its column (an identifier step): its object up to the first space.
function object_column(o) { sub(/ .*$/, "", o); return o }

# The figures of a run, from its results: by kind of work (FREE_, IDS_,
# LABELS_, ATTRS_: COLUMNS, ROWS, MS; IDS_X, IDS_NOCLIENT, FREE_TABLES), what
# was left for review (REVIEW_N steps REVIEW_STEP[], REVIEW_ROWS,
# REVIEW_COLUMNS), the rows and tables changed (FIG_ROWS, FIG_TABLES), the X_
# parties (FIG_XPARTIES), what is not in this database (NOT_HERE,
# TABLES_NOT_HERE, COLUMNS_NOT_HERE), the switches off (OFF_N, OFF[]), the
# translations (RECORDED, REUSED) and the verdict a run is expected to end
# with (EXPECTED).
function compute_figures(   i, s, counted, k, col, freeTables, changed, codeRows, reviewCols, notHereTables, drift, name) {
    FREE_COLUMNS = 0; IDS_COLUMNS = 0; LABELS_COLUMNS = 0; ATTRS_COLUMNS = 0
    FREE_ROWS = 0; IDS_ROWS = 0; LABELS_ROWS = 0; ATTRS_ROWS = 0
    FREE_MS = 0; IDS_MS = 0; LABELS_MS = 0; ATTRS_MS = 0
    IDS_X = 0; IDS_NOCLIENT = 0; FREE_TABLES = 0
    REVIEW_N = 0; REVIEW_ROWS = 0; REVIEW_COLUMNS = 0
    FIG_ROWS = 0; FIG_TABLES = 0; FIG_XPARTIES = 0; NOT_HERE = 0; TABLES_NOT_HERE = 0; COLUMNS_NOT_HERE = 0
    OFF_N = 0; RECORDED = 0; REUSED = 0; EXPECTED = "PASS"

    for (i = 1; i <= IT_N; i++) {
        if (IT_STATE[i] != "HERE") continue
        if (IT_RULE[i] == "NULL_OUT") FREE_COLUMNS++
        else if (IT_RULE[i] == "CODE") IDS_COLUMNS++
        else if (IT_RULE[i] == "DESCRIPTION") LABELS_COLUMNS++
        else if (IT_RULE[i] == "SELF_CODE") ATTRS_COLUMNS++
    }
    # Free text is emptied table by table: the tables its statements worked
    # on, as the live line counts them.
    for (i = 1; i <= ST_N; i++) {
        if (ST_PHASE[i] != "NULL_OUT" || ST_STATUS[i] == "SKIPPED") continue
        k = tolower(object_table(ST_OBJECT[i]))
        if (!(k in freeTables)) { freeTables[k] = 1; FREE_TABLES++ }
    }
    for (i = 1; i <= ST_N; i++) {
        s = ST_PHASE[i]
        counted = (ST_STATUS[i] == "OK" || ST_STATUS[i] == "DRYRUN")
        if (s == "MAPPING") { if (counted) RECORDED += ST_ROWS[i]; continue }
        if (s == "NULL_OUT") { FREE_MS += ST_MS[i]; if (counted) FREE_ROWS += ST_ROWS[i] }
        else if (s == "CODE") { IDS_MS += ST_MS[i]; if (counted) { IDS_ROWS += ST_ROWS[i]; IDS_X += ST_X[i] } }
        else if (s == "DESCRIPTION") { LABELS_MS += ST_MS[i]; if (counted) LABELS_ROWS += ST_ROWS[i] }
        else if (s == "SELF_CODE") { ATTRS_MS += ST_MS[i]; if (counted) ATTRS_ROWS += ST_ROWS[i] }
        else continue
        if (counted && ST_ROWS[i] > 0) changed[tolower(object_table(ST_OBJECT[i]))] = 1
        if (s == "CODE" && ST_STATUS[i] != "SKIPPED" && ST_STATUS[i] != "DISABLED") {
            col = tolower(object_column(ST_OBJECT[i]))
            if (!(col in codeRows)) codeRows[col] = 0
            if (counted || ST_STATUS[i] == "REVIEW") codeRows[col] += ST_ROWS[i]
        }
        if (ST_STATUS[i] == "REVIEW") {
            REVIEW_STEP[++REVIEW_N] = i
            REVIEW_ROWS += ST_ROWS[i]
            col = tolower(object_column(ST_OBJECT[i]))
            if (!(col in reviewCols)) { reviewCols[col] = 1; REVIEW_COLUMNS++ }
        }
    }
    for (col in codeRows) if (codeRows[col] == 0) IDS_NOCLIENT++
    FIG_ROWS = FREE_ROWS + IDS_ROWS + LABELS_ROWS + ATTRS_ROWS
    for (k in changed) FIG_TABLES++
    for (i = 1; i <= X_N; i++) FIG_XPARTIES += X_PARTIES[i]
    for (i = 1; i <= IT_N; i++) {
        if (IT_STATE[i] == "HERE") continue
        NOT_HERE++
        if (IT_STATE[i] == "NO_COLUMN") COLUMNS_NOT_HERE++
        if (IT_STATE[i] == "NO_TABLE" && !(tolower(IT_TABLE[i]) in notHereTables)) {
            notHereTables[tolower(IT_TABLE[i])] = 1
            TABLES_NOT_HERE++
        }
    }
    for (i = 1; i <= ID_N; i++) REUSED += ID_REUSED[i]
    for (i = 1; i <= SET_N; i++) {
        name = tolower(CATEGORY_NAME[SET_CAT[i]])
        sub(/ \(.*$/, "", name)
        if (SET_ID[i] == "N") OFF[++OFF_N] = name " codes"
        if (SET_DESC[i] == "N") OFF[++OFF_N] = name " labels"
        if (SET_ATTR[i] == "N") OFF[++OFF_N] = name " attributes"
    }
    drift = IDN_SET ? IDN_DRIFT : 0
    if (REVIEW_ROWS > 0 || drift > 0) EXPECTED = "REVIEW REQUIRED"
    else if (OFF_N > 0) EXPECTED = "INCOMPLETE"
}

# The switches that were off, as one list: "entity codes, portfolio labels".
function switches_off(   i, s) {
    s = ""
    for (i = 1; i <= OFF_N; i++) s = s (i > 1 ? ", " : "") OFF[i]
    return s
}

# The verification by part (VP_N parts): VP_PART, VP_NAME, and how many
# checks were made (VP_CHECKED), failed, hold values for review, were
# switched off and were skipped.
function verify_parts(   names, keys, n, k, i, part, rows) {
    n = split("SETUP IDENTITY RESIDUAL FREETEXT LABELS MAPPING SETTINGS", keys, " ")
    names["SETUP"] = "Run to verify"; names["IDENTITY"] = "Identities and translations"
    names["RESIDUAL"] = "Identifier columns"; names["FREETEXT"] = "Free text"
    names["LABELS"] = "Labels and attributes"; names["MAPPING"] = "Mapping integrity"
    names["SETTINGS"] = "Protections switched off"
    VP_N = 0
    for (k = 1; k <= n; k++) {
        part = keys[k]
        rows = 0
        for (i = 1; i <= V_N; i++) if (V_PART[i] == part && V_STATUS[i] != "INFO" && V_STATUS[i] != "WARN") rows++
        if (rows == 0) continue
        VP_N++
        VP_PART[VP_N] = part; VP_NAME[VP_N] = names[part]
        VP_CHECKED[VP_N] = 0; VP_FAILED[VP_N] = 0; VP_REVIEW[VP_N] = 0; VP_OFF[VP_N] = 0; VP_SKIPPED[VP_N] = 0
        for (i = 1; i <= V_N; i++) {
            if (V_PART[i] != part || V_STATUS[i] == "INFO" || V_STATUS[i] == "WARN") continue
            if (V_STATUS[i] != "SKIP") VP_CHECKED[VP_N]++
            if (V_STATUS[i] == "FAIL") VP_FAILED[VP_N]++
            if (V_STATUS[i] == "REVIEW") VP_REVIEW[VP_N]++
            if (V_STATUS[i] == "DISABLED") VP_OFF[VP_N]++
            if (V_STATUS[i] == "SKIP") VP_SKIPPED[VP_N]++
        }
    }
}

# What to know (GK_N items GK[]): the verification's warnings, the inventory
# items not in this database, codes found only in references,
# classifications that drifted, and - for a dry run - the triggers.
function good_to_know(dry,   i, d, n1, n2, what) {
    GK_N = 0
    for (i = 1; i <= V_N; i++) {
        if (V_STATUS[i] != "WARN") continue
        d = V_DETAIL[i]
        if (d ~ /^[0-9,]+ [vV][aA][lL][uU][eE]\([sS]\) [iI][nN] [0-9,]+ [cC][oO][lL][uU][mM][nN]\([sS]\)/) {
            n1 = substr(d, 1, index(d, " ") - 1)
            d = substr(d, index(d, " ") + 1)
            d = substr(d, index(d, " ") + 1)
            d = substr(d, index(d, " ") + 1)
            n2 = substr(d, 1, index(d, " ") - 1)
            GK[++GK_N] = "Values that are no client code this run knows - currencies, product codes, system values - were found in " \
                         "identifier columns: " fmt_plural(to_number(n1), "value") " in " fmt_plural(to_number(n2), "column") \
                         ". Not a leak by itself; a client code among them belongs in anon_meta.confirmed_identity (verify.txt names the columns)."
        } else {
            GK[++GK_N] = V_CHECK[i] ": " V_DETAIL[i]
        }
    }
    if (NOT_HERE > 0) {
        GK[++GK_N] = fmt_plural(NOT_HERE, "item") " of the inventory are not in this database: " fmt_plural(TABLES_NOT_HERE, "table") \
                     " and " fmt_plural(COLUMNS_NOT_HERE, "column") ". They are skipped; report.html lists them."
    }
    for (i = 1; i <= H_N; i++) {
        what = "parties: each gets its own X_ value (missing master)"
        if (H_DOMAIN[i] == "ACCOUNT") what = "bank accounts: each gets its own CB_ value"
        GK[++GK_N] = "Codes found only in references, their master row deleted, are " what ". " fmt_plural(H_CODES[i], "code") \
                     ", in " fmt_plural(H_ROWS[i], "row") " of " fmt_plural(H_COLUMNS[i], "column") "."
    }
    if (IDN_SET && IDN_DRIFT > 0) {
        GK[++GK_N] = fmt_plural(IDN_DRIFT, "identity", "identities") " would be classified differently today than when they were recorded: the recorded translation is kept, and the verification says REVIEW REQUIRED."
    }
    if (dry && TRIGGERS > 0) {
        GK[++GK_N] = "A run disables the " fmt_count(TRIGGERS) " triggers of OP while it works, and enables them again at its end."
    }
}
