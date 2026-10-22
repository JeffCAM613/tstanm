# ============================================================================
# OP Anonymization - report.html of a run
# ============================================================================
# Purpose : For run_op_anonymization.sh: writes report.html in a run folder
#           from the files the run left there: manifest.txt, results.txt (the
#           figures, counts only), report.txt and verify.txt. The verdict in
#           a word, the result in one sentence, the main figures, then the
#           work, the verification, what was left for review, the
#           unclassified parties, the identities, the checks, the switches,
#           the duration of each step, what to know and what comes next;
#           folded below, every column of the inventory, what is not in this
#           database, and the full text output. One file with its styles
#           inside: it can be opened, printed and sent as it is. The same
#           report as anon_html.ps1 on Windows.
#
#           It reads, never re-checks: every figure is one the run or its
#           verification recorded. It holds counts and names of tables and
#           columns only - never an identifier. The queries that list the
#           unclassified parties are printed for the operator, never run.
# Usage   : awk -f anon_results.awk -f anon_html.awk
#           with ANON_FOLDER (the run folder) in the environment. Writes
#           report.html in it; exits 1 when the folder has no manifest.txt.
# Requires: a POSIX awk (gawk, mawk, busybox awk), run with LC_ALL=C.
# ============================================================================

BEGIN {
    # How this platform writes its commands and files.
    LAUNCHER = "op/run_op_anonymization.sh"
    OPTION = "--"
    CONFIG_TEXT = "config/anonymization.ini"
    if (ENVIRON["ANON_HTML_LAUNCHER"] != "") LAUNCHER = ENVIRON["ANON_HTML_LAUNCHER"]
    if (ENVIRON["ANON_HTML_OPTION"] != "") OPTION = ENVIRON["ANON_HTML_OPTION"]
    if (ENVIRON["ANON_HTML_CONFIG"] != "") CONFIG_TEXT = ENVIRON["ANON_HTML_CONFIG"]
    exit write_html_report(ENVIRON["ANON_FOLDER"])
}

# ----------------------------------------------------------------------------
# Parts of the page
# ----------------------------------------------------------------------------

function html(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    return s
}

# A table. Its cells are given joined by SUBSEP; numeric lists the numbers of
# the columns, from 0, that hold figures (",1,2,"): they are aligned right.
function table_start(head, numeric, id,   h, cells, n, i) {
    h = "<div class=\"tw\"><table" (id != "" ? " id=\"" id "\"" : "") "><thead><tr>"
    n = split(head, cells, SUBSEP)
    for (i = 1; i <= n; i++) h = h "<th" num_class(numeric, i - 1) ">" cells[i] "</th>"
    return h "</tr></thead><tbody>"
}
function table_row(row, numeric,   h, cells, n, i) {
    h = "<tr>"
    n = split(row, cells, SUBSEP)
    for (i = 1; i <= n; i++) h = h "<td" num_class(numeric, i - 1) ">" cells[i] "</td>"
    return h "</tr>"
}
function table_end() { return "</tbody></table></div>" }
function num_class(numeric, i) { return (index(numeric, "," i ",") > 0) ? " class=\"n\"" : "" }
function cells2(a, b) { return a SUBSEP b }
function cells3(a, b, c) { return a SUBSEP b SUBSEP c }
function cells4(a, b, c, d) { return a SUBSEP b SUBSEP c SUBSEP d }
function cells5(a, b, c, d, e) { return a SUBSEP b SUBSEP c SUBSEP d SUBSEP e }

function card(title, inner) { return "<div class=\"card\"><h2>" title "</h2>" inner "</div>" }
function folded(summary, inner) { return "<div class=\"card\"><details class=\"more\"><summary>" summary "</summary>" inner "</details></div>" }
function pill(class, word) { return "<span class=\"pill " class "\">" word "</span>" }

function bar(label, seconds, max,   width) {
    width = 0.6
    if (max > 0) {
        width = 100.0 * seconds / max
        if (width > 100.0) width = 100.0
        if (width < 0.6) width = 0.6
    }
    return "<div class=\"bar\"><span class=\"bl\">" html(label) "</span><span class=\"track\"><span class=\"fill\" style=\"width:" \
           fmt_fixed1(width) "%\"></span></span><span class=\"bv\">" fmt_clock(seconds) "</span></div>"
}

# A whole text file, as it is; "" when there is none.
function read_text(file,   line, text) {
    text = ""
    while ((getline line < file) > 0) text = text line "\n"
    close(file)
    return text
}

# The order in which the names of tables and columns are listed: a byte
# order in which _ comes before the digits, as Windows sorts them.
function name_key(s) { gsub(/_/, "/", s); return s }

# ----------------------------------------------------------------------------
# One column of the inventory
# ----------------------------------------------------------------------------

