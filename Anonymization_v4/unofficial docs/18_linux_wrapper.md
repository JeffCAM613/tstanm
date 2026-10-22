# 18 - Running on Linux: run_op_anonymization.sh

> **For you, before a run from a Linux server.** What was added so that the tool runs as a `.sh`,
> how it works, where it differs from Windows, how it was tested, and what to look at first on
> the client's server. Counts only: no client name or code appears here.

| | |
|---|---|
| Asked | "Update this tool to include necessary components to run this in a linux server as .sh" |
| Decisions | A native bash and awk wrapper - nothing to install on the server but the Oracle client. The same SQL, configuration, run folder and report as Windows. One release zip for both |
| Code | Working tree, not committed |
| Tested | Regression suite S0-S23 (S23 new, S19 and S22 extended); Oracle Linux 8 and 7 clients, by hand - section 5 |
| Not yet | The client's Linux server |

## Contents

1. [In short](#1-in-short)
2. [What was added and changed](#2-what-was-added-and-changed)
3. [How it works](#3-how-it-works)
4. [The same as Windows, and where it differs](#4-the-same-as-windows-and-where-it-differs)
5. [How it is tested](#5-how-it-is-tested)
6. [Not tested here - look at these first](#6-not-tested-here---look-at-these-first)
7. [Open points](#7-open-points)

---

## 1. In short

- **`op/run_op_anonymization.sh`** is the Linux launcher: `--dryrun`, `--auto`, `--force`,
  `--verbose`, `--no-open`, `--no-color`, `--inventory <file>`, `--help` (the `/` and `-` forms
  are accepted too). Same exit codes, 0 to 5.
- **It needs bash 4.2 or later, awk and the Oracle client** - every Red Hat / Oracle Linux 7 and
  later, Debian, Ubuntu or SUSE server has the first two. No PowerShell, Python or Perl.
- **The same run**: the same engine and SQL, the same `config/anonymization.ini`, the same steps,
  checks table, live lines, end screen, run folder and `report.html`. Nothing in the engine or the
  SQL changed (comments only).
- **The same report, proven**: `report.html` written on Linux is the page Windows writes from the
  same run folder, byte for byte apart from line endings; the end of the run on the screen is the
  same, line by line and colour by colour; `--inventory` writes the same statements. The suite
  checks all three.
- **Ctrl+C** stops the run after the table or column it works on (exit code 5), as on Windows;
  `kill -INT <pid>` does the same from another terminal. **A closed terminal or a dropped SSH
  connection does not stop the run**: it goes on to its end and leaves its folder.
- **One zip for both platforms**: `unzip` on Linux keeps the launcher executable.

## 2. What was added and changed

| File | |
|---|---|
| `op/run_op_anonymization.sh` | New. The launcher, 19 lines of POSIX sh: finds bash, starts `lib/anon.sh`, returns its exit code. Works when started as `sh op/run_op_anonymization.sh` too |
| `op/lib/anon.sh` | New. The port of `anon.ps1`: command line, configuration, questions, sqlplus sessions, the steps, run folder, manifest, exit code |
| `op/lib/anon_screen.sh` | New. The live part of `anon_screen.ps1`: steps, live lines, switches and checks tables, the question before a run |
| `op/lib/anon_results.awk` | New. `results.txt` read into arrays and the figures (`ConvertFrom-Results`, `Get-Figures`, `Get-VerifyParts`, `Get-GoodToKnow`), with the formats |
| `op/lib/anon_end.awk` | New. The end screens (`Show-RunEnd` and the functions it calls) |
| `op/lib/anon_html.awk` | New. `report.html` (`anon_html.ps1`) |
| `tools/make_release.ps1` | The six files above shipped (50 files); Unix permissions in the zip (below) |
| `.gitattributes` | `*.awk` kept LF, as `*.sh` already was |
| `docs/OP_User_Guide.md` | Linux in sections 2 to 8 and in Common problems; new section 12, Running on Linux; the quick reference (now 13) for both. HTML and DOCX rebuilt |
| `docs/OP_Technical_Guide.md` | Sections 3, 8, 11, 14, 19 and 21. HTML and DOCX rebuilt |
| `README.md`, `tools/README.md` | The Linux commands; the zip |
| `tests/regression/run_regression.sh` | S19 and S22: `report.html` and the end screen compared with the Linux code; S23 new |
| `tests/regression/end_screen.ps1`, `README.md` | New: the end screen as `anon_screen.ps1` prints it, for the comparison. The README lists S22 (it was missing) and S23 |
| `op/sql/run/*.sql` (6), `00_run_op_anonymization.sql`, `tests/manual/monitor_op_progress.sql` | Comments that named only the `.bat`; one `PROMPT` of `00_run...` |
| `config/anonymization.template.ini`, `config/inventory_op_custom.csv` | Comments: the file serves both; `--auto`, the Linux dry run. Rows and settings unchanged |

**The zip.** .NET records every entry as made on Windows, and `unzip` then ignores the permissions
it holds. `make_release.ps1` writes `rwxr-xr-x` for `.sh` files and `rw-r--r--` for the rest, and
marks each entry as made on Unix (one byte in the zip's directory). Checked: on Oracle Linux 7,
`unzip` gives the launcher its execute bit and it runs as it comes out; Windows still unpacks the
zip; `unzip -t` finds no error.

**Committing.** git here records file modes as 644 (`core.filemode=false`). For a checkout on Linux
to get an executable launcher, add it with `git add --chmod=+x Anonymization_v4/op/run_op_anonymization.sh`.

## 3. How it works

**bash and awk, not PowerShell on Linux.** PowerShell 7 runs on Linux, but a database server rarely
has it, and the client's IT would have to approve a new runtime. bash and awk are on every server.
The control flow is bash (it mirrors `anon.ps1` function by function, under the same names in
snake case); everything that parses the results and builds text is awk, run with `LC_ALL=C` so
that gawk, mawk and busybox awk give the same bytes.

**Sessions.** As on Windows, `sqlplus -S -L /nolog` per session, `CONNECT` on its input, `PROMPT
<marker>` after each command. On Linux:

- its input is a named pipe the wrapper writes to - the password passes through it and is never
  stored - and its output a file the wrapper reads as it grows; both in a folder only the owner can
  read (`mktemp -d`), removed at the end;
- **each `sqlplus` runs in a process group of its own.** Measured: `sqlplus` catches SIGINT even when
  started in the background, and cancels the statement it runs (ORA-01013) - a Ctrl+C reaching it
  would end the run FAILED instead of STOPPED. In its own group, the terminal's Ctrl+C reaches the
  wrapper only;
- every session closes the other sessions' descriptors, so that its input ends when the wrapper
  closes it.

**Signals.** SIGINT (Ctrl+C) and SIGTERM (`kill`) are a stop request, acted on where the wrapper
waits, exactly where `Test-StopKey` acts on Windows. SIGHUP is ignored, by the wrapper and by every
process it starts: the run goes on, the first write to the closed terminal fails and the screen is
dropped, `console.log` goes on. SIGPIPE is ignored (a `| tee` that dies).

**Questions.** A password is not shown at all (the Linux custom; Windows shows `*`), and the
terminal stops showing what is typed *before* the question appears. Ctrl+C at a question stops
there, nothing changed (exit code 5). With `--auto`, the passwords come from the environment, are
read once and removed from it: no process the wrapper starts is given them.

**No extra tool.** Waiting is a timed read on a private pipe (no `sleep` process); clocks are
bash's own; the wrapper starts `sqlplus`, `awk`, `mkfifo`, `mktemp`, `stty` and nothing else.
`sqlplus -V` runs first: a client missing its libraries (`ORACLE_HOME`, `LD_LIBRARY_PATH`) is one
line before anything else.

## 4. The same as Windows, and where it differs

| | Windows | Linux |
|---|---|---|
| The engine, SQL, configuration file, steps, checks, live lines, end screen, run folder, `report.html` | | the same - see section 1 |
| Options | `/dryrun`... | `--dryrun`... (`/` and `-` accepted) |
| A password while it is typed | `*` | nothing |
| The terminal closed during a run | not safe: `recover.sql` | the run goes on to its end |
| `report.html` at the end | opened in the browser | its path; opened only on a desktop (`DISPLAY`) |
| sqlplus missing its libraries | a failed connection | one line at the start |
| A session that ends before it connects | "sqlplus ended before it connected." | the same, with sqlplus's first line |
| Colours | on a console | on a terminal; none with `TERM=dumb` or `NO_COLOR` |

## 5. How it is tested

**The regression suite.** S19 and S22 now also build `report.html` and the end screen with the
Linux code from the same files and compare them with Windows's (`html_parity`, `end_parity`).
**S23** runs `op/run_op_anonymization.sh` inside the container: the batch file's inventory; a dry
run, a run (PASS) and the same run again; REFUSED, REVIEW REQUIRED, INCOMPLETE, "no" at the
question, a wrong password - each with its exit code; SIGINT to the wrapper's process group during
a 600,000-row statement (STOPPED, exit code 5, and the database says STOPPED: `sqlplus` did not get
it); SIGHUP (the run goes on to PASS, `console.log` complete); and the `report.html` of a Linux run
against the page Windows writes from the same folder. Result: see the end of this section.

**Platforms.**

| | bash | awk | Oracle client |
|---|---|---|---|
| Oracle Linux 8.10 (the database container) | 4.4.20 | gawk 4.2.1 | SQL\*Plus 21.3, database home |
| Oracle Linux 7.9 (a separate client container) | 4.2.46 | gawk 4.0.2 | Instant Client 21.23, RPM, the database over the network |
| The awk programs alone | - | gawk 5.3.2, mawk 1.3.4, busybox 1.37 | - |

The three awk implementations write the same `report.html` and end screens, byte for byte.
ShellCheck finds no warning (notes only, for functions called by name: signal handlers and the
live view).

**By hand** - on a terminal where it matters, a pseudo-terminal driven by `script` and `expect`:

| Scenario | Exit | Seen |
|---|---|---|
| Dry run, run, run again, refused, review, incomplete, not confirmed, wrong password | 0 0 0 1 3 4 1 1 | as on Windows; end screens and reports identical to Windows's |
| Everything asked: the passwords (a wrong SYS one first), the 15 switches, YES | 0 | nothing typed was shown; the SYS password asked again; `console.log` has `********` |
| Ctrl+C typed during the work, 600,000 rows (OL8) | 5 | `^C`, the stop request, STOPPED after the first table, triggers enabled again |
| Ctrl+C typed during the work, 1.5 million rows, 160 columns (OL7, bash 4.2) | 5 | the live line with the long statement's percentage (13% ... 98%) and the time left; stopped after the table under way |
| The terminal closed during the identifiers (OL8) | 0 | the wrapper went on alone for 16 minutes: verified PASS, the seven files, `console.log` complete |
| Ctrl+C at a question | 5 | "Stopped at the question", nothing changed |
| `TERM=xterm`, `NO_COLOR`, `TERM=dumb`, `--no-color` | - | colours only where they belong |
| The worker's `sqlplus` killed during the work (OL8) | 1 | FAILED; `recover.sql` through the monitor found the run still working in the database and said so (section 7) |
| The release zip on OL7, configured from the template | 0 0 | permissions kept; a dry run, then a run with everything asked - PASS, nothing typed shown |

**Bugs these tests found in the new code, fixed:** each `sqlplus` kept the other sessions' pipe open
and never saw the end of its input; a list of switched-off protections came out empty; a password
typed the instant its question appeared was shown; bash 4.2 drops the start of a line when a timed
read runs out (now: wait until a whole line is there, then read it); a SIGHUP handler left the
processes the wrapper starts killable by the hangup (now ignored); a `sqlplus` killed from outside
made bash print a block of the wrapper's source (now one line naming the session); three awk
constructs that one awk accepts and another refuses.

**Result of the suite:** S0-S23, **705 checks passed, 0 failed** - the 681 of 0.5.0, the four
comparisons added to S19 and S22, and S23's twenty. S23 again on the final code: 21 passed (with
the setup's check).

## 6. Not tested here - look at these first

1. **The client's server** - its distribution, and a 19c client (21 was used here). Start with
   `op/run_op_anonymization.sh --help`, then a dry run.
2. **A real SSH disconnection.** Here the terminal was closed by ending its pseudo-terminal, which is
   what a disconnection does to the session; a long run is still better started in `tmux` or
   `screen`, or with `nohup` (User Guide, section 12).
3. **The browser at the end** - there is no desktop in the test containers. On a server the path is
   printed, as intended.
4. **`NLS_LANG`** other than the containers' (`.AL32UTF8`). The wrapper reads error codes, not texts.

## 7. Open points

- **The version label** is still 0.5.0: `anon_run.tool_version` and the zip's name do not tell this
  release from the Windows-only one. Bumping it is one constant in `30_install_engine.sql` and the
  guides' first lines - say if you want it.
- **Windows, unchanged:** `anon.ps1` keeps `ANON_SYS_PASSWORD`/`ANON_OP_PASSWORD` out of `sqlplus`'s
  environment, but the browser it opens at the end inherits them. The Linux wrapper removes them
  from its own environment once read; the same one line would do it on Windows.
- **The triggers** (from 0.5.0): a run enables every trigger of OP at its end, including one
  disabled before it - the same on both platforms.
- **A lost worker session, on both platforms.** When the worker's `sqlplus` was killed during the
  work, `recover.sql` found the run's database session still there, and the screen said "it ends by
  itself and enables the triggers of OP again". Here, the database then ended that call itself
  shortly after - its client was gone - and the run stayed RUNNING, with nothing re-enabled; a
  second `recover.sql` by hand ended it FAILED. (The fixture has no triggers, so none stayed
  disabled; on the client's copy they would have, until that second `recover.sql`.) The message
  comes from the shared design: "it ends by itself, or run `recover.sql` once `anon_meta.anon_run`
  no longer says RUNNING" would be closer. Not changed - say if you want both wrappers to say so.
- **Test leftovers:** the container `anonv4-ol7` (`docker rm -f anonv4-ol7`) and the `util-linux`
  package added to `anonv4-xe` for the pseudo-terminal tests.
