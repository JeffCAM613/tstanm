# 17 - Version 0.5.0: the live output, report.html, and a clean release

> **For you, before your runs on the client copy.** What 0.5.0 is, where it follows plan 15 and
> where it differs, what was cleaned for the client's IT, how it was tested, and what to look at
> first on the client copy. Counts only: no client name or code appears here.

| | |
|---|---|
| Asked | The rework of plan 15 (`15_live_output_plan.md`) as version 0.5.0, and code that reads well when the client's IT reviews it |
| Decisions | Plan 15, section 8, recommendations taken: PowerShell wrapper; YES after the checks; `generate_report.sql` retired; exit code 5 for Ctrl+C; switches asked only when blank. The version label is 0.5.0, not "4.1" |
| Code | Working tree, not committed |
| Tested | Regression suite S0-S22 on the Docker sandbox; the real wrapper end to end through a relay sqlplus - section 6 |
| Not yet | A Windows sqlplus (the host has no Oracle client), and the client copy |

## Contents

1. [In short](#1-in-short)
2. [What changed, file by file](#2-what-changed-file-by-file)
3. [Where it differs from plan 15](#3-where-it-differs-from-plan-15)
4. [The engine: additions only](#4-the-engine-additions-only)
5. [Cleaned for the client's IT](#5-cleaned-for-the-clients-it)
6. [How it is tested](#6-how-it-is-tested)
7. [Not tested here - look at these first on the client copy](#7-not-tested-here---look-at-these-first-on-the-client-copy)
8. [Open points](#8-open-points)

---

## 1. In short

- **The same command**, `op\run_op_anonymization.bat`, now starts a PowerShell wrapper
  (`op\lib\anon.ps1`). It gets ready by itself (sqlplus, configuration, SYS and OP, ANON_META, the
  engine, the inventory - one line each), asks only what the configuration leaves blank (passwords
  masked), shows the switches as a table, then the steps with their times.
- **Live**: the engine runs in one sqlplus session; a second one reads its progress every 2 s. One
  live line per kind of work - free text, identifiers, labels and attributes - with a bar weighed
  by table rows, the table or column worked on with its long-statement percentage
  (`v$session_longops`), the rows so far and the time left.
- **The checks as a table**, by name, met or not, with what was measured and - for one not met -
  what happens and what to do. YES is asked **after** them; a refused run never asks.
- **Every run leaves a folder** `op\logs\<date>_<time>_R-<run>\` with `report.html` (opened at the
  end), `report.txt`, `verify.txt`, `console.log`, `results.txt`, `manifest.txt`, `inventory.sql`.
- **Ctrl+C** stops the run between two columns, enables the triggers again, exit code 5. A new run
  resumes (S17).
- **Passwords** reach sqlplus on its standard input only (they were on its command line).
- **Nothing in how identities are classified, translated, written or verified changed.**

## 2. What changed, file by file

| File | |
|---|---|
| `op\run_op_anonymization.bat` | Now the launcher: 16 lines, starts `lib\anon.ps1`, returns its exit code. The old 728-line batch logic moved to PowerShell |
| `op\lib\anon.ps1` | New. Command line, configuration, questions, sqlplus sessions, the run's steps, run folder, manifest, exit code |
| `op\lib\anon_screen.ps1` | New. Formats, steps, live lines, checks table, results parser, the end screens |
| `op\lib\anon_html.ps1` | New. `report.html`, from the run folder's files |
| `op\sql\run\*.sql` | New entry scripts (13): `session`, `engine`, `inventory`, `start`, `plan`, `count`, `record`, `apply`, `finish`, `poll`, `stop`, `results`, `recover` |
| `op\sql\10_create_metadata_schema.sql` | New objects and migrations (section 4); grants on `v_$session`, `v_$session_longops` |
| `op\sql\30_install_engine.sql` | Additions (section 4); comments reworded |
| `op\sql\00_run_op_anonymization.sql` | Kept for sqlplus without the wrapper and for the suite; REFUSED and STOPPED statuses |
| `op\verify\generate_report.sql` | **Retired** (deleted) |
| `config\*` | Comments and notes reworded (section 5); data rows and column options unchanged - checked |
| `docs\*` | Both guides rewritten for 0.5.0; HTML and DOCX rebuilt |
| `README.md`, `tests\README.md`, `tools\*` | Reworded; `make_release.ps1` ships the new files and names the zip after the engine's version |
| `tests\regression\run_regression.sh` | S13 and S19 extended, S22 new (section 6) |

## 3. Where it differs from plan 15

| Plan 15 | 0.5.0 | Why |
|---|---|---|
| "OP Anonymization 4.1" | **0.5.0**, from `anon_engine.c_version` - on the screen, in `anon_run.tool_version`, in the report, in the zip's name | Your choice |
| `prepare.sql` (SYS) | SYS runs `10_create_metadata_schema.sql` directly | Nothing to add around it |
| Entry scripts: prepare, plan, count, apply, poll, results, stop | Also `session` (the connection test), `engine` (valid + version), `inventory` (counts), `start` (separate from plan, so the run id is known before the checks and the folder exists while they run), `record` (the translations, step 2 of 4), `finish` (CANCELLED / STOPPED between steps), `recover` | Each step of the screen is one command, read up to its end marker |
| Questions: the switches when blank, "as today" | The same; the run-behaviour settings (`PARALLEL_DEGREE`, `CUSTOM_INVENTORY`, `FAIL_ON_MISSING_OBJECT`) take their defaults without asking; `TABLESPACE_INDEX` defaults to the data tablespace. No more "Load config? [Y/n]" | Fewer questions; all shown in the report |
| Live line: "the tables or columns done of the total" | Counted on what is **in this database** (absent items are logged SKIPPED, instantly); labels and attributes counted by column; the bar weighed by table rows | "12 of 93 tables" would count tables that are not there |
| Stop error code | `ORA-20018` (stopped), `ORA-20019` (nothing to stop) | `-20040` is used by `tools\generate_coverage_doc.sql` |
| Inventory load: the batch stripped apostrophes from notes | Kept, doubled in SQL. Otherwise the SQL is identical to the batch's (diffed) | Correct quoting |
| Time estimate from the speed measured on one client copy | From the last completed run on this database (rows per second of work) when there is one; otherwise the dry run's own scans plus 25,000 rows a second; plus one pass for the verification | The client copies' speed is not shipped |
| Verification "could not run" | Exit code 2 (not verified is not a pass) - as the batch did | Unchanged behaviour |

## 4. The engine: additions only

| Object | |
|---|---|
| `anon_meta.anon_progress` | One row per run: phase, stage in words, items done/total, object, the same weighed by rows |
| `anon_meta.anon_check` | The eight checks of each run |
| `anon_meta.anon_step_log.step_id` | From `seq_step_log`; the monitor reads only new rows |
| `anon_meta.anon_run` | `tool_version`, `stop_requested`; statuses REFUSED, CANCELLED, STOPPED (constraint migrated in place) |
| `anon_meta.unclassified_reason.brief` | The reason in one line |
| `anon_engine` | `c_version`, `tool_version`, `request_stop`, `estimate`; `progress`, `record_check`, `check_stop` (private); module `ANON R-000001` via `DBMS_APPLICATION_INFO` |

The checks record what preflight already decided: the `block()` messages, the refusal codes and
the step log are as before (the suite's S3, S9, S10, S12, S14 still grep them).

## 5. Cleaned for the client's IT

Everything in the release zip was read for: client database names, internal version history (v2,
v3, "v4 before this"), dates of decisions, references to working notes, plan items and test logs,
and "the vendor package" / "legacy". Rewritten in neutral, present-tense wording - what the code
does and why - not how it got there. The inventory CSVs' rows, rules, categories and column options
are unchanged (diffed); only comments and notes changed. The site CSV's "transferred / pending review
/ was Ent1" history became a plain description of the personal-attribute columns. The release is
re-scanned in section 6.

The code itself was also checked for leftovers: no function is unused, and a parser-based check
finds no unused parameter or variable in the three PowerShell files. The exit-code names say what
they mean (`ExitError` 1, `ExitVerifyFail` 2 - they were `ExitFailed` and `ExitFail`).
`anon_meta.identity_plan.parent_role`, a column nothing read or wrote, is no longer created; an
existing ANON_META keeps it, unused.

## 6. How it is tested

**Regression suite** (`tests/regression/run_regression.sh`, Docker Oracle 21c XE, fictional data):
S0-S21 as before, with three changes: S13 also checks the new objects are migrated into an older
ANON_META; S14 looks for the validation message's new wording; S19 checks `results.sql` and a
`report.html` built from it by the wrapper's own `anon_html.ps1` (the retired `generate_report.sql`
was tested there before). **S22** is new: the entry scripts driven
in one session as the wrapper drives them - session, engine, inventory, start, plan (8 checks,
identities, scope), count; the run's version and status; every check recorded, the required ones
met; every log row numbered once; the progress row ends DONE; `poll.sql` returns the rows, the
progress and the state, and nothing more once caught up; `results.sql` and `report.html` of the dry
run with no identifier; then `stop.sql` before `apply.sql` (STOPPED between two columns, nothing
changed, translations recorded), a new run resumes and verifies PASS with the same translations;
`finish.sql` CANCELLED; a run whose session is lost stays RUNNING and `recover.sql` ends it
FAILED; a copy anonymized before is REFUSED with its check NOT_MET.
Result on the final code: **681 checks passed, 0 failed** (S0-S22).

**The real wrapper, end to end** - `run_op_anonymization.bat` itself, in `cmd.exe`, through a relay
`sqlplus.exe` that forwards to the container's sqlplus (the host has no Oracle client); output
redirected to a file, so the status line is written once a minute instead of rewritten in place:

| Scenario | Exit | Seen |
|---|---|---|
| Dry run (`/dryrun /auto`) | 0 | getting ready, checks table, three live lines, the end, report.html |
| Run (`/auto /force`) | 0 | banner, translations, triggers, live lines, verification PASS |
| The same run again | 0 | nothing changed (0 rows), PASS - it resumes |
| A copy anonymized before | 1 | NOT STARTED, the check with what happens and what to do |
| The review fixture | 3 | REVIEW REQUIRED, the values left for review by column |
| `ANONYMIZE_ENTITY=n` | 4 | the switch table in yellow, INCOMPLETE |
| 1.5 million rows, a full run | 0 | the live lines with long-statement percentages and time left; PASS, 7.5 million rows |
| 600,000 rows, `stop.sql` during the identifiers | 5 | STOPPED between two columns, labels not run, the triggers enabled again |
| Interactive: passwords and YES typed | 0 | masked prompts, `/verbose` lines, PASS |
| Interactive: "no" at YES | 1 | CANCELLED, nothing changed |
| A wrong OP password (`/auto`) | 1 | one line naming the error, nothing changed |
| No sqlplus | 1 | one line, before anything else |
| `/inventory <file>`, `/help` | 0 | the same INSERT statements as the old batch (apostrophes in notes now kept) |

After the last cleanup, a dry run and a run once more, on an ANON_META created from nothing: exit
codes 0 and 0, both runs recorded with version 0.5.0, each run folder holding the seven files of
section 1.

`report.html` was checked in a browser (headless Edge) for a dry run, a run and a stopped run.
`tools\make_release.ps1` builds `Anonymization_v4_0.5.0.zip` (44 files) from the final tree; its
contents were scanned for client database names, internal history, working-note references and
credentials - none.

Two bugs found by these runs, fixed: in PowerShell, `[Math]::Min(1, 0.43)` picks the integer
overload and returns 0 (the bars read 0% at 44%); and the "triggers enabled again" row, which the
engine also writes on a stop, was taken as the end of the work.

## 7. Not tested here - look at these first on the client copy

1. **A Windows sqlplus.** Everything here went through the relay. Watch the `@"<path>"` lines with
   spaces in the path, and the Oracle messages in another language (NLS_LANG): the wrapper reads
   `ORA-` codes, not texts.
2. **A real console.** The status line rewritten in place (`` `r ``), Ctrl+C read as a key during the
   work, masked password typing, colours, the browser opening at the end. Only redirected output
   was tested here.
3. **The time estimate** on the client's volumes (the first dry run there uses the default rate; a
   dry run after a completed run uses that run's speed).
4. **`v$session_longops`** on the client's 19c with PARALLEL DML: the long-statement percentage of a
   parallel UPDATE comes from its parallel servers (`qcsid`).

## 8. Open points

- **Triggers** (pre-existing): a run disables every trigger of OP and enables every trigger at its
  end - including one the client had disabled before the run. Recording which were enabled at the
  start and enabling only those would fix it; not done, because it changes the engine's behaviour
  outside this rework. Say if you want it.
- `recover.sql` follows the same rule, but only when the run itself had disabled the triggers.
- The Finastra-template documents (user guide, scenarios, references) - after your runs.
- The plan 15 sections that are wording only (screens, report sections) follow the demo; where the
  real data said something better, the wording follows the data.
