# Regression suite

Runs the real engine, verifier and inventory against a **disposable** Oracle database in a local
container, on fictional data, and checks the result. It covers the cases of
`unofficial docs/fixes+needed_in_v4.txt`: the account union, the party classification and its X_
reasons, the shared party/account text, structure roles and parents, the eight switch
combinations for every category, map reuse and extension, incompatible mapping history, the
migration of an older metadata schema, and the removal of the checkbox exceptions.

**Never point it at a real database.** It drops and recreates the `OP`, `ANON_META` and `ATRACE`
users. `fixture_schema.sql` refuses to touch an `OP` schema it did not create itself.

## Run it

Needs Docker Desktop and Git Bash on Windows (the inventory is built by
`op\run_op_anonymization.bat /inventory`, exactly as a real run builds it).

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
| S0 | Sections 7 and 7A of the fix instructions, SELECT only | 3 / 0 / 1 and 16 / 0 / 4 / 3 / 1 / 8 |
| S1 | Core fixture: dry run, then every switch on | dry run changes and freezes nothing; PASS; `assert_core.sql` |
| S2 | The same run again | no translation changes, no row rewritten, PASS |
| S3 | Structure-only account nodes not approved | refused before any update, nothing persisted |
| S4 | Roles that cannot be established | left unchanged, REVIEW REQUIRED |
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
| S16 | A dangling party reference, then confirmed | a warning until confirmed; then X_ MISSING_MASTER, renamed, PASS |
| S17 | Resume after a run that stopped partway | no re-classification; restored originals get the same translations; PASS |
| S18 | Account nodes classified other than `Compte`, or not at all | still account nodes (the screen alone decides): CB_, account parent, labels masked, nothing for review; PASS |
| S19 | Unclassified parties in a dry run, then in EXECUTE, then with X_ renaming off | dry run: counts by reason and where found, the reasons, the fixes and one query per reason - each query runs and lists them; EXECUTE: counts and reasons only; X_ identifiers by table in both, in the step log and in the report; no identifier in any output |

## Files

| File | |
|---|---|
| `run_regression.sh` | the driver |
| `fixture_schema.sql` | the fictional OP tables, all empty |
| `fixture_data.sql` | the core cases - each identity named after the case it exercises |
| `fixture_review.sql` | the cases that must be left for review |
| `legacy_metadata.sql` | `anon_meta` as the previous version created it |
| `assert_core.sql` | one line per expectation after S1 |
| `assert_switches.sql` | one switch combination, every category |
| `design_checks.sql` | the two SELECT-only design checks of the fix instructions |