# The rows a statement of the run changed (or would change) for one column
# (CF_ROWS, CF_X, CF_MS, CF_REVIEW): its own rows for an identifier column;
# the rows of the statement that covers it for free text, labels and
# attributes - one statement covers the columns of a table together
# (CF_SHARED). CF_STATUSES: the statuses of its steps (",OK,REVIEW,");
# CF_CHECK: the worst its verification said.
function column_figures(it,   name, lname, phase, i, mine, o, lo, p, q, inner, cols, n, k, c, rank, best, r, chk) {
    name = IT_TABLE[it] "." IT_COLUMN[it]
    lname = tolower(name)
    phase = IT_RULE[it]
    if (phase != "CODE" && phase != "NULL_OUT" && phase != "DESCRIPTION" && phase != "SELF_CODE") phase = ""
    CF_ROWS = 0; CF_X = 0; CF_MS = 0; CF_REVIEW = 0; CF_STATUSES = ","; CF_NSTATUSES = 0; CF_SHARED = 0; CF_CHECK = ""
    for (i = 1; i <= ST_N; i++) {
        if (phase == "" || toupper(ST_PHASE[i]) != phase) continue
        mine = 0
        o = ST_OBJECT[i]
        lo = tolower(o)
        p = tolower(IT_TABLE[it]) ".["
        if (phase == "CODE") {
            mine = (tolower(object_column(o)) == lname)
        } else if (index(lo, p) == 1 && (q = index(substr(o, length(p) + 1), "]")) > 0) {
            inner = substr(o, length(p) + 1, q - 1)
            n = split(inner, cols, ",")
            for (k = 1; k <= n; k++) {
                c = cols[k]
                if (tolower(substr(c, length(c) - 7)) == "(masked)" && length(c) >= 8) c = substr(c, 1, length(c) - 8)
                if (tolower(trim(c)) == tolower(IT_COLUMN[it])) mine = 1
            }
            if (mine && n > 1) CF_SHARED = 1
        } else if (lo == lname) {
            mine = 1
        }
        if (!mine) continue
        CF_STATUSES = CF_STATUSES toupper(ST_STATUS[i]) ","
        CF_NSTATUSES++
        if (ST_STATUS[i] == "REVIEW") { CF_REVIEW += ST_ROWS[i]; continue }
        if (ST_STATUS[i] == "OK" || ST_STATUS[i] == "DRYRUN") { CF_ROWS += ST_ROWS[i]; CF_X += ST_X[i] }
        CF_MS += ST_MS[i]
    }
    rank["FAIL"] = 5; rank["REVIEW"] = 4; rank["DISABLED"] = 3; rank["WARN"] = 2; rank["PASS"] = 1; rank["SKIP"] = 0; rank["INFO"] = 0
    best = -1
    for (i = 1; i <= V_N; i++) {
        if (V_PART[i] != "RESIDUAL" && V_PART[i] != "FREETEXT" && V_PART[i] != "LABELS") continue
        chk = V_CHECK[i]
        sub(/ .*$/, "", chk)
        if (tolower(chk) != lname) continue
        r = (toupper(V_STATUS[i]) in rank) ? rank[toupper(V_STATUS[i])] : 0
        if (r > best) { best = r; CF_CHECK = V_STATUS[i] }
    }
}

# ----------------------------------------------------------------------------
# The report
# ----------------------------------------------------------------------------

