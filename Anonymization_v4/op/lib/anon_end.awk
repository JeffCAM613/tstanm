# ============================================================================
# OP Anonymization - The end of a run, on the screen
# ============================================================================
# Purpose : For run_op_anonymization.sh: the end of a run in plain words -
#           the result in one sentence, the figures, the identities, the
#           unclassified parties, what was left for review, what to know,
#           and what comes next - from the run's results.txt and its state.
#           The same screens as anon_screen.ps1 on Windows.
# Usage   : awk -f anon_results.awk -f anon_end.awk
#           with, in the environment, ANON_RESULTS (results.txt) and
#           ANON_STATE (the state of the run, written by anon.sh: one
#           NAME|value line each - STATUS, DRY, TNS, LAUNCHER, WIDTH, VERDICT,
#           COLOR; DURATION|<step>|<status>|<seconds>, ERROR|<message> and
#           ANON_CHECK lines, in order; REFUSAL|<message>). Prints each line
#           of the screen as its colour, a tab, and its text.
# Requires: a POSIX awk (gawk, mawk, busybox awk), run with LC_ALL=C.
# ============================================================================

BEGIN {
    # How this platform writes its commands and files.
    OPTION = "--"
    CONFIG_TEXT = "config/anonymization.ini"
    VERIFY_TEXT = "op/verify/verify_op_coverage.sql"
    read_results(ENVIRON["ANON_RESULTS"])
    read_state(ENVIRON["ANON_STATE"])
    compute_figures()
    show_run_end()
    exit
}

