# tests/

**Nothing in this folder is part of a run.** `manual/` holds ad-hoc scripts for inspecting an
instance by hand — before a run, during one, or when something looks wrong. In the source
repository, `regression/` holds the automated suite that proves the engine on fictional data in a
disposable container; it is not part of a release.

The workflow scripts live elsewhere and are the only things the orchestrator executes:

| Purpose | Location |
|---|---|
| Anonymization workflow | `op/sql/` |
| Post-run verification | `op/verify/` |
| Documentation generation | `tools/` |
| **Manual inspection (this folder)** | `tests/manual/` |

This separation is deliberate: nothing outside `op/` is ever part of a run, so a script here can
be read and run by hand without wondering whether a run executes it too.

## What's here

| Script | Use |
|---|---|
| `manual/check_tables_exist.sql` | Which inventory tables/columns exist on this instance. Read-only. Answers "will anything be skipped?" before committing to a run. |
| `manual/row_counts.sql` | Row counts for the main anonymization targets. Read-only. Useful for estimating runtime. |
| `manual/monitor_op_progress.sql` | A run in progress, from `anon_meta.anon_progress` and `anon_meta.anon_step_log`, for a DBA in SQL*Plus (the run shows the same live). Run from a second session. |
| `manual/inspect_code_map.sql` | Sample the generated mapping; check category counts and look for anomalies. Read-only. |
| `manual/typed_identity_diagnostics.sql` | Before a run, on raw data: is the copy raw, how many bank accounts and parties of each kind, how many texts are both, which structure screens hold identifiers, and what a `pere` points at. Counts only - safe to share. Read-only. |
| `manual/check_locks.sql` | Who is holding the `anon_meta` tables. Run as SYS when a run stalls or fails at the inventory reload. Read-only. |

## Ground rules

- **Read-only.** Nothing here issues DML. If you need a script that changes data, it belongs in
  `op/sql/` and in the inventory.
- **Safe to run any time**, including against a database mid-run.
- **Not required for correctness.** Skipping all of them changes nothing about a run's outcome.