function write_html_report(folder,   path, line, eq, key, m, nsteps, skey, sstat, ssec, reportText, verifyText, dry, status,
                           verdict, exitCode, run, kind, when, finished, workSeconds, class, badge, lead, ntiles, tnum, tcap,
                           ncards, cards, i, j, k, n, inner, titles, what, identities, failed, rowsHead, head, num, title,
                           note, li, p, text, verb, nrest, top, rest, newHead, notes, word, options, names, nbars, blabel,
                           bsec, max, label, w, todo, ntodo, here, cfrows, x, st, holds, whatOf, nabsent,
                           aitems, awhy, order, t, css, js, files, database, page) {
    path = folder "/manifest.txt"
    if ((getline line < path) <= 0) return 1
    close(path)
    nsteps = 0
    while ((getline line < path) > 0) {
        sub(/\r$/, "", line)
        eq = index(line, "=")
        if (eq <= 1) continue
        key = tolower(substr(line, 1, eq - 1))
        m[key] = substr(line, eq + 1)
        # step.<KEY>=<status>|<seconds>
        if (key ~ /^step[.][a-z]+$/ && m[key] ~ /^[^|]*[|][0-9]+$/) {
            nsteps++
            skey[nsteps] = toupper(substr(key, 6))
            sstat[nsteps] = substr(m[key], 1, index(m[key], "|") - 1)
            ssec[nsteps] = substr(m[key], index(m[key], "|") + 1) + 0
        }
    }
    close(path)
    read_results(folder "/results.txt")
    compute_figures()
    reportText = read_text(folder "/report.txt")
    verifyText = read_text(folder "/verify.txt")

    dry = (m["mode"] == "DRYRUN")
    status = m["status"]; verdict = m["verdict"]; exitCode = m["exit_code"]; run = m["run"]
    kind = dry ? "dry run" : "run"
    when = ""
    if (RUN_SET) {
        finished = RUN_FINISHED
        sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /, "", finished)
        when = html(RUN_STARTED) " to " html(finished) "<br>" fmt_clock(RUN_SECONDS)
    }
    workSeconds = 0
    for (i = 1; i <= nsteps; i++) if (skey[i] != "READY") workSeconds += ssec[i]

    # The verdict in a word, the result in a sentence, the main figures.
    class = "ok"; badge = "Done"; lead = ""; ntiles = 0
    if (status == "REFUSED") {
        class = "bad"; badge = "Not started"
        titles = ""; n = 0
        for (i = 1; i <= CHK_N; i++) {
            if (CHK_STATUS[i] != "NOT_MET" || CHK_NEEDED[i] != "REQUIRED") continue
            titles = titles (n++ > 0 ? ", " : "") tolower(CHK_TITLE[i])
        }
        what = "The checks refused this run."
        if (n > 0) what = "The checks refused this run: " titles ", not met."
        lead = "<strong>" html(what) "</strong> Nothing was changed. Exit code 1."
        tnum[++ntiles] = "0"; tcap[ntiles] = "rows changed"
    } else if (status == "CANCELLED") {
        class = "warn"; badge = "Not started"
        lead = "<strong>The run was not confirmed.</strong> Nothing was changed. Exit code 1."
    } else if (status == "FAILED") {
        class = "bad"; badge = "Failed"
        if (FIG_ROWS > 0 && !dry) {
            lead = "<strong>The run failed after " fmt_count(FIG_ROWS) " rows were changed.</strong> Each table or column is its own transaction: nothing is half done, and the triggers of OP were enabled again. A new run resumes with the same translations. Exit code 1."
        } else {
            lead = "<strong>The run failed.</strong> Nothing in OP was changed. Exit code 1."
        }
    } else if (status == "STOPPED") {
        class = "warn"; badge = "Stopped"
        if (FIG_ROWS > 0 && !dry) {
            lead = "<strong>Stopped on request, after " fmt_count(FIG_ROWS) " rows were changed.</strong> Every table or column done is complete, and the triggers of OP were enabled again. A new run resumes from there with the same translations. Exit code 5."
        } else {
            lead = "<strong>Stopped on request.</strong> Nothing was changed. Exit code 5."
        }
    } else if (dry) {
        badge = "Dry run"
        lead = "<strong>A run would change " fmt_count(FIG_ROWS) " rows in " FIG_TABLES " tables.</strong> "
        if (EXPECTED == "REVIEW REQUIRED") {
            lead = lead "It would end REVIEW REQUIRED: " fmt_count(REVIEW_ROWS) " values in " REVIEW_COLUMNS " columns would be left for review. "
        } else if (EXPECTED == "INCOMPLETE") {
            lead = lead "It would end INCOMPLETE: " html(switches_off()) " switched off. "
        } else {
            lead = lead "Its verification would be expected to PASS. "
        }
        if (EST_SET && EST_SECONDS > 0) lead = lead capitalize(fmt_about(EST_SECONDS)) ", a rough estimate. "
        lead = lead "Nothing was changed."
        tnum[++ntiles] = fmt_count(FIG_ROWS); tcap[ntiles] = "rows a run would change"
    } else {
        class = "bad"
        if (verdict == "PASS") class = "ok"
        else if (verdict == "REVIEW REQUIRED" || verdict == "INCOMPLETE") class = "warn"
        badge = "Done, not verified"
        if (verdict == "PASS") badge = "Done, PASS"
        else if (verdict == "REVIEW REQUIRED") badge = "Done, review required"
        else if (verdict == "INCOMPLETE") badge = "Done, incomplete"
        else if (verdict == "FAIL") badge = "Done, FAIL"
        lead = "<strong>" fmt_count(FIG_ROWS) " rows changed in " fmt_clock(workSeconds) ".</strong> Verification: " html(verdict) ". "
        if (verdict == "REVIEW REQUIRED" && REVIEW_ROWS > 0) {
            lead = lead fmt_count(REVIEW_ROWS) " client values in " REVIEW_COLUMNS " columns were left as they were, on purpose. "
        } else if (verdict == "INCOMPLETE") {
            lead = lead "Switched off: " html(switches_off()) ". "
        } else if (verdict == "FAIL") {
            lead = lead "Client data is still present where it should have been replaced. "
        }
        lead = lead "Exit code " exitCode "."
        tnum[++ntiles] = fmt_count(FIG_ROWS); tcap[ntiles] = "rows changed"
    }
    identities = 0
    for (i = 1; i <= ID_N; i++) identities += ID_FOUND[i]
    if (identities > 0) { tnum[++ntiles] = fmt_count(identities); tcap[ntiles] = "identities" }
    if (FIG_XPARTIES > 0) { tnum[++ntiles] = fmt_count(FIG_XPARTIES); tcap[ntiles] = "unclassified parties (X_)" }
    if (REVIEW_ROWS > 0) { tnum[++ntiles] = fmt_count(REVIEW_ROWS); tcap[ntiles] = "values left for review" }
    if (dry && status == "COMPLETED" && EST_SET && EST_SECONDS > 0) {
        tnum[++ntiles] = fmt_about(EST_SECONDS); tcap[ntiles] = "expected time of a run"
    }
    if (!dry && status == "COMPLETED") {
        failed = 0
        for (i = 1; i <= V_N; i++) if (V_STATUS[i] == "FAIL") failed++
        tnum[++ntiles] = failed ""; tcap[ntiles] = "checks failed"
        tnum[++ntiles] = fmt_clock(workSeconds); tcap[ntiles] = "duration of the work"
    }
    if (NOT_HERE > 0) { tnum[++ntiles] = fmt_count(NOT_HERE); tcap[ntiles] = "inventory items not in this database" }

    ncards = 0

    # What stopped a refused run.
    if (status == "REFUSED") {
        inner = ""
        for (i = 1; i <= CHK_N; i++) {
            if (CHK_STATUS[i] != "NOT_MET") continue
            inner = inner "<div class=\"stop\"><div><strong>" html(CHK_TITLE[i]) "</strong> &middot; " tolower(CHK_NEEDED[i]) \
                    " &middot; not met</div><div>" html(CHK_MEASURE[i]) "</div>"
            if (CHK_HAPPENS[i] != "") inner = inner "<div><strong>What happens:</strong> " html(CHK_HAPPENS[i]) "</div>"
            if (CHK_TODO[i] != "") inner = inner "<div><strong>What to do:</strong> " html(CHK_TODO[i]) "</div>"
            inner = inner "</div>"
        }
        if (inner != "") cards[++ncards] = card("What stopped it", inner)
    }

    # The work, done or to do.
    if (ST_N > 0) {
        rowsHead = dry ? "Rows to change" : "Rows changed"
        head = cells4("What", "Columns", rowsHead, "Of them X_")
        if (!dry) head = head SUBSEP "Time"
        num = ",1,2,3,4,"
        inner = table_start(head, num, "")
        inner = inner work_row("Free text emptied", FREE_COLUMNS, FREE_ROWS, "-", FREE_MS, dry, num)
        inner = inner work_row("Identifiers renamed", IDS_COLUMNS, IDS_ROWS, fmt_count(IDS_X), IDS_MS, dry, num)
        inner = inner work_row("Labels masked", LABELS_COLUMNS, LABELS_ROWS, "-", LABELS_MS, dry, num)
        inner = inner work_row("Attributes masked", ATTRS_COLUMNS, ATTRS_ROWS, "-", ATTRS_MS, dry, num)
        if (REVIEW_ROWS > 0) {
            text = cells4("Left as they are, for review", REVIEW_COLUMNS "", fmt_count(REVIEW_ROWS), "-")
            if (!dry) text = text SUBSEP "-"
            inner = inner table_row(text, num)
        }
        inner = inner table_end()
        title = "What was done"
        note = "Columns: those of the inventory in this database. Free text: the rows that had a value, in " FREE_TABLES \
               " tables, one statement per table. " IDS_NOCLIENT " identifier columns held no client code."
        if (dry) {
            title = "What a run would change"
            note = "Columns: those of the inventory in this database. Rows: what the count found; a run changes the same rows unless the data changes in between. Free text: the rows with a value, in " \
                   FREE_TABLES " tables."
        } else if (status != "COMPLETED") {
            title = "What was done before the run ended"
        }
        cards[++ncards] = card(title, inner "<div class=\"muted\">" note "</div>")
    }

    # The verification.
    if (!dry && V_N > 0) {
        li = ""
        verify_parts()
        for (i = 1; i <= VP_N; i++) {
            p = pill("ok", "Pass")
            text = fmt_count(VP_CHECKED[i]) " checked"
            if (VP_PART[i] == "SETTINGS") {
                if (VP_OFF[i] > 0) { p = pill("warn", "Off"); text = VP_OFF[i] " protections switched off" }
                else { p = pill("skip", "None"); text = "every switch was on" }
            } else if (VP_FAILED[i] > 0) {
                p = pill("bad", "Fail"); text = text "; " VP_FAILED[i] " failed"
            } else if (VP_REVIEW[i] > 0) {
                p = pill("warn", "Review"); text = text "; " VP_REVIEW[i] " hold values left for review"
            }
            if (VP_SKIPPED[i] > 0) text = text "; " VP_SKIPPED[i] " not in this database"
            li = li "<li>" p " <strong>" VP_NAME[i] "</strong> <span class=\"muted\">" html(text) "</span></li>"
        }
        n = 0
        for (i = 1; i <= V_N && n < 40; i++) {
            if (V_STATUS[i] != "FAIL" && V_STATUS[i] != "WARN") continue
            n++
            p = (V_STATUS[i] == "WARN") ? pill("warn", "Note") : pill("bad", "Fail")
            li = li "<li>" p " <code>" html(V_CHECK[i]) "</code> <span class=\"muted\">" html(V_DETAIL[i]) "</span></li>"
        }
        text = "<div><strong>Result: " html(verdict) ", exit code " exitCode ".</strong> <span class=\"muted\">PASS needs every protection on, no original left, and nothing left for review.</span></div>"
        cards[++ncards] = card("Verification", "<ul class=\"cmp\">" li "</ul>" text)
    }

    # What was left for review.
    if (REVIEW_N > 0) {
        inner = table_start(cells3("Column", "Rows", "Why"), ",1,", "")
        for (k = 1; k <= REVIEW_N; k++) {
            i = REVIEW_STEP[k]
            inner = inner table_row(cells3("<code>" html(ST_OBJECT[i]) "</code>", fmt_count(ST_ROWS[i]), html(ST_MESSAGE[i])), ",1,")
        }
        inner = inner table_end()
        text = "A run would leave " fmt_count(REVIEW_ROWS) " values in " REVIEW_COLUMNS " columns as they are, because their role is not settled. Its verification would say REVIEW REQUIRED (exit code 3) while they remain."
        if (!dry) text = fmt_count(REVIEW_ROWS) " client values in " REVIEW_COLUMNS " columns were left as they were, on purpose: their role is not settled. The verification says REVIEW REQUIRED (exit code 3) while they remain."
        cards[++ncards] = card("Left for review", "<div>" text "</div>" inner)
    }

    # The unclassified parties.
    if (X_N > 0) {
        inner = "<div>" fmt_count(FIG_XPARTIES) " parties: the data does not say which kind of party they are, so they get an X_ value. By reason, and by where each one was found (parties, not rows):</div>"
        inner = inner table_start("Reason" SUBSEP "Parties" SUBSEP "In tiers" SUBSEP "On a w_tiers node" SUBSEP "On another screen" SUBSEP \
                                  "Only in references" SUBSEP "Why", ",1,2,3,4,5,", "")
        for (k = 1; k <= X_N; k++) {
            i = X_ORDER[k]
            inner = inner table_row(html(X_LABEL[i]) SUBSEP fmt_count(X_PARTIES[i]) SUBSEP fmt_count(X_INTIERS[i]) SUBSEP \
                                    fmt_count(X_PARTYNODE[i]) SUBSEP fmt_count(X_OTHER[i]) SUBSEP fmt_count(X_REFS[i]) SUBSEP \
                                    html(X_WHY[i]), ",1,2,3,4,5,")
        }
        inner = inner table_end()
        if (dry) {
            inner = inner "<h3>Before the real run: fix the data, or leave them X_</h3><ul class=\"plain\">"
            for (k = 1; k <= X_N; k++) {
                i = X_ORDER[k]
                inner = inner "<li><strong>" html(X_LABEL[i]) "</strong>: " html(X_FIX[i]) "</li>"
            }
            inner = inner "</ul><h3>To list them: one query per reason</h3><div class=\"muted\">They read this dry run's plan (" run \
                    "), so run them before the next run starts. What they return is the client's codes: keep it on this machine.</div>"
            for (k = 1; k <= X_N; k++) {
                i = X_ORDER[k]
                text = ""
                for (j = 1; j <= X_SQLN[i]; j++) text = text (j > 1 ? "\n" : "") X_SQL[i, j]
                inner = inner "<div class=\"reason\"><strong>" html(X_LABEL[i]) "</strong><div class=\"q\"><button type=\"button\">Copy</button><pre>" \
                        html(text) "</pre></div></div>"
            }
        }
        if (XT_N > 0) {
            verb = dry ? "would go" : "went"
            inner = inner "<h3>Where their X_ values " verb ": " fmt_count(IDS_X) " rows in " XT_N " tables</h3>"
            top = table_start(cells3("Table", "Rows", "Columns"), ",1,2,", "")
            rest = table_start(cells3("Table", "Rows", "Columns"), ",1,2,", "")
            nrest = 0
            for (i = 1; i <= XT_N; i++) {
                text = table_row(cells3("<code>" html(XT_TABLE[i]) "</code>", fmt_count(XT_ROWS[i]), fmt_count(XT_COLUMNS[i])), ",1,2,")
                if (i <= 10) top = top text
                else { rest = rest text; nrest++ }
            }
            inner = inner top table_end()
            if (nrest > 0) inner = inner "<details class=\"more\"><summary>The other " nrest " tables</summary>" rest table_end() "</details>"
        }
        cards[++ncards] = card("Unclassified parties (X_)", inner)
    }

    # The identities.
    if (ID_N > 0) {
        newHead = "New translations"
        if (!dry && status == "COMPLETED") newHead = "New translations recorded"
        inner = table_start(cells5("Category", "Found", newHead, "Reused", "Notes"), ",1,2,3,", "")
        for (i = 1; i <= ID_N; i++) {
            note = ""
            if (ID_CAT[i] == "UNCLASSIFIED_PARTY" && ID_FOUND[i] > 0) note = "by reason under \"Unclassified parties\""
            if (ID_CAT[i] == "BANK_ACCOUNT" && ACC_SET) {
                note = fmt_count(ACC_MASTER) " in compte_banque only, " fmt_count(ACC_BOTH) " also on the structure, " \
                       fmt_count(ACC_STRUCTURE) " only on the structure"
                if (ACC_REFERENCE > 0) note = note ", " fmt_count(ACC_REFERENCE) " only in references"
            }
            inner = inner table_row(cells5(CATEGORY_NAME[ID_CAT[i]], fmt_count(ID_FOUND[i]), fmt_count(ID_NEW[i]), fmt_count(ID_REUSED[i]),
                                           html(note)), ",1,2,3,")
        }
        inner = inner table_end()
        notes = ""
        if (IDN_SET) {
            if (IDN_SAME > 0) notes = notes (notes != "" ? " " : "") fmt_plural(IDN_SAME, "text is", "texts are") \
                                      " both a party and a bank account: each keeps its own translation."
            if (IDN_PRECEDENCE > 0) notes = notes (notes != "" ? " " : "") fmt_plural(IDN_PRECEDENCE, "party has", "parties have") \
                                            " an Entite node and another w_tiers node: one E_ value."
            if (IDN_DRIFT > 0) notes = notes (notes != "" ? " " : "") fmt_plural(IDN_DRIFT, "identity", "identities") \
                                       " would be classified differently today: the recorded translation is kept."
            if (IDN_SUPERSEDED > 0) notes = notes (notes != "" ? " " : "") fmt_plural(IDN_SUPERSEDED, "earlier translation is", "earlier translations are") \
                                            " superseded: kept, never used."
        }
        cards[++ncards] = card("Identities", inner "<div class=\"muted\">" notes "</div>")
    }

    # The checks.
    if (CHK_N > 0) {
        li = ""
        for (i = 1; i <= CHK_N; i++) {
            p = pill("ok", "Met")
            if (CHK_STATUS[i] == "NOT_MET" && CHK_NEEDED[i] == "REQUIRED") p = pill("bad", "Not met")
            else if (CHK_STATUS[i] == "NOT_MET") p = pill("warn", "Not met")
            else if (CHK_STATUS[i] == "NOTE" && CHK_NEEDED[i] == "OPTIONAL") p = pill("warn", "Not here")
            else if (CHK_STATUS[i] == "NOTE") p = pill("skip", "Info")
            else if (CHK_NEEDED[i] == "INFO") p = pill("skip", "None")
            li = li "<li>" p " <strong>" html(CHK_TITLE[i]) "</strong> <span class=\"muted\">" tolower(CHK_NEEDED[i]) \
                 " &middot; " html(CHK_MEASURE[i]) "</span></li>"
        }
        cards[++ncards] = card("Checks", "<ul class=\"cmp\">" li "</ul><div class=\"muted\">Made before anything is changed. A required check that is not met stops the run there, before the question to start it.</div>")
    }

    # The switches.
    if (SET_N > 0) {
        word["Y"] = "yes"; word["N"] = "<strong>no</strong>"
        inner = table_start(cells4("Category", "Rename codes", "Labels", "Attributes"), "", "")
        for (i = 1; i <= SET_N; i++) {
            inner = inner table_row(cells4(CATEGORY_NAME[SET_CAT[i]], word[toupper(SET_ID[i])], word[toupper(SET_DESC[i])],
                                           word[toupper(SET_ATTR[i])]), "")
        }
        inner = inner table_row(cells4("Free text", "always emptied", "", ""), "") table_end()
        options = "APPROVE_STRUCTURE_ONLY_ACCOUNTS=" m["approve_structure_only_accounts"] ", PARALLEL_DEGREE=" m["parallel_degree"] \
                  ", FAIL_ON_MISSING_OBJECT=" m["fail_on_missing_object"] ", CUSTOM_INVENTORY=" m["custom_inventory"] \
                  " (" m["inventory_site"] " items)"
        cards[++ncards] = card("Switches", inner "<div class=\"muted\">From " CONFIG_TEXT ". Also: " html(options) ".</div>")
    }

    # The duration of each step.
    names["READY"] = "Getting ready"; names["CHECK"] = "Checking and planning"; names["COUNT"] = "Counting"
    names["RECORD"] = "Recording the translations"; names["APPLY"] = "Anonymizing"; names["VERIFY"] = "Verifying"
    nbars = 0
    for (i = 1; i <= nsteps; i++) {
        if (skey[i] == "COUNT" || skey[i] == "APPLY") {
            verb = (skey[i] == "COUNT") ? "Counting: " : ""
            blabel[++nbars] = (verb == "") ? "Free text" : verb "free text"; bsec[nbars] = FREE_MS / 1000
            blabel[++nbars] = (verb == "") ? "Identifiers" : verb "identifiers"; bsec[nbars] = IDS_MS / 1000
            blabel[++nbars] = (verb == "") ? "Labels and attributes" : verb "labels and attributes"; bsec[nbars] = (LABELS_MS + ATTRS_MS) / 1000
            continue
        }
        label = (skey[i] in names) ? names[skey[i]] : ""
        if (sstat[i] != "DONE") label = label " (" tolower(sstat[i]) ")"
        blabel[++nbars] = label; bsec[nbars] = ssec[i]
    }
    if (nbars > 0) {
        max = 0
        for (i = 1; i <= nbars; i++) if (bsec[i] > max) max = bsec[i]
        inner = ""
        for (i = 1; i <= nbars; i++) inner = inner bar(blabel[i], bsec[i], max)
        note = ""
        if (dry && EST_SET) {
            note = "The estimate for a run: the planning this dry run took, the rows to change at "
            if (toupper(EST_BASIS) ~ /^R-/) note = note "the speed of " EST_BASIS " on this database"; else note = note "a default rate"
            note = note ", and one more pass for the verification."
        } else if (!dry) {
            note = "The work of each kind is the time of its statements. The wait for YES is not counted."
        }
        cards[++ncards] = card("Duration by step", inner "<div class=\"muted\">" html(note) "</div>")
    }

    # What to know, and what comes next.
    good_to_know(dry)
    if (GK_N > 0) {
        inner = "<ul class=\"plain\">"
        for (i = 1; i <= GK_N; i++) inner = inner "<li>" html(GK[i]) "</li>"
        cards[++ncards] = card("Good to know", inner "</ul>")
    }
    ntodo = 0
    if (status == "REFUSED") {
        for (i = 1; i <= CHK_N; i++) if (CHK_STATUS[i] == "NOT_MET" && CHK_TODO[i] != "") todo[++ntodo] = html(CHK_TODO[i])
        todo[++ntodo] = "Then a dry run: <code>" LAUNCHER " " OPTION "dryrun</code>."
    } else if (status == "CANCELLED") {
        todo[++ntodo] = "<code>" LAUNCHER "</code> asks again, after the same checks."
    } else if (status == "FAILED") {
        todo[++ntodo] = "report.txt (below) has the full output. Once the cause is removed, the same command resumes: the translations recorded so far are kept."
    } else if (status == "STOPPED") {
        todo[++ntodo] = "The same command resumes from here, with the same translations: <code>" LAUNCHER "</code>."
    } else if (dry) {
        todo[++ntodo] = "The run itself: <code>" LAUNCHER "</code>. It checks again, shows what it will change, then asks for YES."
    } else if (verdict == "PASS") {
        todo[++ntodo] = "Keep this folder with the copy: report.html, verify.txt and manifest.txt say what was done to it."
    } else if (verdict == "REVIEW REQUIRED") {
        todo[++ntodo] = "Decide on what was left for review (above). A new run on this data keeps every translation."
        todo[++ntodo] = "Keep this folder with the copy: report.html, verify.txt and manifest.txt say what was done to it."
    } else if (verdict == "INCOMPLETE") {
        todo[++ntodo] = "To complete it, switch the protections on in " CONFIG_TEXT " and run again: the translations are kept."
    } else {
        todo[++ntodo] = "Do not hand over this copy: the verification names the columns that still hold client data."
    }
    inner = "<ul class=\"plain\">"
    for (i = 1; i <= ntodo; i++) inner = inner "<li>" todo[i] "</li>"
    cards[++ncards] = card("Next", inner "</ul>")

    # Folded: every column, what is not here, the text outputs.
    here = 0
    for (i = 1; i <= IT_N; i++) if (IT_STATE[i] == "HERE") here++
    if (here > 0 && ST_N > 0) {
        whatOf["CODE"] = "identifier"; whatOf["NULL_OUT"] = "free text"; whatOf["DESCRIPTION"] = "label"; whatOf["SELF_CODE"] = "attribute"
        num = dry ? ",0,3,4," : ",0,3,4,5,"
        if (dry) head = "#" SUBSEP "Column" SUBSEP "What it is" SUBSEP "Rows to change" SUBSEP "X_" SUBSEP "A run would"
        else head = "#" SUBSEP "Column" SUBSEP "What it is" SUBSEP "Rows changed" SUBSEP "X_" SUBSEP "Time" SUBSEP "Verification"
        inner = ""
        for (i = 1; i <= IT_N; i++) {
            if (IT_STATE[i] != "HERE") continue
            column_figures(i)
            holds = ""
            if (IT_CATEGORY[i] != "NONE") { holds = ", " tolower(IT_CATEGORY[i]); gsub(/_/, " ", holds) }
            cfrows = fmt_count(CF_ROWS)
            if (CF_SHARED) cfrows = cfrows " <span class=\"muted\">(its table)</span>"
            if (IT_RULE[i] == "NULL_OUT" && CF_NSTATUSES == 0) cfrows = "<span class=\"muted\">-</span>"
            st = ""
            if (CF_REVIEW > 0) st = "<span class=\"st warn\">review " fmt_count(CF_REVIEW) "</span>"
            else if (index(CF_STATUSES, ",DISABLED,") > 0) st = "<span class=\"st skip\">switched off</span>"
            else if (dry) {
                if (CF_ROWS > 0) st = "<span class=\"st ok\">change</span>"
                else if (IT_RULE[i] == "CODE") st = "<span class=\"st skip\">no client code</span>"
                else st = "<span class=\"st skip\">nothing to do</span>"
            } else {
                t = toupper(CF_CHECK)
                if (t == "PASS") st = "<span class=\"st ok\">pass</span>"
                else if (t == "FAIL") st = "<span class=\"st bad\">fail</span>"
                else if (t == "REVIEW") st = "<span class=\"st warn\">review</span>"
                else if (t == "DISABLED") st = "<span class=\"st skip\">switched off</span>"
                else if (t == "WARN") st = "<span class=\"st warn\">note</span>"
                else st = "<span class=\"st skip\">-</span>"
            }
            x = ""
            if (CF_X > 0) x = fmt_count(CF_X)
            text = IT_SEQ[i] SUBSEP "<code>" html(IT_TABLE[i] "." IT_COLUMN[i]) "</code>" SUBSEP \
                   ((IT_RULE[i] in whatOf) ? whatOf[IT_RULE[i]] : "") html(holds) SUBSEP cfrows SUBSEP x
            if (!dry) text = text SUBSEP fmt_clock(CF_MS / 1000)
            inner = inner table_row(text SUBSEP st, num)
        }
        inner = "<label class=\"muted\" for=\"filter\">Filter by table, column or word</label>" \
                "<input id=\"filter\" class=\"filter\" type=\"search\" placeholder=\"histo_operation, review, attribute...\">" \
                "<div class=\"muted\"><span id=\"shown\">" here "</span> shown. Free text, labels and attributes are changed by one statement per table: a column marked \"its table\" shows the rows of that statement.</div>" \
                table_start(head, num, "cols") inner table_end()
        cards[++ncards] = folded("Every column of the inventory in this database (" here ")", inner)
    }
    nabsent = 0
    n = 0
    for (i = 1; i <= IT_N; i++) {
        if (IT_STATE[i] == "HERE") continue
        nabsent++
        k = IT_TABLE[i]
        w = "table not in this database"
        if (IT_STATE[i] == "NO_COLUMN") { k = IT_TABLE[i] "." IT_COLUMN[i]; w = "column not in this database" }
        if (!(tolower(k) in aitems)) { order[++n] = k; aitems[tolower(k)] = 0; awhy[tolower(k)] = w }
        aitems[tolower(k)]++
    }
    if (nabsent > 0) {
        # The names in the order Windows sorts them.
        for (i = 2; i <= n; i++) {
            for (j = i; j > 1 && name_key(order[j - 1]) > name_key(order[j]); j--) { t = order[j]; order[j] = order[j - 1]; order[j - 1] = t }
        }
        inner = "<div class=\"muted\">" TABLES_NOT_HERE " tables and " COLUMNS_NOT_HERE " columns of the inventory. Skipped, because FAIL_ON_MISSING_OBJECT=" \
                m["fail_on_missing_object"] ". A module this database does not have is the usual reason.</div>" \
                table_start(cells3("Table or column", "Items", "Why"), ",1,", "")
        for (i = 1; i <= n; i++) {
            inner = inner table_row(cells3("<code>" html(order[i]) "</code>", aitems[tolower(order[i])] "", awhy[tolower(order[i])]), ",1,")
        }
        cards[++ncards] = folded("Not in this database (" nabsent " items)", inner table_end())
    }
    if (verifyText != "") cards[++ncards] = folded("Verification output (verify.txt)", "<pre>" html(verifyText) "</pre>")
    if (reportText != "") cards[++ncards] = folded("Full text report (report.txt)", "<pre>" html(reportText) "</pre>")

    css = ":root{--bg:#f4f6f9;--card:#fff;--fg:#182131;--muted:#5a6577;--line:#d9dfe8;--accent:#2c5aa0;--ok:#1d7444;--oks:#e2f2e8;--warn:#8f5b00;--warns:#faefd9;--bad:#b42318;--bads:#fbe7e5;--track:#e6eaf0;--code:#eef1f6;color-scheme:light}\n" \
          "@media (prefers-color-scheme:dark){:root:not([data-theme=\"light\"]){--bg:#0e131a;--card:#151c26;--fg:#e3e8ef;--muted:#98a3b5;--line:#273245;--accent:#8aaee8;--ok:#63cc90;--oks:#13301f;--warn:#e8b85e;--warns:#33270f;--bad:#f3897e;--bads:#3a1916;--track:#232c3b;--code:#1b2431;color-scheme:dark}}\n" \
          ":root[data-theme=\"dark\"]{--bg:#0e131a;--card:#151c26;--fg:#e3e8ef;--muted:#98a3b5;--line:#273245;--accent:#8aaee8;--ok:#63cc90;--oks:#13301f;--warn:#e8b85e;--warns:#33270f;--bad:#f3897e;--bads:#3a1916;--track:#232c3b;--code:#1b2431;color-scheme:dark}\n" \
          "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 \"Segoe UI\",system-ui,-apple-system,sans-serif}\n" \
          ".wrap{max-width:1000px;margin:0 auto;padding:28px 20px 60px;display:grid;gap:18px}\n" \
          ".head{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;align-items:flex-end}\n" \
          ".kicker{font-size:.8rem;color:var(--muted);letter-spacing:.05em;text-transform:uppercase}h1{margin:0;font-size:1.7rem}\n" \
          ".when{color:var(--muted);text-align:right;font-size:.92rem}\n" \
          ".verdict{display:flex;gap:14px;align-items:center;border-radius:12px;padding:16px 18px}\n" \
          ".verdict.ok{background:var(--oks)}.verdict.warn{background:var(--warns)}.verdict.bad{background:var(--bads)}\n" \
          ".badge{flex:none;color:var(--card);font-weight:800;border-radius:999px;padding:4px 16px}\n" \
          ".ok .badge{background:var(--ok)}.warn .badge{background:var(--warn)}.bad .badge{background:var(--bad)}\n" \
          ".tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}\n" \
          ".tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;min-width:0}\n" \
          ".num{font-size:1.3rem;font-weight:800;font-variant-numeric:tabular-nums;white-space:nowrap}.cap{color:var(--muted);font-size:.88rem}\n" \
          ".card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;display:grid;gap:10px;min-width:0}\n" \
          "h2{margin:0;font-size:1.05rem}h3{margin:6px 0 0;font-size:.95rem}\n" \
          ".bar{display:grid;grid-template-columns:minmax(120px,18rem) 1fr 7rem;gap:10px;align-items:center;font-size:.93rem}\n" \
          ".track{background:var(--track);border-radius:4px;height:14px;overflow:hidden;display:block}.fill{display:block;height:100%;border-radius:4px;background:var(--accent)}\n" \
          ".bv{text-align:right;font-variant-numeric:tabular-nums}\n" \
          "ul.cmp{list-style:none;margin:0;padding:0;display:grid;gap:7px}\n" \
          ".pill{display:inline-block;min-width:4.6em;text-align:center;border-radius:999px;padding:1px 10px;font-size:.8rem;font-weight:700}\n" \
          ".pill.ok{background:var(--oks);color:var(--ok)}.pill.warn{background:var(--warns);color:var(--warn)}.pill.bad{background:var(--bads);color:var(--bad)}.pill.skip{background:var(--track);color:var(--muted)}\n" \
          ".muted{color:var(--muted)}table{border-collapse:collapse;width:100%;font-size:.93rem}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}\n" \
          "th{font-weight:600}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}.tw{overflow-x:auto}\n" \
          "code{font-family:Consolas,\"Cascadia Mono\",monospace;font-size:.9em}\n" \
          "ul.plain{margin:0;padding-left:1.2em;display:grid;gap:6px}\n" \
          "pre{margin:0;overflow-x:auto;font:12.5px/1.4 Consolas,\"Cascadia Mono\",monospace;background:var(--code);border-radius:8px;padding:12px}\n" \
          "summary{cursor:pointer;font-weight:600}summary:focus-visible,button:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px}\n" \
          ".foot{color:var(--muted);font-size:.88rem}\n" \
          ".q{position:relative}.q button{position:absolute;top:8px;right:8px;font:600 .78rem \"Segoe UI\",system-ui,sans-serif;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:6px;padding:3px 10px;cursor:pointer}\n" \
          ".reason{display:grid;gap:6px;padding-top:10px;border-top:1px solid var(--line)}\n" \
          ".stop{background:var(--bads);border-radius:10px;padding:12px 14px;display:grid;gap:6px}\n" \
          ".filter{width:100%;max-width:360px;padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg);font:inherit}\n" \
          ".st{font-size:.78rem;font-weight:700;border-radius:999px;padding:0 8px;white-space:nowrap}\n" \
          ".st.ok{background:var(--oks);color:var(--ok)}.st.warn{background:var(--warns);color:var(--warn)}.st.bad{background:var(--bads);color:var(--bad)}.st.skip{background:var(--track);color:var(--muted)}\n" \
          "details.more{display:grid;gap:10px}details.more[open]>summary{margin-bottom:10px}\n" \
          "@media (max-width:560px){.bar{grid-template-columns:1fr 5.5rem}.bar .bl{grid-column:1/-1}.when{text-align:left}}\n" \
          "@media print{body{background:#fff}.card,.tile{break-inside:avoid}details{display:none}}"
    js = "document.querySelectorAll('.q button').forEach(function (b) {\n" \
         "  b.addEventListener('click', function () {\n" \
         "    var pre = b.parentNode.querySelector('pre');\n" \
         "    var done = function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); };\n" \
         "    try { navigator.clipboard.writeText(pre.textContent).then(done, function () { select(pre); }); } catch (e) { select(pre); }\n" \
         "  });\n" \
         "});\n" \
         "function select(el) { var r = document.createRange(); r.selectNodeContents(el); var s = getSelection(); s.removeAllRanges(); s.addRange(r); }\n" \
         "var f = document.getElementById('filter');\n" \
         "if (f) f.addEventListener('input', function () {\n" \
         "  var v = f.value.trim().toLowerCase(), shown = 0;\n" \
         "  document.querySelectorAll('#cols tbody tr').forEach(function (tr) {\n" \
         "    var on = !v || tr.textContent.toLowerCase().indexOf(v) >= 0;\n" \
         "    tr.hidden = !on; if (on) shown++;\n" \
         "  });\n" \
         "  document.getElementById('shown').textContent = shown;\n" \
         "});"
    files = "report.html, report.txt (what the engine printed), "
    if (verifyText != "") files = files "verify.txt (what the verification printed), "
    files = files "console.log (every line of the run), results.txt (the figures of this report), manifest.txt, inventory.sql."
    database = m["database"]
    if (RUN_SET && RUN_DATABASE != "") database = RUN_DATABASE

    page = folder "/report.html"
    printf "%s", "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" > page
    printf "%s", "<title>OP Anonymization " html(run) "</title><style>" css "</style></head><body><div class=\"wrap\">" > page
    printf "%s", "<div class=\"head\"><div><div class=\"kicker\">OP Anonymization " html(m["tool_version"]) " &middot; " kind \
                 "</div><h1>" html(database) " &middot; run " html(run) "</h1></div><div class=\"when\">" when "</div></div>" > page
    printf "%s", "<div class=\"verdict " class "\"><span class=\"badge\">" html(badge) "</span><div>" lead "</div></div>" > page
    if (ntiles > 0) {
        printf "%s", "<div class=\"tiles\">" > page
        for (i = 1; i <= ntiles; i++) printf "%s", "<div class=\"tile\"><div class=\"num\">" html(tnum[i]) "</div><div class=\"cap\">" html(tcap[i]) "</div></div>" > page
        printf "%s", "</div>" > page
    }
    for (i = 1; i <= ncards; i++) printf "%s", cards[i] > page
    printf "%s", "<div class=\"foot\">Files of this run, in the same folder: " files "</div>" > page
    printf "%s", "</div><script>" js "</script></body></html>" > page
    close(page)
    return 0
}

function work_row(what, columns, rows, x, ms, dry, num,   text) {
    text = what SUBSEP columns SUBSEP fmt_count(rows) SUBSEP x
    if (!dry) text = text SUBSEP fmt_clock(ms / 1000)
    return table_row(text, num)
}