# The state of the run: its status, its mode, the database, the command that
# runs it, the width of the screen, how it ends; its steps, its errors and
# the checks of its plan.
function read_state(file,   line, f) {
    STATUS = ""; DRY = 0; TNS = ""; LAUNCHER = ""; WIDTH = 100; VERDICT = ""; COLOR = ""; REFUSAL = ""
    DUR_N = 0; ERR_N = 0
    CHK_N = 0
    if (file == "") return
    while ((getline line < file) > 0) {
        sub(/\r$/, "", line)
        if (line ~ /^ANON_CHECK[|]/) { add_check(line); continue }
        split_fields(line, f, 2)
        if (f[0] == "STATUS") STATUS = f[1]
        else if (f[0] == "DRY") DRY = (f[1] == "1")
        else if (f[0] == "TNS") TNS = f[1]
        else if (f[0] == "LAUNCHER") LAUNCHER = f[1]
        else if (f[0] == "WIDTH") WIDTH = f[1] + 0
        else if (f[0] == "VERDICT") VERDICT = f[1]
        else if (f[0] == "COLOR") COLOR = f[1]
        else if (f[0] == "REFUSAL") REFUSAL = f[1]
        else if (f[0] == "OPTION") OPTION = f[1]
        else if (f[0] == "CONFIG") CONFIG_TEXT = f[1]
        else if (f[0] == "VERIFY") VERIFY_TEXT = f[1]
        else if (f[0] == "ERROR") ERRORS[++ERR_N] = f[1]
        else if (f[0] == "DURATION") {
            split_fields(line, f, 4)
            DUR_N++
            DUR_KEY[DUR_N] = f[1]; DUR_STATUS[DUR_N] = f[2]; DUR_SECONDS[DUR_N] = f[3] + 0
        }
    }
    close(file)
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

function out(text, color) { print color "\t" text }

# A text wrapped at the width of the screen: its first line after first, the
# others under it (or indented by indent, when it is given).
function wrapped(first, text, color, indent,   pad, line, words, n, i) {
    pad = rep(" ", (indent == "") ? length(first) : indent)
    line = first
    n = split(text, words, / /)
    for (i = 1; i <= n; i++) {
        if (words[i] == "") continue
        if (length(line) + length(words[i]) > WIDTH && line ~ /[^ \t\r\n]/ && length(line) > length(pad)) {
            out(rtrim(line), color)
            line = pad
        }
        line = line words[i] " "
    }
    if (line ~ /[^ \t\r\n]/) out(rtrim(line), color)
}

function rule(color) { out(" " rep("=", 79), (color == "") ? "White" : color) }

# ----------------------------------------------------------------------------
# The end of a run
# ----------------------------------------------------------------------------

function show_run_end() {
    out("", "")
    if (STATUS == "REFUSED") show_refused_end()
    else if (STATUS == "CANCELLED") {
        rule("Yellow")
        out("  NOT STARTED   You did not type YES. Nothing was changed.", "Yellow")
        rule("Yellow")
        out("  Next     " LAUNCHER "     asks again, after the same checks", "")
    }
    else if (STATUS == "FAILED") show_failed_end()
    else if (STATUS == "STOPPED") show_stopped_end()
    else if (DRY) show_dry_run_end()
    else show_done_end()
}

# "What / Columns / Rows ..." of the work, done or to do.
function show_work_table(dry,   head, rowsHead) {
    rowsHead = dry ? "Rows to change" : "Rows changed"
    head = "   " pad_right("What", 30) pad_left("Columns", 7) pad_left(rowsHead, 17) pad_left("Of them X_", 13)
    if (!dry) head = head pad_left("Time", 9)
    out(head, "White")
    work_row("Free text emptied", FREE_COLUMNS, FREE_ROWS, "-", FREE_MS, dry)
    work_row("Identifiers renamed", IDS_COLUMNS, IDS_ROWS, fmt_count(IDS_X), IDS_MS, dry)
    work_row("Labels masked", LABELS_COLUMNS, LABELS_ROWS, "-", LABELS_MS, dry)
    work_row("Attributes masked", ATTRS_COLUMNS, ATTRS_ROWS, "-", ATTRS_MS, dry)
    if (REVIEW_ROWS > 0) {
        head = "   " pad_right("Left as they are, for review", 30) pad_left(REVIEW_COLUMNS, 7) pad_left(fmt_count(REVIEW_ROWS), 17) pad_left("-", 13)
        if (!dry) head = head pad_left("-", 9)
        out(head, "Yellow")
    }
}
function work_row(what, columns, rows, x, ms, dry,   line) {
    line = "   " pad_right(what, 30) pad_left(columns, 7) pad_left(fmt_count(rows), 17) pad_left(x, 13)
    if (!dry) line = line pad_left(fmt_clock(ms / 1000), 9)
    out(line, "")
}

function show_identity_table(   i, note, line) {
    if (ID_N == 0) return
    out("", "")
    out("   " pad_right("Identities", 26) pad_left("Found", 8) pad_left("New translations", 19) pad_left("Reused", 9), "White")
    for (i = 1; i <= ID_N; i++) {
        note = ""
        if (ID_CAT[i] == "UNCLASSIFIED_PARTY" && ID_FOUND[i] > 0) note = "by reason below"
        if (ID_CAT[i] == "BANK_ACCOUNT" && ACC_SET && ACC_STRUCTURE > 0) note = fmt_count(ACC_STRUCTURE) " only on the structure"
        line = "   " pad_right(CATEGORY_NAME[ID_CAT[i]], 26) pad_left(fmt_count(ID_FOUND[i]), 8) pad_left(fmt_count(ID_NEW[i]), 19) \
               pad_left(fmt_count(ID_REUSED[i]), 9)
        if (note != "") line = line "   " note
        out(line, "")
    }
}

# The unclassified parties: by reason with the reason in one line, and where
# their X_ values go.
function show_unclassified(dry,   total, k, i, n, list, where, top) {
    if (X_N == 0) return
    out("", "")
    total = fmt_count(FIG_XPARTIES)
    if (dry) {
        out("   Unclassified parties (X_): " total ". The data does not say which kind of party they are.", "")
        out("     " pad_right("Reason", 25) pad_left("Parties", 8) pad_left("In tiers", 11) pad_left("w_tiers node", 15) pad_left("Other screen", 15), "White")
        for (k = 1; k <= X_N; k++) {
            i = X_ORDER[k]
            out("     " pad_right(X_LABEL[i], 25) pad_left(fmt_count(X_PARTIES[i]), 8) pad_left(fmt_count(X_INTIERS[i]), 11) \
                pad_left(fmt_count(X_PARTYNODE[i]), 15) pad_left(fmt_count(X_OTHER[i]), 15), "")
            if (X_BRIEF[i] != "") out("       " X_BRIEF[i], "DarkGray")
        }
    } else {
        if (IDS_X > 0) {
            out("   Unclassified parties (X_): " total ", renamed in " fmt_plural(XT_N, "table") " (" fmt_plural(IDS_X, "row") ")", "")
        } else {
            out("   Unclassified parties (X_): " total "; no row of theirs changed in this run", "")
        }
        for (k = 1; k <= X_N; k++) {
            i = X_ORDER[k]
            out("     " pad_right(X_LABEL[i], 25) pad_left(fmt_count(X_PARTIES[i]), 5) "   " X_BRIEF[i], "")
        }
    }
    if (dry && XT_N > 0) {
        n = (XT_N < 3) ? XT_N : 3
        for (i = 1; i <= n; i++) top[i] = XT_TABLE[i] " (" fmt_count(XT_ROWS[i]) ")"
        list = top[1]
        if (n == 2) list = top[1] " and " top[2]
        if (n == 3) list = top[1] ", " top[2] " and " top[3]
        where = "Their X_ values would go to " fmt_plural(IDS_X, "row") " in " fmt_plural(XT_N, "table")
        if (XT_N > 1) where = where ", the most in " list "."; else where = where ": " list "."
        wrapped("   ", where, "")
        wrapped("   ", "report.html says what to do about each reason, with one query per reason that lists them. The queries read this dry run's plan: run them before the next run starts.", "")
    }
}

function show_review(dry,   k, i) {
    if (REVIEW_ROWS == 0) return
    out("", "")
    if (dry) {
        wrapped("   ", "Left for review: " fmt_plural(REVIEW_ROWS, "value") " in " fmt_plural(REVIEW_COLUMNS, "column") \
                       ". A run leaves them as they are, and its verification says REVIEW REQUIRED while they remain.", "Yellow")
    } else {
        wrapped("   ", "Left for review: " fmt_plural(REVIEW_ROWS, "value") " in " fmt_plural(REVIEW_COLUMNS, "column") \
                       ", as they were. The verification says REVIEW REQUIRED while they remain.", "Yellow")
    }
    for (k = 1; k <= REVIEW_N; k++) {
        i = REVIEW_STEP[k]
        out("     " pad_right(ST_OBJECT[i], 58) pad_left(fmt_count(ST_ROWS[i]), 8), "")
    }
}

function show_good_to_know(dry,   i) {
    good_to_know(dry)
    if (GK_N == 0) return
    out("", "")
    out("  Good to know (" GK_N ")", "White")
    for (i = 1; i <= GK_N; i++) wrapped("   - ", GK[i], "")
}

# The end of a dry run: what a run would change, how it would end, about how
# long it would take; the figures, the identities, the X_ parties, what would
# be left for review, what to know, and the next command.
function show_dry_run_end(   why, basis, about) {
    rule("")
    out("  A run would change " fmt_plural(FIG_ROWS, "row") " in " fmt_plural(FIG_TABLES, "table") ".", "White")
    if (EXPECTED == "REVIEW REQUIRED") {
        why = fmt_plural(REVIEW_ROWS, "value") " in " fmt_plural(REVIEW_COLUMNS, "column") " would be left for review."
        if (REVIEW_ROWS == 0) why = "identities classified differently today than when they were recorded."
        wrapped("  ", "It would end REVIEW REQUIRED: " why, "Yellow")
    } else if (EXPECTED == "INCOMPLETE") {
        wrapped("  ", "It would end INCOMPLETE: " switches_off() " switched off.", "Yellow")
    } else {
        out("  Its verification would be expected to PASS.", "White")
    }
    if (EST_SET && EST_SECONDS > 0) {
        basis = "a rough estimate"
        if (toupper(EST_BASIS) ~ /^R-/) basis = "a rough estimate, from the speed of " EST_BASIS " on this database"
        about = fmt_about(EST_SECONDS)
        out("  " capitalize(about) ", " basis ". Nothing was changed.", "White")
    } else {
        out("  Nothing was changed.", "White")
    }
    rule("")
    show_work_table(1)
    show_identity_table()
    show_unclassified(1)
    show_review(1)
    show_good_to_know(1)
    out("", "")
    out("  Nothing was changed.", "Green")
    out("  Next     " LAUNCHER "     the run itself (it checks again, then asks)", "")
}

# The end of a run that completed: what was done, in how long, and what its
# verification says.
function show_done_end(   seconds, i, note, color) {
    seconds = 0
    for (i = 1; i <= DUR_N; i++) if (DUR_KEY[i] != "READY") seconds += DUR_SECONDS[i]
    rule(COLOR)
    out("  DONE   " fmt_plural(FIG_ROWS, "row") " changed in " fmt_clock(seconds) ". Verification: " VERDICT ".", COLOR)
    if (VERDICT == "PASS") {
        wrapped("         ", "Every protection was on, no original value was found where the inventory covers, and nothing was left for review.", COLOR)
    } else if (VERDICT == "REVIEW REQUIRED") {
        if (REVIEW_ROWS > 0) {
            wrapped("         ", fmt_plural(REVIEW_ROWS, "client value") " in " fmt_plural(REVIEW_COLUMNS, "column") \
                                  " were left as they are, on purpose; their role is not settled.", COLOR)
        } else {
            wrapped("         ", "Identities are classified differently today than when they were recorded; report.html lists what to review.", COLOR)
        }
    } else if (VERDICT == "INCOMPLETE") {
        wrapped("         ", "Nothing was found where protection was on, but " switches_off() " were switched off: their client data stays.", COLOR)
    } else if (VERDICT == "FAIL") {
        wrapped("         ", "Client data is still present where it should have been replaced: report.html names the columns.", COLOR)
    } else if (VERDICT == "NOT VERIFIED") {
        wrapped("         ", "The verification could not run: run sqlplus op/<password>@" TNS " @" VERIFY_TEXT ".", COLOR)
    }
    rule(COLOR)
    show_work_table(0)
    verify_parts()
    if (VP_N > 0) {
        out("", "")
        out("   " pad_right("Verification", 30) pad_left("Checked", 8) pad_left("Failed", 9) pad_left("For review", 13), "White")
        for (i = 1; i <= VP_N; i++) {
            if (VP_PART[i] == "SETTINGS") {
                note = "none"
                if (VP_OFF[i] > 0) note = fmt_plural(VP_OFF[i], "protection") " off"
                out("   " pad_right(VP_NAME[i], 30) pad_left("-", 8) pad_left("-", 9) pad_left("-", 13) "   " note, "")
                continue
            }
            color = ""
            if (VP_FAILED[i] > 0) color = "Red"; else if (VP_REVIEW[i] > 0) color = "Yellow"
            out("   " pad_right(VP_NAME[i], 30) pad_left(fmt_count(VP_CHECKED[i]), 8) pad_left(fmt_count(VP_FAILED[i]), 9) \
                pad_left(fmt_count(VP_REVIEW[i]), 13), color)
        }
    }
    show_unclassified(0)
    show_review(0)
    show_good_to_know(0)
    out("", "")
    if (VERDICT == "PASS") {
        wrapped("  Next     ", "keep this run folder with the copy: report.html, verify.txt and manifest.txt say what was done to it.", "")
    } else if (VERDICT == "REVIEW REQUIRED") {
        wrapped("  Next     ", "decide on what was left for review (report.html, \"Left for review\"). A new run on this data keeps every translation.", "")
    } else if (VERDICT == "INCOMPLETE") {
        wrapped("  Next     ", "to complete it, switch the protections on in " CONFIG_TEXT " and run again: the translations are kept.", "")
    } else {
        wrapped("  Next     ", "do not hand over this copy: report.html names the columns that still hold client data.", "")
    }
}

# A run its checks refused: the check that refused it, and what to do.
function show_refused_end(   i, n, unmet, why, first, label) {
    n = 0
    for (i = 1; i <= CHK_N; i++) if (CHK_STATUS[i] == "NOT_MET" && CHK_NEEDED[i] == "REQUIRED") unmet[++n] = i
    why = ""
    if (n > 0) why = " " CHK_TITLE[unmet[1]] ": not met."
    else if (REFUSAL != "") why = " " REFUSAL
    rule("Red")
    wrapped("  NOT STARTED   ", "Nothing was changed." why, "Red")
    rule("Red")
    first = 1
    for (i = 1; i <= n; i++) {
        if (CHK_TODO[unmet[i]] == "") continue
        label = first ? "  Next     " : "           "
        wrapped(label, CHK_TODO[unmet[i]], "")
        first = 0
    }
    if (first) wrapped("  Next     ", "report.txt says what the checks found.", "")
    out("           Then " LAUNCHER " " OPTION "dryrun", "")
}

# A run that failed: how far it got, that the triggers of OP are enabled
# again, and that a new run resumes.
function show_failed_end(   worked, i, n, seen) {
    worked = (FIG_ROWS > 0 && !DRY)
    rule("Red")
    if (DUR_N <= 2 && FIG_ROWS == 0) {
        wrapped("  FAILED   ", "The checks could not run to their end. Nothing was changed.", "Red")
    } else if (worked) {
        wrapped("  FAILED   ", fmt_plural(FIG_ROWS, "row") " were changed before it failed. Each table or column is its own transaction: nothing is half done. The triggers of OP are enabled again.", "Red")
    } else {
        wrapped("  FAILED   ", "Nothing in OP was changed.", "Red")
    }
    rule("Red")
    n = 0
    for (i = 1; i <= ERR_N && n < 5; i++) {
        if (ERRORS[i] in seen) continue
        seen[ERRORS[i]] = 1
        n++
        wrapped("   - ", ERRORS[i], "Red")
    }
    wrapped("  Next     ", "report.txt has the full output. Once the cause is removed, the same command resumes: the translations recorded so far are kept.", "")
}

function show_stopped_end() {
    rule("Yellow")
    if (DRY || FIG_ROWS == 0) {
        wrapped("  STOPPED   ", "On request. Nothing was changed.", "Yellow")
    } else {
        wrapped("  STOPPED   ", "On request, after " fmt_plural(FIG_ROWS, "row") " were changed. Every table or column done is complete, and the triggers of OP are enabled again.", "Yellow")
    }
    rule("Yellow")
    wrapped("  Next     ", "the same command resumes from here, with the same translations: " LAUNCHER, "")
}
