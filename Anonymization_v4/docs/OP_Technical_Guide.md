# OP Anonymization - Technical Guide

**KTP Payment Factory - OP schema - version 0.5.0**

Everything needed to understand, operate, maintain and extend the tool. For the shorter
run-it-and-go instructions, read the *OP Anonymization - User Guide*.

---

## Contents

1. [Purpose and scope](#1-purpose-and-scope)
2. [The design principle: one inventory drives everything](#2-the-design-principle-one-inventory-drives-everything)
3. [The inventory](#3-the-inventory)
4. [Identities](#4-identities)
5. [Switches](#5-switches)
6. [Translations](#6-translations)
7. [Applying the inventory](#7-applying-the-inventory)
8. [The run](#8-the-run)
9. [The checks](#9-the-checks)
10. [Watching a run](#10-watching-a-run)
11. [Stopping, failing and resuming](#11-stopping-failing-and-resuming)
12. [The dry run](#12-the-dry-run)
13. [Verification](#13-verification)
14. [The run folder and report.html](#14-the-run-folder-and-reporthtml)
15. [Metadata schema reference](#15-metadata-schema-reference)
16. [Extending coverage](#16-extending-coverage)
17. [Version compatibility](#17-version-compatibility)
18. [Vocabulary](#18-vocabulary)
19. [File reference](#19-file-reference)
20. [Error codes](#20-error-codes)
21. [Known limitations](#21-known-limitations)

---

## 1. Purpose and scope

The tool removes client data from a restored copy of a KTP Payment Factory database, so the copy can
be used for development, testing and support.

| Schema | Holds | Covered by |
|---|---|---|
| **OP** | Core treasury: entities, portfolios, counterparties, bank accounts, and the `histo_*` history tables | **This tool** |
| **EPF** (`OPPAYMENTS`) | Payment factory: payments, users, SWIFT/BIC data, audit trail | The EPF anonymization, run after this one. It reads the translations this tool records (`atrace.ref_tables_modif`) |

The shipped inventory lists 560 columns, and the site inventory 16 more. On a given database some of
them do not exist: the inventory covers several KTP/CTI versions.

### What "anonymized" means here

Four treatments, declared per column:

| Rule | Effect |
|---|---|
| `CODE` | The identifier is replaced with its translation, of its own domain (a party's or a bank account's) |
| `NULL_OUT` | Emptied. Where the column refuses NULL, overwritten with the marker `ANONYMIZED`, cut to the column's width |
| `DESCRIPTION` | A label, overwritten with its owner's replacement, so screens stay readable |
| `SELF_CODE` | An attribute (address, contact detail), overwritten with its owner's replacement where it holds a value; an empty field stays empty |

### What is deliberately not anonymized

- **Amounts, dates, currencies, product and system codes.** They carry no client identity, and
  changing them would break reconciliation and reporting.
- **Columns left out of the inventory, with the reason in a comment**: for example the
  one-character discriminators that say whether a neighbouring column holds a tiers or an entity.
  Every listed column is processed by its rule; nothing is skipped by guesswork.

---

## 2. The design principle: one inventory drives everything

Every `(table, column, rule, category)` is declared **once**, in a CSV. That one declaration drives
four things:

```
                     config/inventory_op.csv
                   + config/inventory_op_custom.csv
                              |
                              v
                   anon_meta.anon_inventory
                              |
        +-------------+-------+--------+-----------------+
        v             v                v                 v
    the engine    the dry run      the verifier    the coverage doc
```

The script that changes the data, the check that proves it changed and the document that describes it
cannot disagree, because they read the same rows. A site's own columns are not a special case: they
are rows of a second CSV, loaded the same way.

---

## 3. The inventory

### Format

```csv
table_name,column_name,rule,category,source,notes
structure,code,CODE,NODE_ROLE,BASE,[folders: Entite Compte Tiers Compta Compta_Ato] ...
compte_regle,compte,CODE,BANK_ACCOUNT,BASE,
histo_operation,description,NULL_OUT,NONE,BASE,
```

| Field | Meaning |
|---|---|
| `table_name`, `column_name` | A table (or updatable view) of OP, and its column |
| `rule` | `CODE` - `NULL_OUT` - `DESCRIPTION` - `SELF_CODE` |
| `category` | What the column holds (a `CODE` row) or who owns the row (a `DESCRIPTION` or `SELF_CODE` row) |
| `source` | `BASE` (shipped) or `CUSTOM` (site file) |
| `notes` | Free text, and the column options below. No commas |

Lines starting with `#` and blank lines are ignored. Values are case-insensitive.

### Categories

| Rule | Category | Means |
|---|---|---|
| `CODE` | `PARTY` | Party codes only. A bank account's replacement is never written here |
| `CODE` | `BANK_ACCOUNT` | Bank-account codes only. A party's replacement is never written here, even when a party has the same text |
| `CODE` | `MIXED` | Reviewed columns that hold both. A value known in one domain takes that domain's translation; a value that is a party AND an account is left as it is and reported for review, unless the column's `[group: ...]` settles it |
| `CODE` | `NODE_ROLE` | `structure.code` and `structure.pere` only: each node by its role (section 7) |
| `DESCRIPTION`, `SELF_CODE` | `PARTY`, `BANK_ACCOUNT`, `NODE_ROLE` (structure), or one party category | The owner of the row; a party category limits the column to owners of that category |
| `NULL_OUT` | `NONE` | Free text is never category-dependent |

`ANY` is not accepted: every column says which domain it holds. A single party category on a `CODE`
row is refused too - it would leave an unclassified party's code in clear.

### Column options

Bracketed words in the notes field, parsed by `21_validate_inventory.sql` into columns of
`anon_inventory`:

| Option | On | Means |
|---|---|---|
| `[no-harvest]` | `CODE,PARTY` or `CODE,BANK_ACCOUNT` | The column holds other codes too (a BBAN, an IBAN, a condition code): a value that is no identity stays as it is, and is not captured as the code of a deleted master (section 4) |
| `[only-where: <col> in <table>.<col> where <col> = <value>]` | `CODE` | Only the rows whose `<col>` names a `<table>` row with that value hold identifiers; the others are not renamed, read or checked |
| `[group: <col>]` | `CODE,MIXED` | Rows with the same `<col>` hold one kind of code: a value that is a party AND an account takes the kind of its group's other values |
| `[folders: <tree> ...]` | `structure.code` | The structure trees whose folder rows - rows with no screen - are named after clients |

A misspelt option, or one on the wrong kind of column, stops the run before anything changes.

### Fixed contracts

`21_validate_inventory.sql` refuses an inventory that breaks what the identity model relies on:
`tiers.code` is `CODE,PARTY`, `compte_banque.code` is `CODE,BANK_ACCOUNT`, `structure.code` and
`structure.pere` are `CODE,NODE_ROLE`, `tiers` labels and attributes belong to parties and
`compte_banque` ones to bank accounts.

### Overrides

The shipped file is loaded first, the site file second. For each site row the load deletes the
shipped row of the same `(table, column)` before inserting its own, so a site row **replaces** the
shipped one - which is how a wrong classification is corrected at a site without editing a file the
next release replaces.

### How the CSVs reach the database

The CSVs are on the machine that runs the tool, not necessarily on the database server, so they are
not read as external tables. The run turns them into `INSERT` statements and sends them on the input
of its worker session (section 8); `inventory.sql` in the run folder is that text.
`op\run_op_anonymization.bat /inventory <file>` - or `op/run_op_anonymization.sh --inventory <file>`
on Linux, which writes the same statements - writes it to a file and stops.

---

## 4. Identities

### Two domains

Every original code belongs to a **domain**, and only that domain's translation is ever written where
it is used:

| Domain | Found in | Category | Prefix |
|---|---|---|---|
| PARTY | `tiers.code`; `structure` nodes on the `w_tiers` screen; codes found only in party columns; confirmed references | ENTITY | `E_` |
| | | PORTFOLIO | `P_` |
| | | COUNTERPARTY | `T_` |
| | | UNCLASSIFIED_PARTY | `X_` |
| ACCOUNT | `compte_banque.code`; `structure` nodes on the `w_compte_banque` screen; codes found only in bank-account columns | BANK_ACCOUNT | `CB_` |

The same text can be a party AND an account. They are different objects, and each keeps its own
replacement: the shared text proves nothing.

### Classification of a party, in this order

| | Category |
|---|---|
| No `tiers` row | UNCLASSIFIED_PARTY, reason MISSING_MASTER |
| Flag `O` and a `w_tiers` node | PORTFOLIO |
| Flag `N` and an `Entite` node on `w_tiers` | ENTITY (wins over another classification of the same party) |
| Flag `N` and another `w_tiers` node, no `Entite` | COUNTERPARTY |
| Flag `N` and no structure node at all - an archived party | COUNTERPARTY |
| No structure node, flag not `N` | UNCLASSIFIED_PARTY, NO_STRUCTURE |
| Nodes on other screens only | UNCLASSIFIED_PARTY, NO_PARTY_SCREEN |
| Flag neither `O` nor `N` (empty, another value, or two different values) | UNCLASSIFIED_PARTY, UNKNOWN_FLAG |
| Flag `N`, `w_tiers` nodes with no classification | UNCLASSIFIED_PARTY, UNKNOWN_CLASSIFICATION |

An account node is any node on the `w_compte_banque` screen, whatever its classification. A
`w_compte_banque` node with no `compte_banque` row is a bank account unless
`APPROVE_STRUCTURE_ONLY_ACCOUNTS=n`, in which case a run that finds one refuses to start.

The reasons are recorded in `anon_meta.unclassified_reason` in words - one line (`brief`), in full
(`why`), what would classify the party (`fix`) - with a query that lists the parties of a run.

### Codes found only in references

A value of a `CODE,PARTY` or `CODE,BANK_ACCOUNT` column that is no identity of that domain is the
code of a master row deleted in the past. It is captured too (`anon_meta.reference_harvest`), found
only in references (`REFERENCE_ONLY`): a party as UNCLASSIFIED_PARTY, MISSING_MASTER; an account as
BANK_ACCOUNT. Not read for them: columns marked `[no-harvest]`, rows outside `[only-where: ...]`,
blank values, values longer than the master's code column, replacements already in `code_map`, and
`CHAR` columns (their padding would make a code of its own). A code of a `MIXED` column is not
harvested - its kind cannot be told - but can be confirmed by hand in
`anon_meta.confirmed_identity`.

### Captured once

The first time a run that changes data sees an identity, it records it in
`anon_meta.identity_inventory` with its category and reason, from the raw data. A later run keeps
that record: a replacement already written never changes because master data was repaired since.
When today's facts would classify an identity differently, the recorded category is kept and the
difference is reported (classification drift; the verification then says REVIEW REQUIRED).

---

## 5. Switches

Each of the five categories has three **independent** switches in `config\anonymization.ini`:

| Switch | Acts on |
|---|---|
| `ANONYMIZE_<CATEGORY>` | Renaming the identifiers and every typed reference to them (`CODE`) |
| `ANONYMIZE_<CATEGORY>_DESCRIPTION` | Labels (`DESCRIPTION`) |
| `ANONYMIZE_<CATEGORY>_ATTRIBUTES` | Attributes and addresses (`SELF_CODE`) |

They act **per identity**, by its category, not per column: with `ANONYMIZE_COUNTERPARTY=n` every
column still runs, and the counterparties' codes - only those - are kept. Labels and attributes are
masked with the identity's replacement, so they can be masked while the identifier itself is kept. A
switch never moves an identity into another category.

`NULL_OUT` has no switch: free text is always emptied.

A switch at `n` leaves client data in place by configuration: the verification then reports
INCOMPLETE, never PASS. When an identity's one translation belongs to another category than its own
(an earlier translation kept after the data changed), an operation runs only if both categories allow
it.

---

## 6. Translations

### Generated, never regenerated

A replacement is the category's prefix and seven digits: `E_0000001`, `CB_0000001`. New translations
are numbered after every existing one of their category, in the binary order of the original text, so
the same data always gets the same numbers and extending a map never moves an identity to another
value. An identity needs a translation when any of its three switches is on.

`anon_meta.code_map` holds them, keyed by `(category, old_code)`, with a unique index on `new_code`.
It is the only record of the original values and is **never dropped by a run**. An existing
translation is reused, never regenerated.

### The plan

Each run builds `anon_meta.identity_plan`: every identity with its category, where it was found, its
switches and its one translation - reused (`EXISTING`), new (`NEW`) or not needed (`NONE`). A dry
run counts against this plan, and a run applies it, so the two cannot disagree. The plan of the
latest completed run is kept: the verification checks the data against it, because after the run
only the plan still knows what each value was.

### Typed lookups

From the plan, each run rebuilds:

| Table | Holds |
|---|---|
| `code_lookup` | One lookup per domain (`PARTY`, `ACCOUNT`), the `MIXED` lookup (identities known in one domain only), the `AMBIGUOUS` texts (party AND account), and the values of each domain (`VALUE_P`, `VALUE_A`) that settle a `MIXED` group |
| `node_lookup` | What each structure node becomes, tree by tree |
| `owner_key` | How a label or an attribute finds its owner: by its original code or by its replacement, so labels are masked correctly whether or not the identifier was renamed |

A `CODE` column reads only its own domain's lookup. There is no fallback to another domain.

---

## 7. Applying the inventory

In this order:

1. **Free text** (`NULL_OUT`), table by table: every `NULL_OUT` column of a table in one statement.
   A column the dictionary calls nullable but that refuses NULL at run time (`ORA-01407`) gets the
   marker. Then the text of the structure's folder rows that are not named after a client.
2. **Identifiers** (`CODE`), column by column, each through its domain's lookup.
3. **Labels and attributes** (`DESCRIPTION`, `SELF_CODE`), one statement per table, rule and owner
   category.

Each statement is its own transaction. Tables at or above 100,000 rows get a `PARALLEL` hint
(`PARALLEL_DEGREE`).

### The structure tree

`structure` holds party nodes, account nodes and folders, in several trees (`structure.structure`).
A node is renamed by its screen: an account node with its account's translation, a party node with
its party's. A folder row - a row with no screen - of a tree listed by `[folders: ...]` is renamed
when its code is a client identifier (the party's translation first, else the account's). Any other
node keeps its code. A child's `pere` takes exactly what its parent node in the **same tree** became,
so a parent and its children cannot disagree. A `pere` with no node in its child's tree takes the
translation of the one domain its text belongs to, and is left for review when it is both.

### Left for review

Values whose role the data does not settle are left as they are and logged `REVIEW` - a value that
is a party AND an account in a `MIXED` column (unless its group settles it), a parent with no node in
its child's tree that is both. They are client values still in place: the verification says REVIEW
REQUIRED while they remain.

---

## 8. The run

### The pieces

```
op\run_op_anonymization.bat          launcher: starts lib\anon.ps1, returns its exit code
op\lib\anon.ps1                      configuration, questions, sessions, steps, run folder
op\lib\anon_screen.ps1               the screen: steps, live lines, checks table, the end
op\lib\anon_html.ps1                 report.html
op/run_op_anonymization.sh           Linux launcher: starts lib/anon.sh in bash
op/lib/anon.sh                       the same as anon.ps1, in bash
op/lib/anon_screen.sh                the screen while the run works
op/lib/anon_results.awk              the figures of a run, read from run/results.sql
op/lib/anon_end.awk                  the end of the run on the screen
op/lib/anon_html.awk                 report.html
op\sql\10_create_metadata_schema.sql ANON_META, created or migrated in place (SYS)
op\sql\30_install_engine.sql         the op.anon_engine package
op\sql\21_validate_inventory.sql     the loaded inventory, checked
op\sql\run\*.sql                     the entry scripts the run sends
op\verify\verify_op_coverage.sql     the verification
```

### Sessions

The wrapper starts `sqlplus -S -L /nolog` processes and writes on their standard input; **the
passwords travel only there**, in the `CONNECT` line. None is on a command line, in a file, or in
the environment of a process it starts.

| Session | Connected as | Runs |
|---|---|---|
| test | SYS, then OP | `run/session.sql`: what the connection reaches |
| SYS | SYS | `10_create_metadata_schema.sql` |
| worker | OP, kept open | `30_install_engine.sql`, `run/engine.sql`, the inventory, `21_validate_inventory.sql`, `run/inventory.sql`, then `run/start.sql`, `run/plan.sql`, and `run/count.sql` (a dry run) or `run/record.sql` and `run/apply.sql` (a run) |
| monitor | OP, kept open | `run/poll.sql` about every two seconds; `run/stop.sql` on Ctrl+C; `run/results.sql` at the end |
| verifier | OP | `verify_op_coverage.sql` (a run) |

Each command sent to a kept session is followed by `PROMPT <marker>`; the wrapper reads the output up
to that marker. The engine's state - the run, its plan - stays in the worker session from the checks
to the work, so nothing has to be attached again after the confirmation.

On Linux each session is a `sqlplus` in a process group of its own. Its input is a named pipe the
wrapper writes to - the `CONNECT` line passes through it, and is never stored - and its output a file
the wrapper reads as it grows; both are in a temporary folder only its owner can read, removed at
the end. The process group keeps Ctrl+C at the terminal away from `sqlplus`, which would otherwise
cancel the statement it runs. The wrapper needs bash 4.2 or later, awk (gawk, mawk or busybox) and
the usual system commands; it starts nothing else.

### The steps

| Dry run | Run |
|---|---|
| Getting ready | Getting ready |
| 1 of 2 Checking and planning (read-only) | 1 of 4 Checking and planning (read-only) |
| 2 of 2 Counting what a run would change | The confirmation: `Type YES to start` |
| | 2 of 4 Recording the translations |
| | 3 of 4 Anonymizing |
| | 4 of 4 Verifying (read-only) |

The confirmation comes **after** the checks: a run its checks refuse never asks for it. `/force`
skips it.

### The entry scripts

Every line the wrapper reads begins with `ANON_` and has fields separated by `|`. Counts, and names
of tables and columns, only - never an identifier.

| Script | Does | Prints |
|---|---|---|
| `session.sql` | Says what the connection reaches | `ANON_SESSION` |
| `engine.sql` | Says whether the engine is valid, and its version | `ANON_ENGINE` |
| `inventory.sql` | Counts the loaded inventory against this database | `ANON_INVENTORY` |
| `start.sql` | `configure`, `start_run` | `ANON_RUN`, `ANON_RESULT` |
| `plan.sql` | `preflight`; a refusal ends the run REFUSED | `ANON_RESULT`, `ANON_CHECK`, `ANON_IDENTITIES`, `ANON_SCOPE`, `ANON_ESTIMATE` |
| `count.sql` | The dry run's work | `ANON_RESULT` |
| `record.sql` | `generate_code_map` | `ANON_RESULT` |
| `apply.sql` | Triggers off, `apply_inventory`, triggers on - on every way out | `ANON_RESULT` |
| `finish.sql` | Ends a run that does not go on: CANCELLED, STOPPED | `ANON_RESULT` |
| `poll.sql` | One look at a run | `ANON_STEP`, `ANON_PROGRESS`, `ANON_LONGOP`, `ANON_RUNSTATE`, `ANON_VERIFY` |
| `stop.sql` | Asks a run to stop | `ANON_STOP` |
| `results.sql` | The figures of a run | `ANON_R_...` |
| `recover.sql` | Ends a run whose session was lost, unless that session still works; enables the triggers of OP when the run left them disabled | `ANON_RECOVER` |

`op\sql\00_run_op_anonymization.sql` runs the same steps as one script in one session, for SQL\*Plus
without the wrapper; the regression suite uses it.

---

## 9. The checks

`preflight` records each check by name in `anon_meta.anon_check`, met or not, with what it measured
and, for one not met, what happens and what to do:

| Check | Needed | Not met when |
|---|---|---|
| Identity tables | required | `tiers`, `structure` or `compte_banque` lacks a column the identities are read from, or an identifier is longer than 80 characters |
| Data not anonymized before | required | An original has the form of a replacement and no translation owns it, or a master row holds another domain's replacement: the copy was anonymized before |
| Earlier translations | required | An identity has two or more earlier translations and none matches its category now, or a recorded identity's translation is missing |
| Replacements unique | required | A planned replacement already exists, equals an original, or does not fit in seven digits |
| Replacements fit their columns | required | A column is too narrow or not text for its replacements, a `NOT NULL` free-text column cannot be masked, or an `[only-where: ...]` cannot be applied |
| Bank accounts only on the structure | info (required with `APPROVE_STRUCTURE_ONLY_ACCOUNTS=n`) | Such nodes exist and the setting says they are not bank accounts |
| Free text that cannot be emptied | info | - (says which columns get the marker) |
| Inventory objects in this database | optional (required with `FAIL_ON_MISSING_OBJECT=y`) | Inventory items are missing |

A required check not met raises `ORA-20011` (`-20012`, `-20013`, `-20016` for the specific cases):
the run ends **REFUSED** and nothing has changed. Each finding is also logged `ERROR` in
`anon_step_log` with its details.

---

## 10. Watching a run

The engine's own lines (`DBMS_OUTPUT`) appear only when a call ends, and the work is one call. So the
engine also writes, as it goes, in autonomous transactions that a second session sees at once:

| Where | What |
|---|---|
| `anon_meta.anon_step_log` | One row per inventory item, numbered by `step_id` (a sequence): the monitor reads only the rows after the last one it has shown |
| `anon_meta.anon_progress` | One row per run, rewritten before each planning stage, table or column: the phase, what the engine does in words, the items done of those planned, the object, and the same weighed by the rows of the tables (from the optimizer statistics) |
| `v$session.module` | `ANON R-000001`: the monitor finds the run's session, and the progress of a long statement in `v$session_longops`. `10_create_metadata_schema.sql` grants OP read access to these two views; without it the live lines show tables and columns only |

The live line of each kind of work shows its bar, the items done, the object with the percentage of
its long statement, the rows so far, and the time left - from the weighed progress, once there is
enough of it to say.

`tests\manual\monitor_op_progress.sql` gives a DBA the same view from SQL\*Plus.

---

## 11. Stopping, failing and resuming

### Statuses of a run

`anon_meta.anon_run.status`: `RUNNING`, then `COMPLETED`; `FAILED` on an error; `REFUSED` when the
checks found it unsafe; `CANCELLED` when it was not confirmed; `STOPPED` when it was asked to stop.

### Ctrl+C

The wrapper reads Ctrl+C as a key while sessions work. During the work it sends `run/stop.sql`
through the monitor session, which sets `anon_run.stop_requested`; the engine reads it before each
table or column (`check_stop`) and raises `ORA-20018`. `apply.sql` then enables the triggers again and
ends the run STOPPED. Before the work, the wrapper ends the run STOPPED itself once the step under way
returns. The exit code is 5.

On Linux, Ctrl+C is the SIGINT the wrapper receives - SIGTERM, from `kill`, is taken the same way -
and `sqlplus` never receives it (section 8). A SIGHUP, when the terminal closes, stops nothing: the
run goes on to its end without its screen, and leaves its folder.

### Failures

An error ends the run FAILED with the error recorded (`anon_run.error_text`, `anon_step_log`). The
triggers of OP are enabled again on every way out of `apply.sql`. If the worker's session itself is
lost, the wrapper runs `run/recover.sql` through the monitor session; after a closed window, an
operator runs it by hand. It changes nothing while the run's database session is still there - a
lost connection does not stop a call under way, and the run then ends by itself - and otherwise
records the run FAILED and, when the run had disabled the triggers of OP and not enabled them
again, enables them.

### Resuming is running again

Every operation is a no-op when its work is done, and the translations are reused, never
regenerated, so a new run converges on the same result whether the previous one reached 5% or 95%:

| Rule | Why a second pass changes nothing |
|---|---|
| `CODE` | It matches originals only; a replacement is not an original |
| `NULL_OUT` | It matches values that are not empty (or not the marker) |
| `DESCRIPTION` / `SELF_CODE` | They match values that differ from the owner's replacement |
| Identities | Captured once; a row already renamed is read back to its original through its own domain's translation |

There is no checkpoint: the whole inventory is applied again. That is correct whatever changed in
between, at the cost of reading every table again.

---

## 12. The dry run

`/dryrun` runs the same checks and plans the same translations, then counts - with the same lookups,
filters and statements as a run, but `SELECT COUNT(*)` instead of `UPDATE` - what each table and
column would change. Nothing in OP and nothing in `code_map` or `identity_inventory` changes.

It also gives a rough estimate of a run's time: the planning it took, the rows to change at the rate
of the last completed run on this database (rows changed per second of work) - or else its own scans
plus a default rate - and one more pass for the verification (`anon_engine.estimate`).

---

## 13. Verification

`op\verify\verify_op_coverage.sql` checks the result against the plan of the latest completed run and
the same inventory the engine used. Results go to `anon_meta.verify_result`.

| Part | Checks |
|---|---|
| Identities | Each identity has exactly one translation of its own domain; masters and nodes carry it; classification unchanged since capture |
| Residual identifiers | For every identifier column: is an original of its domain, or of the other one, still there? Is a replacement of the wrong domain there? **The primary test** |
| Free text | Every `NULL_OUT` column is empty or holds the marker |
| Labels and attributes | Each holds its owner's replacement; no empty field was filled in |
| Mapping integrity | Replacements unique, of their own domain, none equal to an original |
| Protections switched off | What each switch at `n` left in place |
| Prefix conformance | How much of each master column carries a prefix: information only |

It asks *"is any value here still an original?"* - a question with a definite answer - rather than
*"does this value look anonymized?"*. A currency code, a product code or a system value in an
identifier column is not a failure; values that are no recorded identifier are counted as a warning,
outside the verdict (a client code among them belongs in `anon_meta.confirmed_identity`). Every
prefix test uses `ESCAPE`: in Oracle `_` is a wildcard.

### The verdict

| Verdict | Exit code | When |
|---|---|---|
| PASS | 0 | Every protection on, nothing original left, nothing left for review |
| FAIL | 2 | An original is still where it should have been replaced, or a replacement of the wrong domain is present |
| REVIEW REQUIRED | 3 | Values were left as they are on purpose, or a classification drifted |
| INCOMPLETE | 4 | No exposure where protection was on, but a protection was switched off |

The verification exits 1 when it cannot run; the run's exit code is then 2 - changed but not
verified is not a pass.

---

## 14. The run folder and report.html

Every run leaves `op\logs\<date>_<time>_R-<run>\`: `report.html`, `report.txt` (the engine's
lines), `verify.txt`, `console.log` (the screen and the engine), `results.txt`, `manifest.txt`
(`key=value`) and `inventory.sql`.

`report.html` is written by `anon_html.ps1` - `anon_html.awk` on Linux, which writes the same page:
the regression suite compares the two - from the files of the folder - `results.txt` above all,
which `run/results.sql` prints from what the run and the verification recorded. It **reads, never
re-checks**: there is one place that decides whether a column is clean, and the report is not it. It
holds counts and names of tables and columns only. The queries that list the unclassified parties
are printed in it for the operator to run, never run by the tool.

---

## 15. Metadata schema reference

Everything the tool stores lives in `anon_meta`, created by the first run and migrated in place by
later versions: missing columns are added and constraints widened; nothing that records an original
value is ever dropped.

| Table | Holds |
|---|---|
| `code_map` | `category`, `old_code`, `new_code`, `run_id`, `id_applied`. The translations. **Holds original client identifiers** |
| `identity_inventory` | Every original identity: `domain`, `old_code`, `category`, `x_reason`, `membership`, `map_category`. **Holds original client identifiers** |
| `confirmed_identity` | Identities confirmed by hand, for codes found only in `MIXED` or `[no-harvest]` columns. **Holds original client identifiers** |
| `reference_harvest` | Codes found only in references, by column, per run. **Holds original client identifiers** |
| `identity_plan` | What a run intends for each identity (section 6). **Holds original client identifiers** |
| `code_lookup`, `node_lookup`, `owner_key` | The lookups of the latest run, rebuilt every run. **Hold original client identifiers** |
| `anon_inventory` | The loaded inventory, with the parsed column options. Truncated and reloaded every run |
| `anon_run` | One row per run: mode, status, times, switches (`config_json`), counts found (`dataset_json`), `tool_version`, `stop_requested`, `error_text` |
| `anon_run_setting` | The three switches of each category, per run |
| `anon_step_log` | One row per inventory item per run, numbered by `step_id`: phase, object, status, rows, rows given an X_ value, milliseconds, message |
| `anon_progress` | Where a run is now (section 10) |
| `anon_check` | The checks of each run (section 9) |
| `field_baseline` | The NULL counts of attribute columns before a run masks them |
| `verify_result`, `verify_key` | The latest verification, and its scratch table |
| `unclassified_reason` | The reasons of unclassified parties, in words, with their queries |

Status values of `anon_step_log`: `OK`, `NOOP` (no row changed - worth a look on a column you
expected to change), `SKIPPED` (not in this database), `DISABLED` (switched off), `REVIEW`, `DRYRUN`
(would change *n* rows), `ERROR`.

### The atrace compatibility view

The EPF anonymization reads `atrace.ref_tables_modif` to carry the OP renames into OPPAYMENTS. The
view exposes exactly one row per identity - its own translation - and only translations a completed
run applied to identifiers (`code_map.id_applied`): one used only to mask a label never renames
anything downstream.

### After handover

```sql
DROP USER anon_meta CASCADE;
DROP USER atrace CASCADE;   -- once the EPF anonymization has run
```

---

## 16. Extending coverage

Add a line to `config\inventory_op_custom.csv` (section 3), then a dry run to check it and count what
it would change. Nothing else changes: the engine, the dry run, the verification, the report and the
coverage document read it.

`tools\generate_coverage_doc.sql` writes the coverage document from the loaded inventory, and says
what exists on the connected database.

### Choosing the rule

| The column holds | Rule | Category |
|---|---|---|
| Party codes | `CODE` | `PARTY` |
| Bank-account codes | `CODE` | `BANK_ACCOUNT` |
| Both, confirmed by review | `CODE` | `MIXED` |
| Free text or personal data | `NULL_OUT` | `NONE` |
| Personal data that must stay populated | `SELF_CODE` | the owner's domain |

Decide from what the column **holds**, not from its name: `compte_ana` (*compte analytique*, an
analytical account) holds party codes too. `tools\analyze_flag_impact.sql` measures, per column, how
many values belong to each category.

`DESCRIPTION` and `SELF_CODE` find the owner through the table's `code` column, so they apply to
tables that have one.

### Is the inventory complete?

The tool guarantees that **the inventory is followed exactly**. Whether it lists everything that
needs anonymizing is a data-classification question for the owner of the schema.
`tools\scan_for_leaks.sql` walks every character column of OP for recorded originals, as an aid to
that review.

---

## 17. Version compatibility

- **Older OP versions.** Missing tables and columns are found by the checks, logged `SKIPPED` and
  never touched. `FAIL_ON_MISSING_OBJECT=y` makes any of them a refusal.
- **Newer OP versions.** A new table or column is one line in `inventory_op_custom.csv`.
- **An `ANON_META` created by an earlier version** is migrated in place by the next run: columns
  added, constraints widened, a derived table of the earlier design dropped. Its translations are
  reused where they agree with the identity's domain and category; where they cannot be trusted, the
  checks refuse the run and say why.
- **A new kind of anonymization** - something none of the four rules expresses - needs a new rule in
  the engine and in the verification.

---

## 18. Vocabulary

The application's schema objects are never renamed. Its French vocabulary:

| Term | Means |
|---|---|
| `entite` | Legal entity |
| `portefeuille` | Portfolio |
| `tiers` | Third party; `tiers.code` is the party master |
| `compte_banque` | Bank account |
| `structure` | The structure tree: party nodes, account nodes, folders; `pere` is the parent node |
| `ecran` | The screen a node belongs to: `w_tiers` (party), `w_compte_banque` (bank account) |
| `flag_portefeuille` | `O` a portfolio, `N` an entity or a counterparty |
| `libelle` | Label |
| `adresse1`-`adresse5` | Address lines |
| `nom_pp` / `prenom_pp` | Surname / given name of a natural person |
| `email_adress` | Email address (the column's own spelling) |
| `histo_*` | History tables - the bulk of the row count |
| `compte_ana` | *Compte analytique*: an analytical account, not a bank account |

---

## 19. File reference

### What runs

| Path | Role |
|---|---|
| `op\run_op_anonymization.bat` | The entry point: starts `lib\anon.ps1` in Windows PowerShell 5.1 and returns its exit code |
| `op\lib\anon.ps1`, `anon_screen.ps1`, `anon_html.ps1` | The run, its screen, its report |
| `op/run_op_anonymization.sh` | The entry point on Linux: starts `lib/anon.sh` in bash and returns its exit code |
| `op/lib/anon.sh`, `anon_screen.sh` | The run and its screen, on Linux |
| `op/lib/anon_results.awk`, `anon_end.awk`, `anon_html.awk` | The figures of a run, the end of the run on the screen and its report, on Linux |
| `op\sql\10_create_metadata_schema.sql` | Creates or migrates `anon_meta` and the `atrace` view; the grants. Runs as SYS |
| `op\sql\21_validate_inventory.sql` | Rejects impossible rule/category pairs and misspelt options; parses the options |
| `op\sql\30_install_engine.sql` | The `op.anon_engine` package |
| `op\sql\run\*.sql` | The entry scripts (section 8) |
| `op\sql\00_run_op_anonymization.sql` | The whole run as one SQL\*Plus script |
| `op\verify\verify_op_coverage.sql` | The verification |

### Configuration

| Path | Role |
|---|---|
| `config\anonymization.template.ini` | The commented template |
| `config\anonymization.ini` | The settings of this site: a copy of the template |
| `config\inventory_op.csv` | The shipped inventory |
| `config\inventory_op_custom.csv` | The site's additions and corrections |

### Optional

| Path | Role |
|---|---|
| `tools\generate_coverage_doc.sql` | The coverage document, from the loaded inventory |
| `tools\analyze_flag_impact.sql` | What each switch governs, measured on a database |
| `tools\scan_for_leaks.sql` | Recorded originals anywhere in OP, inventory or not |
| `tests\manual\monitor_op_progress.sql` | A run's progress from SQL\*Plus |
| `tests\manual\row_counts.sql` | The size of what a run works on |
| `tests\manual\check_tables_exist.sql` | Which inventory objects exist here |
| `tests\manual\check_locks.sql` | Who holds the `anon_meta` tables (as SYS) |
| `tests\manual\typed_identity_diagnostics.sql` | Before a run, on raw data: the identities, by kind - counts only |
| `tests\manual\inspect_code_map.sql` | The translations - **shows original client values; keep its output local** |

---

## 20. Error codes

| Code | Raised by | Means |
|---|---|---|
| `ORA-20011` | `preflight` | Checks found the run unsafe. **Nothing was changed.** The run ends REFUSED |
| `ORA-20012` | `preflight` | Inventory items missing and `FAIL_ON_MISSING_OBJECT=y`. Nothing was changed |
| `ORA-20013` | `preflight` | The identity tables are not shaped as expected - usually the wrong database. Nothing was changed |
| `ORA-20014` | `configure` | A switch is neither y nor n, or `PARALLEL_DEGREE` is not a number |
| `ORA-20015` | engine | A category not valid for its rule reached the engine (the validation should have stopped it) |
| `ORA-20016` | `preflight` | An identifier is longer than the 80 characters `anon_meta` records. Nothing was changed |
| `ORA-20017` | engine | A `NOT NULL` column that is not text can be neither emptied nor masked |
| `ORA-20018` | engine | The run was asked to stop, and stopped between two columns (STOPPED) |
| `ORA-20019` | `request_stop` | The run to stop is not running |
| `ORA-20020` | validation | The inventory is empty |
| `ORA-20021` | validation | Inventory rows that cannot be applied as written; they are listed |
| `ORA-20023` | `10_create_metadata_schema.sql` | `anon_inventory` is held by another session |
| `ORA-20030` | verification | No completed run with a plan: nothing to verify |
| `ORA-20040`, `-20050`, `-20060` | tools | The coverage document, the switch analysis or the leak scan needs a loaded inventory or a completed run |

### Oracle errors worth recognising

| Code | Meaning here |
|---|---|
| `ORA-03114: not connected` | The client lost the connection: the network, not the code. Run again from a host near the database |
| `ORA-03113: end-of-file` | The server process died |
| `ORA-01407` | A column refused NULL: handled with the marker |
| `ORA-00054` | A table is held by another session |

---

## 21. Known limitations

| | |
|---|---|
| **Inventory completeness** | The tool follows the inventory exactly; whether it lists everything is a classification question for the schema owner. `tools\scan_for_leaks.sql` helps |
| **BIC components and account numbers** | Not covered: they need rules the engine does not have (a BIC mapped component by component, account numbers generated format-valid). The EPF anonymization covers them; `inventory_op_custom.csv` lists them, commented out |
| **A re-run costs a full run** | No checkpoint, by design (section 11) |
| **A stable network** | The worker session is open for the whole run. Run from a host near the database |
| **Closing the window during a run** | On Windows the triggers of OP can stay disabled until `run/recover.sql` is run. On Linux the run goes on to its end |
| **The triggers of OP** | A run disables every trigger of OP and enables every trigger again at its end - including one that was disabled before the run |
| **The estimate of a dry run** | A rough figure: statements on large tables do not scale with the rows they change |
