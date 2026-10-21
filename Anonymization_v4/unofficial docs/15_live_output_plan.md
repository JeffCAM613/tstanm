# 15 - Rework plan: live output and report.html, as in db-purge

2026-10-20. For you, before anything is built. The demo shows the screens and the reports this plan
produces, for a dry run, a run and a refused run: see the link in the reply that came with this file.

## In short

- **Asked.** While you test v4 on the client's test data: the same live output as db-purge, and
  its result HTML, for the dry run too.
- **What you see.** The same command and the same configuration file. The run gets ready by itself
  and asks only what the configuration file does not say. It shows each step with its time and one
  live line for each kind of work, then the result in one sentence, the figures, what to know and
  the next command. Every run, dry runs included, leaves a folder with `report.html`,
  `report.txt` and `console.log`.
- **What does not change.** What is anonymized, and how. The engine gets small additions so that
  it can be watched: progress, and the checks recorded by name. Every rule stays as it is. Q1-Q4 of
  `14_open_questions.txt` are a separate matter.
- **How.** As in db-purge: `run_op_anonymization.bat` starts a PowerShell wrapper. The engine runs
  in one sqlplus session, and a second session reads its progress every 2 seconds. The wrapper
  writes the screen, then `report.html`.

## 1. What gets in the way today, on the client's data

1. **Nothing shows while the work runs.** The engine's lines appear only when a whole PL/SQL block
   ends. The anonymization is one block: about 30 minutes on TANM7881 (1,757 s) with a still
   screen. To watch it you need a second session with `monitor_op_progress.sql`.
2. **The answer is buried.** A dry run prints about 430 lines, one per column, most of them
   "0 rows would change". The X_ parties and the values left for review sit between them.
3. **A dry run leaves no report.** `logs\report_<time>.html` is written only after a real run, and
   covers only the verification.
4. **YES is asked before the checks.** A run the checks refuse (EPFPG785, already anonymized)
   still asks for YES, then fails with ORA-20011 and a query to run.
5. **The end is a list of counters.** A refusal or a failure ends on an Oracle error.
6. **The passwords are on sqlplus's command line**, visible in the process list to anyone on the
   machine.
7. **Closing the window during a run leaves OP's triggers disabled.** The handler that enables
   them again runs only when Oracle raises an error.
8. **The files are scattered:** `logs\op_anon_<time>.log`, `logs\report_<time>.html`, and the
   inventory SQL in `%TEMP%`.

## 2. The screens

The demo has all of them. They follow db-purge's rules: plain words, steps named by what they do,
a `-- Title ---` divider before each question, prompts marked `>` with the default in brackets,
and one sentence before the figures.

### 2.1 Getting ready

Before anything else, each with one line: sqlplus found, the configuration file read, the database
reached as SYS and as OP, ANON_META created or upgraded when needed, the engine installed, the
inventory loaded (`575 items (559 shipped, 16 of this site): 428 in this database, 147 not
here`). A missing sqlplus, a wrong alias or a wrong password is a line on this screen, not an
Oracle error later.

### 2.2 Questions

Only what the configuration file does not say: the database, the passwords (masked, never on a
command line), and any switch left blank (asked one by one with the columns it covers, as today).
The switches are then shown as one table, with "Every switch is on: a full anonymization", or
which protections are off and that the result will be INCOMPLETE. `/auto` asks nothing, as today.
With `/auto` the passwords come from the environment (`ANON_SYS_PASSWORD`, `ANON_OP_PASSWORD`) or
from the configuration file.

### 2.3 Steps

| Dry run | Run |
|---|---|
| 1 of 2 Checking and planning (read-only) | 1 of 4 Checking and planning (read-only) |
| 2 of 2 Counting what a run would change | Ready banner, then `Type YES to start` |
| | 2 of 4 Recording the translations |
| | 3 of 4 Anonymizing |
| | 4 of 4 Verifying (read-only) |

- A running step shows its clock and what the engine does now ("capturing the identities",
  "checking the plan"), rewritten in place.
- Counting and anonymizing have **one live line per kind of work**: Free text, Identifiers, Labels
  and attributes. Each line has a bar, the tables or columns done of the total, the column being
  worked on, the rows so far and the time left. A long statement on a large table shows its own
  percentage, read from Oracle's `v$session_longops`.
- The triggers of OP: one line when they are disabled and one when they are enabled again.
- **YES moves after the checks.** A run that the checks refuse never asks for it. The banner before
  it says what will change, in counts, and that it cannot be undone.

### 2.4 The checks, as a table

As db-purge's requirements: a name, whether it is needed, the state now with what was measured,
and for each one not met, what happens and what to do. They come from what the preflight checks
today:

