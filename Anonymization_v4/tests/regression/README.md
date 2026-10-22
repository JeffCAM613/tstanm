# Regression suite

Runs the real engine, verifier and inventory against a **disposable** Oracle database in a local
container, on fictional data, and checks the result. It covers the cases of
`unofficial docs/fixes+needed_in_v4.txt`: the account union, the party classification and its X_
reasons, the shared party/account text, structure roles and parents, the eight switch
combinations for every category, map reuse and extension, incompatible mapping history, the
migration of an older metadata schema, and the removal of the checkbox exceptions. And those of
`fixes+needed_in_v4-part2.txt`: codes found only in references, the structure tree by tree
(folders, other screens, parents), MIXED breakdowns, and free text that refuses NULL.

**Never point it at a real database.** It drops and recreates the `OP`, `ANON_META` and `ATRACE`
users. `fixture_schema.sql` refuses to touch an `OP` schema it did not create itself.

## Run it

Needs Docker Desktop and Git Bash on Windows (the inventory is built by
`op\run_op_anonymization.bat /inventory`, exactly as a real run builds it). The Linux wrapper,
`op/run_op_anonymization.sh`, runs in the container itself (S23): it needs nothing more.

```bash
# once: a throwaway Oracle XE 21 (the closest free version to 19c)
docker run -d --name anonv4-xe -p 15210:1521 -e ORACLE_PASSWORD=<choose one> \
       --shm-size=1g gvenzl/oracle-xe:21-slim-faststart

# every time, from Anonymization_v4/
export ANON_TEST_SYS_PASSWORD=<the same password>
tests/regression/run_regression.sh            # every scenario, about 10 minutes
tests/regression/run_regression.sh S1 S8      # only some
```

The last line says `passed N, failed M`; the exit code is 0 only when nothing failed.
`docker rm -f anonv4-xe` removes the database when you are done.

## What each scenario proves

| | Scenario | Expected |
|---|---|---|
| S0 | Sections 7 and 7A of the fix instructions, SELECT only - with part 2's item 7 (an archived party, flag N and no structure node, is a counterparty) | 3 / 0 / 1 and 16 / 0 / 4 / 3 / 2 / 7 |
| S1 | Core fixture: dry run, then every switch on | dry run changes and freezes nothing; PASS; `assert_core.sql` - including part 2's items 1, 2B, 3 and 5C (tiers_domicile emptied, an account report's codes only, a party code with no master, free text that refuses NULL) |
| S2 | The same run again | no translation changes, no row rewritten, PASS |
| S3 | Structure-only account nodes refused (`APPROVE_STRUCTURE_ONLY_ACCOUNTS=n`) | refused before any update, nothing persisted; left unset, they are allowed (default `y`) |
| S4 | A text that is a party AND an account, in MIXED columns with no breakdown | left unchanged, REVIEW REQUIRED; other-screen nodes keep their code and an ambiguous parent is the one in its child's tree - neither for review |
| S5 | The eight switch combinations, all five categories at once | `assert_switches.sql`; INCOMPLETE unless all on |
| S6 | New inputs on a mapped dataset | appended after the existing numbers, nothing renumbered |
| S7 | Raw data re-imported, maps kept, a category off | originals kept, other categories reuse their values, EPF view honest |
| S8 | An X_ party whose master data is repaired later | keeps its X_, drift reported, REVIEW REQUIRED |
| S9 | Data already anonymized, mapping lost | refused |
| S10 | Data anonymized by the previous version | refused: a master holds another domain's replacement |
| S11 | Maps of the previous version on raw data | the matching one reused, the other superseded, drift reported |
| S12 | Two earlier party translations, neither matching | refused |
| S13 | Metadata schema of the previous version | migrated in place, run and verification pass |
| S14 | Inventory validation and column capacity | `ANY`, a party category on CODE, a wrong master domain, a value that cannot fit and a NOT NULL number are refused; a one-character free-text column is processed |
| S15 | A switch that is neither y nor n | refused |
| S16 | A dangling party reference: in a party column, then in a MIXED column | captured by itself (X_ MISSING_MASTER, reference only), renamed, PASS; in a MIXED column a warning until confirmed, then the same |
| S17 | Resume after a run that stopped partway | no re-classification; restored originals get the same translations; PASS |
| S18 | Account nodes classified other than `Compte`, or not at all | still account nodes (the screen alone decides): CB_, account parent, labels masked, nothing for review; PASS |
| S19 | Unclassified parties in a dry run, then in EXECUTE, then with X_ renaming off | dry run: counts by reason and where found, the reasons, the fixes and one query per reason - each query runs and lists them; EXECUTE: counts and reasons only; X_ identifiers by table in both, in the step log and in the report; no identifier in any output; the report and the end of the run on the screen the same from the Linux wrapper's code |
| S20 | Part 2: codes found only in references, the structure tree by tree, MIXED breakdowns (`fixture_part2.sql`) | references captured (X_ / CB_), counted by column in the dry run; folders of the folder trees renamed (party first), other folders' text emptied, other screens untouched, each child follows the parent of its own tree; a breakdown settles a party-and-account value; PASS; `assert_part2.sql`; a second run rewrites nothing |
| S21 | Part 2: what is still left for review | a breakdown of both kinds, or of nothing else, and a parent with no node in its child's tree that is both: left unchanged, REVIEW REQUIRED |
| S22 | The run as the wrapper drives it: the entry scripts in one session, `poll.sql`, `results.sql`, `stop.sql`, `finish.sql`, `recover.sql` | every check recorded and every log row numbered once; the progress and the figures read back; a stop between two columns, then a run that resumes to PASS; CANCELLED, a lost session ended FAILED, a copy anonymized before REFUSED; the dry run's report and end screen the same from the Linux wrapper's code |
| S23 | The Linux wrapper, `op/run_op_anonymization.sh`, in the container | the batch file's inventory; a dry run, a run (PASS) and the same run again; REFUSED, REVIEW REQUIRED, INCOMPLETE, not confirmed, a wrong password - each with its exit code; SIGINT to its process group during the work stops it between two columns (STOPPED, exit code 5); SIGHUP stops nothing (PASS); its report.html the page Windows writes from the same folder |

## Files

| File | |
|---|---|
| `run_regression.sh` | the driver |
| `fixture_schema.sql` | the fictional OP tables, all empty |
| `fixture_data.sql` | the core cases - each identity named after the case it exercises |
| `fixture_review.sql` | the cases that must be left for review |
| `fixture_part2.sql` | the cases of part 2 of the fix instructions that must end in PASS |
| `legacy_metadata.sql` | `anon_meta` as the previous version created it |
| `assert_core.sql` | one line per expectation after S1 |
| `assert_part2.sql` | one line per expectation after S20 |
| `assert_switches.sql` | one switch combination, every category |
| `design_checks.sql` | the two SELECT-only design checks of the fix instructions |
| `end_screen.ps1` | the end of a run as `anon_screen.ps1` shows it, from a `results.txt` and a run state: compared with the Linux wrapper's `anon_end.awk` |