| Check | Needed | From |
|---|---|---|
| Identity tables | required | `build_plan` (tiers, structure, compte_banque) |
| Data not anonymized before | required | `validate_plan`: originals that look like replacements, masters that hold another domain's replacement |
| Earlier translations | required | `validate_plan`: conflicts, translations missing |
| Replacements unique | required | `validate_plan`: unique, equal to no original, one of their own domain |
| Replacements fit their columns | required | `check_inventory`: too narrow, wrong type, cannot be masked |
| Bank accounts only on the structure | info (setting) | `validate_plan` with `APPROVE_STRUCTURE_ONLY_ACCOUNTS` |
| Free text that cannot be emptied | info | `check_inventory`: NOT NULL free text gets ANONYMIZED |
| Inventory objects in this database | optional (required with `FAIL_ON_MISSING_OBJECT=y`) | `check_inventory` |

### 2.5 The end

- **Dry run:** "A run would change N rows in T tables. It would end PASS / REVIEW REQUIRED /
  INCOMPLETE ..." The expected verdict comes from what the dry run counted: values left for review,
  protections switched off. Then an estimate of the time it takes ("about 30 minutes": from this
  database's last run when there is one, otherwise a rough rate taken from TANM7881). After that:
  the figures by kind of work, the identities by category, the X_ parties by reason with a
  one-line reason each and where their X_ values would go, the values left for review, "Good to
  know", Next, Report, Files.
- **Run:** "DONE   N rows changed in 29:47. Verification: REVIEW REQUIRED." Then the figures with
  their times, the verification by part, the X_ parties (counts and reasons only), "Good to know",
  Next, the exit code in words.
- **Refused:** "NOT STARTED   Nothing was changed." with the check that refused it, what it means
  and what to do (EPFPG785: import the raw data again).
- **Failed or stopped:** what was done before it, that the triggers are enabled again, and that a
  new run resumes (S17).
- `/verbose` shows every line of the engine, as today. `console.log` and `report.txt` always keep
  them all.

## 3. report.html

One self-contained file in the run folder, opened in the browser at the end (`/no-open` leaves
it closed). The look is db-purge's: the verdict in a word, the result in one sentence, tiles with
the main figures, then cards.

| Section | Dry run | Run | Refused |
|---|---|---|---|
| What a run would change / What was done (by kind, columns, rows, X_, time) | yes | yes | |
| Verification by part, with the verdict and its exit code | | yes | |
| Left for review: column, rows, what it holds, what it needs | yes | yes | |
| Unclassified parties (X_): by reason and where found, the reason in words | yes | yes | |
| ... what to do before the real run, and one query per reason to list them | yes | | |
| ... where the X_ values go, by table | yes | yes | |
| Identities by category | yes | yes | yes |
| Checks | yes | yes | yes, with the one that refused |
| Switches used | yes | yes | yes |
| Duration by step | yes | yes | |
| Good to know, Next | yes | yes | yes |
| Every column of the inventory, with a filter (folded) | yes | yes, with its verification | |
| Not in this database (folded) | yes | yes | |
| The full text report and the verification output (folded) | yes | yes | yes |

The rules stay those of `generate_report.sql`: it **reads, never re-checks**, and it holds counts
only, never an identifier. The X_ queries are printed, never run.

## 4. How it works

### 4.1 Files

| File | |
|---|---|
| `op\run_op_anonymization.bat` | becomes the launcher (about 15 lines): starts `lib\anon.ps1`, returns its exit code. Same switches: `/dryrun`, `/auto`, `/force`, `/inventory <file>`; new: `/verbose`, `/no-open` |
| `op\lib\anon.ps1` | new: configuration, questions, sessions, steps, run folder, exit code. Taken from db-purge's `epf.ps1` where it fits: prompts, dividers, `Start-Session`, the monitor, `console.log` |
| `op\lib\anon_screen.ps1` | new: steps, live lines, checks table, the end. As db-purge's `epf_screen.ps1` |
| `op\lib\anon_html.ps1` | new: `report.html`. As db-purge's `epf_html.ps1` |
| `op\sql\run\*.sql` | new entry scripts, each small: `prepare.sql` (SYS), `plan.sql`, `count.sql`, `apply.sql`, `poll.sql`, `results.sql`, `stop.sql` |
| `op\sql\00_run_op_anonymization.sql` | kept, for sqlplus without the wrapper and for the regression suite |
| `op\verify\verify_op_coverage.sql` | unchanged; its output goes to `verify.txt` |
| `op\verify\generate_report.sql` | retired once `report.html` covers its sections |
| `tests\manual\monitor_op_progress.sql` | kept, for a DBA |

### 4.2 Sessions

1. **SYS** (`prepare.sql`): ANON_META created or upgraded, its grants. As today's
   `10_create_metadata_schema.sql`.
2. **Worker, as OP, one session kept open**: install the engine, load the inventory, `plan.sql`
   (configure, start the run, preflight). Then, for a run, the YES question, then `apply.sql` in
   the same session. The plan stays in the engine's memory, so nothing has to be attached again.
3. **Monitor, as OP**: `poll.sql <run> <last step_id>` every 2 seconds.
4. **Verifier, as OP**: `verify_op_coverage.sql`, then `results.sql` for the screen's end and
   `report.html`.

The passwords reach sqlplus on its standard input only, as in db-purge.

### 4.3 What the monitor reads

- `anon_meta.anon_step_log` rows after the last one seen. A new column, `step_id`, numbers them.
- `anon_meta.anon_progress`: one row per run, rewritten by the engine before each table, column
  or planning stage. It holds the phase, the items done and planned, the object and when it
  started.
- `v$session` and `v$session_longops` for the worker session, found by its module
  `ANON R-<run>`: the percentage and time left of a long statement. This needs a read grant on
  those two views, made in the SYS step. Without it, the line shows items only.

### 4.4 The run folder

`op\logs\<date>_<time>_R-<run>\`, one per run:

| File | |
|---|---|
| `console.log` | every line of the screen, plus the engine's |
| `report.txt` | what the engine printed (today's `op_anon_*.log`) |
| `verify.txt` | what the verification printed (runs only) |
| `report.html` | section 3 |
| `manifest.txt` | `key=value`: run, mode, switches, steps and their times, checks, verdict, exit code |
| `inventory.sql` | the inventory as loaded: table and column names only |
| `sqlplus_*.log` | each session's raw output |

### 4.5 Ctrl+C

Ctrl+C asks the engine to stop after the column it is working on. The wrapper does not end then:
the run finishes that column, enables the triggers again, ends STOPPED, and writes its report. A
new run resumes: it keeps the translations already recorded (S17). Closing the window is still
not safe. The screen says so while the run works.

### 4.6 Exit codes

Unchanged: 0 PASS, 1 failed or not started, 2 FAIL, 3 REVIEW REQUIRED, 4 INCOMPLETE. New: 5 stopped
with Ctrl+C. The last line of the screen says the code in words.

## 5. Changes to the engine (additions only)

| Object | Change | Why |
|---|---|---|
| `anon_meta.anon_progress` | new table: run_id, phase, items_done, items_total, object_name, started_at | the live lines |
| `anon_meta.anon_step_log` | new column `step_id`, from a sequence | the monitor reads only new rows |
| `anon_meta.anon_check` | new table: run_id, code, needed, status, measure, what_happens, what_to_do | the checks table. Today only failures are logged |
| `anon_meta.anon_run` | statuses REFUSED, CANCELLED, STOPPED; columns `tool_version`, `stop_requested` | a refusal is not a failure; Ctrl+C |
| `anon_meta.unclassified_reason` | new column `brief`: the reason in one line | the screen |
| `op.anon_engine` | `progress(...)`, `record_check(...)`, module and action set with `DBMS_APPLICATION_INFO`, the stop request read between columns, a version constant, the time estimate of a dry run | as above |
| `10_create_metadata_schema.sql` | creates and migrates all of the above in place, as it already does for `x_rows` | upgrade without loss |

Nothing in how identities are classified, translated, written or verified changes. The engine's own
lines in `report.txt` stay as they are, so a run can still be read line by line, as now.

## 6. Tests

- **Regression suite:** S0-S19 run unchanged and stay green. A new S20 checks the progress rows,
  `step_id`, the checks recorded whether met or not, the `results.sql` lines, and that none of them
  holds an identifier.
- **The wrapper without a database:** a stand-in sqlplus with scripted replies plays the screens:
  dry run, run, refused, failed, stopped, `/auto`, `/force`, `/verbose`, no console (output to a
  file). The screens are checked, as db-purge's 28 scenarios were.
- **End to end on the Docker sandbox:** the real wrapper through a relay sqlplus that forwards to
  the container's sqlplus (the host has no Oracle client). A dry run, a run, a refusal (S10's
  data) and a Ctrl+C.
- **Then you:** a dry run on the client test copy, after a fresh raw import, then a run.

## 7. Order of work

1. This plan and the demo. Then your changes.
2. The engine additions, the entry scripts and `results.sql`. The regression suite plus S20.
3. The wrapper: getting ready, questions, steps, live lines, the end, Ctrl+C. Tests with the
   stand-in sqlplus.
4. `report.html`. `generate_report.sql` retired.
5. End to end on the sandbox. Then your runs on the client copy.
6. Then the documents, as planned: user guide, scenarios and references in the Finastra template.

## 8. Decisions for you

My recommendation comes first in each. "ok" takes all of them.

1. **The wrapper in PowerShell** (as db-purge; Windows PowerShell 5.1 is on every Windows machine),
   with the .bat as the command you type. The other way, keeping everything in batch, cannot
   rewrite a line in place, read a second session or write HTML.
2. **YES after the checks.** The other way: as today, before anything runs.
3. **`generate_report.sql` retired** once `report.html` covers it. The other way: keep it for one
   version.
4. **Exit code 5 for a run stopped with Ctrl+C.** The other way: 1, as for a failure.
5. **"OP Anonymization 4.1"** on the screens and in ANON_META (`tool_version`), so that a report
   says which version made it.
6. **Switches:** asked only when the configuration file leaves them blank (as today), and shown as
   one table either way.

Your answers:

## 9. Not in this plan

- The anonymization rules: Q1-Q4 and D1-D10 of `14_open_questions.txt`. Once decided, the
  "Left for review" lines in the demo change with them. Today they are what your client copy will
  show.
- The documents in the Finastra template: after this.
