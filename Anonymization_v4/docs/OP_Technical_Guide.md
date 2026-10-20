# OP Anonymization — Technical Guide

**KTP Payment Factory · OP schema · version 4**

> **Out of date in parts — being rewritten.** This guide describes v4 before the typed-identity
> fix of 2026-10-20. Where it disagrees with the following, the following is right — and so are
> `config/anonymization.template.ini` and the headers of the two inventory CSVs:
>
> - **Identifiers are typed.** Every party — entity `E_`, portfolio `P_`, counterparty `T_`, and
>   the new *unclassified party* `X_`, with the reason recorded — and every bank account `CB_` is
>   classified once, from the data, before anything changes. A column only ever receives the
>   translation of the domain it holds: `PARTY`, `BANK_ACCOUNT`, `MIXED` (reviewed columns holding
>   both) or `NODE_ROLE` (the structure tree, by each node's role). The category `ANY` is gone.
> - **The three switches of a category are independent.** `ANONYMIZE_<CATEGORY>` renames
>   identifiers only; `_DESCRIPTION` and `_ATTRIBUTES` mask labels and attributes even when the
>   identifier is kept. Five categories, every switch on by default.
> - **No checkbox exceptions.** `MIN_CODE_LENGTH` and the one-character column rule are gone:
>   every listed column is processed, a one-character identifier is anonymized like any other, and
>   a column that must not be touched is left out of the inventory.
> - **Structure-only bank accounts.** A `w_compte_banque` node with no `compte_banque` row is
>   anonymized as a bank account. Never asked; `APPROVE_STRUCTURE_ONLY_ACCOUNTS=n` refuses them.
> - **Four verdicts**: PASS, FAIL, REVIEW REQUIRED, INCOMPLETE — exit codes 0, 2, 3, 4.

Everything needed to understand, operate, maintain and extend the tool. For the shorter
run-it-and-go instructions, read the *OP Anonymization — User Guide*.

---

## Contents

1. [Purpose and scope](#1-purpose-and-scope)
2. [The design principle](#2-the-design-principle-one-inventory-drives-everything)
3. [The inventory](#3-the-inventory)
4. [Configuration flags](#4-configuration-flags)
5. [Identifier generation](#5-identifier-generation)
6. [Run lifecycle](#6-run-lifecycle)
7. [Restartability](#7-restartability)
8. [Logging](#8-logging)
9. [The dry run](#9-the-dry-run)
10. [Verification](#10-verification)
11. [The HTML report](#11-the-html-report)
12. [Metadata schema reference](#12-metadata-schema-reference)
13. [Extending coverage](#13-extending-coverage)
14. [Version compatibility](#14-version-compatibility)
15. [Naming and vocabulary](#15-naming-and-vocabulary)
16. [File reference](#16-file-reference)
17. [Error codes](#17-error-codes)
18. [Known limitations](#18-known-limitations)
19. [History](#19-history)

---

## 1. Purpose and scope

The tool removes client data from a restored copy of a KTP Payment Factory database so the copy can
be used for development, testing and support.

Two schemas are in scope for the product as a whole:

| Schema | Holds | Status |
|---|---|---|
| **OP** | Core treasury — entities, portfolios, counterparties, bank accounts, and around 60 `histo_*` history tables | **This tool. Complete and tested.** |
| **EPF** (`OPPAYMENTS`) | Payment factory — payments, bulk payments, users, SWIFT/BIC data, audit trail | Not yet ported to v4. The previous-generation scripts remain in `Anonymization_EPF/`. |

v4 covers **580 columns across 167 tables**: 562 shipped plus 18 site-specific.

### What "anonymized" means here

Four treatments, declared per column:

| Rule | Effect | Typical use |
|---|---|---|
| `CODE` | The value is looked up in the mapping and replaced with its generated equivalent | Any column holding an entity, portfolio, counterparty or bank account code |
| `NULL_OUT` | Set to `NULL`. Where the column is `NOT NULL`, overwritten with the marker `ANONYMIZED` truncated to the column width | Free text and PII — names, addresses, phone, email, IBAN and RIB fragments |
| `DESCRIPTION` | Overwritten with the anonymized code of the row itself | Label columns, so screens stay readable: a counterparty shows as `T_0000412` rather than blank |
| `SELF_CODE` | Overwritten with the anonymized code of the row itself | A PII attribute that must stay populated because it is `NOT NULL` or subject to a format check |

### What is deliberately not anonymized

- **Amounts, dates, currencies, product and system codes.** They carry no client identity and
  changing them would break reconciliation and reporting.
- **One-character columns.** A single character is a checkbox state (`O`, `x`, `N`) far more often
  than a client identifier, and substituting it would rewrite every matching flag in the schema.
  Governed by `MIN_CODE_LENGTH`, default 2.
- **Structural referential data** that has no client content.

---

## 2. The design principle: one inventory drives everything

Every `(table, column, rule, category)` pair is declared **once**, in a CSV. That one declaration
drives four separate things:

```
                     config/inventory_op.csv
                   + config/inventory_op_custom.csv
                              │
                              ▼
                   anon_meta.anon_inventory
                              │
        ┌─────────────┬───────┴────────┬─────────────────┐
        ▼             ▼                ▼                 ▼
    the engine    the dry run      the verifier    the coverage doc
```

Coverage drift becomes structurally impossible: the script that changes the data, the check that
proves it changed, and the document that describes it cannot disagree, because they read the same
rows.

This is the central fix over v3, where the anonymization scripts and the verification script each
maintained their own hand-edited table list. By the time v4 was written the two lists had already
drifted apart, and the documentation described a third list that matched neither.

A second consequence: **custom inclusions stop being a special case.** They are simply additional
rows from a second CSV, parsed by the same loader and treated identically downstream.

---

## 3. The inventory

### Format

```csv
table_name,column_name,rule,category,source,notes
structure,code,CODE,ANY,BASE,
prevision_param,compte,CODE,BANK_ACCOUNT,BASE,
cm_pooling_convention,value_1,NULL_OUT,NONE,BASE,
```

| Field | Meaning |
|---|---|
| `table_name` | Table in the OP schema |
| `column_name` | Column to anonymize |
| `rule` | `CODE` · `NULL_OUT` · `DESCRIPTION` · `SELF_CODE` |
| `category` | `ENTITY` · `PORTFOLIO` · `COUNTERPARTY` · `BANK_ACCOUNT` · `ANY` · `NONE` |
| `source` | `BASE` (shipped) or `CUSTOM` (site file) |
| `notes` | Documentation only, never interpreted. **No commas.** |

Lines starting with `#` are ignored. Blank lines are ignored. Values are case-insensitive.

### What `category` means, per rule

- On **`CODE`** it says which slice of the mapping may apply.
  - `BANK_ACCOUNT` restricts lookups to bank-account codes. This is necessary because a
    `compte_banque.code` can be textually identical to a `tiers.code`; without the restriction a
    column referencing one would be rewritten using the other's mapping.
  - `ANY` means the column may hold an entity, portfolio or counterparty code, and the mapping is
    searched unrestricted.
- On **`DESCRIPTION`** and **`SELF_CODE`** it says which entity type owns the row, so the correct
  per-category configuration flag gates it.
- On **`NULL_OUT`** it is always `NONE`. Free text is never category-dependent.

> **`BANK_ACCOUNT` is a narrowing, and narrowing can be wrong.** A column classified
> `CODE,BANK_ACCOUNT` that actually holds another category's codes will be under-anonymized, and the
> engine will not notice. This happened in testing: `param_cpta_reg_gen.compte_ana` — *compte
> analytique*, an analytical account — was classified `BANK_ACCOUNT` purely because its name
> contains `compte`, and five rows of live client data survived a run that reported success. See
> [§10](#10-verification) for what changed as a result.

### Current composition

| Rule | Category | Shipped | Custom |
|---|---|---:|---:|
| `CODE` | `ANY` | 390 | 1 |
| `CODE` | `BANK_ACCOUNT` | 72 | — |
| `NULL_OUT` | `NONE` | 92 | — |
| `DESCRIPTION` | `ANY` | 2 | — |
| `DESCRIPTION` | `BANK_ACCOUNT` | 1 | — |
| `SELF_CODE` | `ANY` | 5 | — |
| `SELF_CODE` | `ENTITY` | — | 5 |
| `SELF_CODE` | `PORTFOLIO` | — | 5 |
| `SELF_CODE` | `COUNTERPARTY` | — | 4 |
| `SELF_CODE` | `BANK_ACCOUNT` | — | 3 |
| | **Total** | **562** | **18** |

580 rows in the files; **579 loaded**, because one custom row (`param_cpta_reg_gen.compte_ana`)
overrides a shipped row rather than adding to it.

### Overrides

The two files are parsed in order, base then custom. For each custom row the loader emits a `DELETE`
before its `INSERT`, so a row in the custom file **replaces** the shipped row for the same
`(table, column)`.

That is how a wrong classification in the shipped inventory gets corrected at a site without editing
a file that will be overwritten by the next release. The primary key on
`(table_name, column_name)` makes the delete necessary — without it a second row for the same column
raises `ORA-00001`.

### How the CSVs reach the database

The CSVs live on the client, not necessarily on the database server, so they cannot be read as
external tables. `run_op_anonymization.bat` parses them and writes a temporary SQL file of `INSERT`
statements, which the orchestrator runs. On failure that file is **kept** and its path printed —
which is the only reason a batch quoting defect that had corrupted roughly 500 of 579 statements was
ever found.

---

## 4. Configuration flags

### Where they take effect

Configuration says which categories to anonymize. v4 enforces that **at mapping generation, not at
each column**:

```
ANONYMIZE_COUNTERPARTY=n
   └─ no COUNTERPARTY rows are generated in anon_meta.code_map
        └─ every CODE column finds no match for counterparty values
             └─ counterparty codes are left alone, everywhere, automatically
```

This is why v4 has no per-column conditionals. v3 needed roughly 200
`IF flag = 'y' THEN … ELSE …` blocks to achieve the same thing in two of its scripts, and got it
wrong in a third, which ignored the flags entirely while documenting that it honoured them.

### The mental model to correct

**Disabling a category does not remove columns from the run.** Every column is still visited and its
`UPDATE` still executes. What changes is what is in the mapping — and a value that is not in the
mapping is left alone. So one column can be *partly* anonymized:

```
ANONYMIZE_COUNTERPARTY=n
   └─ the UPDATE on histo_flux.tiers still runs
        ├─ rows holding a counterparty code:  no match, left as-is
        └─ rows holding an entity code:       still replaced
```

The consequence: **a flat covered/skipped list cannot be produced from the CSV alone.** For a
`CODE,ANY` column the answer depends on what values the column actually holds on a given instance.

The exception is `CODE,BANK_ACCOUNT`. Those only ever look at bank-account codes, so the flag
genuinely is a whole-column on/off switch and the answer *is* knowable in advance.

| Rows | Rule + category | Governed by | Predictable from the CSV alone? |
|---:|---|---|---|
| 72 | `CODE` + `BANK_ACCOUNT` | `ANONYMIZE_BANK_ACCOUNT` | **Yes — off means the column is 100% untouched** |
| 391 | `CODE` + `ANY` | all four category flags, per value | No — depends on instance data |
| 92 | `NULL_OUT` | nothing | **Yes — always erased** |
| 3 | `DESCRIPTION` | `ANONYMIZE_*_DESCRIPTION` | Yes |
| 5 | `SELF_CODE` + `ANY` | any `ANONYMIZE_*_ATTRIBUTES` | Yes |
| 17 | `SELF_CODE` + category | that category's `_ATTRIBUTES` | Yes |

`tools/analyze_flag_impact.sql` resolves the remaining 391 against a real instance.

### The three flag families

| Flag | Gates | Replaces |
|---|---|---|
| `ANONYMIZE_<CATEGORY>` | `CODE` — whether the category's identifiers are mapped at all | v2's `Ent0` + `EntC` |
| `ANONYMIZE_<CATEGORY>_DESCRIPTION` | `DESCRIPTION` — the label column | `EntD` / `FoldD` / `TierD` / `CpteD` |
| `ANONYMIZE_<CATEGORY>_ATTRIBUTES` | `SELF_CODE` — the extra PII attribute columns | `Ent1`–`Ent5` and the equivalents |

Descriptions and attributes are gated separately because the vendor package separated them, and the
separation is useful: a support copy often wants readable labels while still scrubbing phone numbers
and personal names.

Both require their own category to be enabled, because both write the row's anonymized identifier —
without a mapping there is nothing to write.

`NULL_OUT` has no flag. Free text and PII are always erased.

### What replaced the `Ent1`–`Ent5` slots

In v2 each category had five free-form slots holding column names, applied only to `op.tiers` and
`op.compte_banque`. **Which** columns are treated this way is now declared in the inventory with
rule `SELF_CODE`, so there is no five-column ceiling and no table restriction. The flags remain as
the on/off switch those slots gave you by being left blank.

The 17 `SELF_CODE` rows in `inventory_op_custom.csv` are what one site had put in those slots. They
live in the custom file precisely because they are that site's choice, not a product default.

---

## 5. Identifier generation

Codes are generated **deterministically and set-based**:

```sql
INSERT INTO anon_meta.code_map (category, old_code, new_code)
SELECT :category, code,
       :prefix || LPAD(ROW_NUMBER() OVER (ORDER BY code), 7, '0')
  FROM (<category source query>);
```

| Category | Prefix | Width |
|---|---|---|
| Entity | `E_` | 9 |
| Portfolio | `P_` | 9 |
| Counterparty | `T_` | 9 |
| Bank account | `CB_` | 10 |

Uniqueness is guaranteed by construction, so there is no collision probe and no retry loop. The
whole mapping is produced in one statement per category rather than one round-trip per code, and the
result is reproducible — the same source data always yields the same mapping.

v3 instead drew a random 7-digit number per code, queried the mapping table to check for a
collision, and retried up to 100 times.

**Width is checked before any data is touched.** Preflight compares the generated width against
`all_tab_columns` for every `CODE` column in the inventory and refuses to start if a target is too
narrow. v3 would have discovered that as an `ORA-12899` partway through a run it could not resume.

### `code_map_any`

A second table holds the resolved unrestricted lookup — one row per distinct original, with
collisions across categories resolved by priority (entity > portfolio > counterparty > bank
account). `CODE,ANY` columns read this; `CODE,BANK_ACCOUNT` columns read `code_map` filtered to that
category.

Six originals currently exist in more than one category. Verification reports them as an
informational warning; they were reviewed and are correct by design.

---

## 6. Run lifecycle

```
run_op_anonymization.bat
   ├─ settle configuration (file, prompts, defaults)
   ├─ parse both CSVs into a temporary INSERT script
   └─ sqlplus @sql/00_run_op_anonymization.sql  (22 positional parameters)
        ├─ connect as SYS
        ├─ @@10_create_metadata_schema.sql      create anon_meta if absent; truncate the inventory
        ├─ connect as OP, assert the connection landed
        ├─ @@30_install_engine.sql              compile the anon_engine package
        ├─ @<temporary inventory script>        load 579 rows
        ├─ @@21_validate_inventory.sql          reject impossible rule/category pairs
        ├─ anon_engine.configure / start_run
        ├─ anon_engine.preflight                DRY RUN STOPS HERE
        ├─ disable triggers            (45 on the tested instance)
        ├─ generate or reuse the mapping
        ├─ apply the inventory         NULL_OUT → CODE → DESCRIPTION/SELF_CODE
        ├─ re-enable triggers          (runs even when the run fails)
        └─ finish_run
   ├─ verify/verify_op_coverage.sql            after a successful EXECUTE
   └─ verify/generate_report.sql               always, even when verification fails
```

Triggers are re-enabled by a handler that runs before the error propagates, so a failed run does not
leave the schema with its audit triggers off.

Verification's exit code is captured and becomes the batch's exit code. The report is generated
either way, because a failed verification is exactly when it is most wanted.

---

## 7. Restartability

**A failed run can be re-run directly. No restore, no flag, no checkpoint.**

The guarantee is that every operation is a no-op when its work is already done, so re-executing the
whole inventory converges on the same result whether the previous run reached 5% or 95%.

| Rule | Why a second pass changes nothing |
|---|---|
| `CODE` | Matches `WHERE column IN (SELECT old_code …)`. An already-substituted value is a *new* code, which is not in `old_code`, so it does not match. |
| `NULL_OUT` | Matches `WHERE column IS NOT NULL`. Already empty, nothing to do. |
| `DESCRIPTION` / `SELF_CODE` | Matches only rows where the column does not already equal its row's code. |
| Mapping | Reused, never regenerated — identifiers stay stable across runs. |

### It does not skip completed steps

There is no checkpoint; the whole inventory is re-executed. That is deliberate — skipping based on a
previous run's log would be wrong the moment the configuration changed or the database was partially
restored, whereas idempotent re-execution is correct in every case.

**The cost:** a re-run re-scans every table and takes roughly as long as the original even though it
changes almost nothing.

### What a clean re-run looks like

```
mapping ................ REUSED  (n existing mappings)
NULL_OUT items ......... NOOP
CODE items ............. NOOP
DESCRIPTION / SELF_CODE  NOOP
```

`REUSED` on all four categories is the signal that the mapping survived. Identifiers being
*generated* instead means `anon_meta` was dropped and the previous run's work can no longer be
reconciled — restore and start over.

This was proven directly: runs 3 and 4 against an already-anonymized instance showed the dry run
predicting exactly one change and the execute making exactly that one change.

### When you must not re-run

**After restoring the database.** The mapping refers to values the restore has put back, so the two
are out of step. `DROP USER anon_meta CASCADE` first.

> This is the behaviour not to take for granted if you have used v3. There, every run dropped the
> mapping table and generated fresh random identifiers, so a failed run left renamed rows whose
> originals could no longer be recovered.

---

## 8. Logging

Every inventory item produces exactly one `anon_step_log` row — **including items that changed zero
rows**.

| Status | Meaning |
|---|---|
| `OK` | Applied, *n* rows changed |
| `NOOP` | Applied, 0 rows changed — already clean, or nothing matched |
| `SKIPPED` | Table or column does not exist here (`ORA-00942` / `ORA-00904`) |
| `DISABLED` | Excluded by configuration |
| `ERROR` | Anything else — the run fails |

The `NOOP` / `SKIPPED` distinction is the point. v3's `merge_codes` printed nothing at all when zero
rows matched, so a misspelled column name and a genuinely clean column produced identical output:
silence.

Errors other than missing-object are not swallowed. The orchestrator runs under
`WHENEVER SQLERROR EXIT FAILURE`, so a failed run returns a non-zero exit code.

### Live progress

The step log is written through an **autonomous transaction**, so progress is visible from a second
session immediately, even though SQL\*Plus will not print `DBMS_OUTPUT` until the block finishes:

```batch
sqlplus op/<pwd>@<TNS> @tests\manual\monitor_op_progress.sql
```

### Counters

The run summary counts each object once. Preflight visits every object too, and until this was fixed
both visits were counted — a run reporting `skipped 304` was describing 152 objects.

---

## 9. The dry run

`/dryrun` runs the same code path with `p_dry_run => TRUE`. It:

- resolves every inventory row against `all_tab_columns` and reports what is missing here,
- checks generated code width against every `CODE` target,
- identifies one-character columns and reports that they will be left alone,
- identifies `NOT NULL` free-text columns that cannot be emptied,
- counts the rows each item *would* change,
- writes `DRYRUN` rows to the step log,
- issues **no DML**, and
- **exits non-zero if any check fails.**

It is a rehearsal, not a summary. v3's `/dryrun` lived entirely in the batch file, echoed a hardcoded
list of five filenames — three of which the real run did not execute — issued four `COUNT(*)`
queries, never consulted the inventory, and could not fail.

---

## 10. Verification

`verify/verify_op_coverage.sql` reads the same inventory the engine used, so it cannot check a
different set of columns than the one that was anonymized. Results are written to
`anon_meta.verify_result` and the script exits non-zero on any failure.

| Part | Question | Pass/fail? |
|---|---|---|
| 1 | Does any **original identifier** still exist in any identifier column? | **Yes — this is the test** |
| 2 | Is every free-text / PII column empty or masked? | Yes |
| 3 | Do anonymized rows agree with their own code? | Warning only |
| 4 | Is the mapping unique, complete and unambiguous? | Yes |
| 5 | How much of each identifier column carries a prefix? | Informational |

### Residual detection, not prefix matching

Part 1 asks *"is any value here still one of the originals?"* — a question with a definite answer
that cannot be fooled.

The older scripts instead asked *"does this value look anonymized?"* by testing a prefix. That is
weaker in two ways:

1. **It produced false passes.** The OP script used `LIKE 'E_%'` — and in Oracle `_` is a
   single-character wildcard, so a real currency code `EUR` matched and was counted as anonymized.
   Every prefix test in v4 uses `ESCAPE`, as the EPF script correctly did.
2. **Even written correctly, it asks the wrong question.** Plenty of values legitimately have no
   prefix — currency codes, product codes, system references that were never client data. Those are
   not failures. Prefix conformance is reported as information, not pass/fail.

### Part 1 deliberately does not mirror the engine

An earlier version restricted `BANK_ACCOUNT` columns to bank-account codes, exactly as the engine
does. That meant a column whose declared category was too narrow was missed by the engine **and** by
the check meant to catch it. Both agreed; both were wrong. On the test instance that hid five live
client codes in `param_cpta_reg_gen.compte_ana`, and verification reported `PASS`.

Part 1 now searches the **full** mapping regardless of the declared category. The verifier's job is
to test the outcome, not to re-apply the engine's assumptions. Any original left anywhere is a leak,
whatever category it belongs to.

**The general rule this illustrates:** it is legitimate for the checker to share a *definition* with
the engine — what an anonymized value looks like. It is not legitimate for it to share an
*assumption* about where to look.

### Things that are deliberately not failures

- **One-character columns.** The engine leaves them alone by design, so failing them would mean a
  correct run could never pass.
- **`NOT NULL` free text.** It cannot be emptied. It is masked with `ANONYMIZED` where the column is
  character-typed; where it is not, the gap is reported as a warning — loud, but not a run failure.
- **Missing objects.** Reported as `SKIP`, with a row count of nothing.

---

## 11. The HTML report

`verify/generate_report.sql` writes `op/logs/report_<timestamp>.html` — a single self-contained file
with inline CSS and no external dependencies.

### It reads, it never re-checks

Every number comes from `anon_meta.verify_result`, joined to `anon_inventory` and `anon_run`. The
report performs no verification of its own.

That is deliberate. Duplicating the check logic is exactly how the engine and the verifier came to
share one wrong assumption and both miss five live client codes. There is one place that decides
whether a column is clean, and the renderer is not it.

If `verify_result` is empty the script raises `ORA-20070` and stops, rather than rendering an empty
report that would look like a pass.

### Structure

| Section | Contents |
|---|---|
| Verdict banner | `PASS` / `FAIL` with the headline figures |
| Six tiles | Columns in scope · verified clean · rows exposed · not on instance · identifiers mapped · rows changed |
| Coverage by treatment | One row per rule, with columns / clean / exposed / not checked |
| Shipped inventory | Every column from `inventory_op.csv`, grouped by table |
| Custom-added inventory | The same for `inventory_op_custom.csv` |
| Not checked on this instance | Tables absent here, grouped, with the reason |
| Mapping integrity | Uniqueness, completeness, per-category counts |

Failures sort to the top **within each table group** and are shaded, so nothing needing action can be
buried a few hundred rows down.

### Clean and Exposed, not anonymized and not-anonymized

| Column | Means |
|---|---|
| **Rows** | Every row in the column |
| **Exposed** | Rows still holding an original client value — the only figure that should ever be non-zero |
| **Clean** | Rows − Exposed |

A `CODE` column can legitimately hold currency codes, product codes and system references that were
never client data and correctly carry no prefix. Counting those as "not anonymized" would show
alarming figures on a perfectly clean database — the trap the v3 verifier fell into.

### Regenerating

It reads stored results, so it can be re-run at any time without a run and without changing
anything. It always reflects the most recent verification.

---

## 12. Metadata schema reference

Everything the tool stores lives in `anon_meta`, created on first run and never dropped as part of a
run.

| Object | Purpose |
|---|---|
| `code_map` | `category`, `old_code`, `new_code`. The mapping. Retained across runs. |
| `code_map_any` | Resolved unrestricted lookup — one row per distinct original, cross-category collisions resolved by priority |
| `anon_inventory` | The loaded inventory. Truncated and reloaded each run. PK `(table_name, column_name)` |
| `anon_run` | One row per run: `run_id`, `run_mode` (`EXECUTE` / `DRYRUN`), `status`, timestamps, `config_json` |
| `anon_step_log` | One row per inventory item per run: `phase`, `object_name`, `rows_affected`, `elapsed_ms`, `status`, `message` |
| `verify_result` | One row per check: `part`, `check_name`, `expectation`, `total_rows`, `bad_rows`, `status`, `detail` |
| `atrace.ref_tables_modif` | A view over `code_map` in a separate schema, for EPF compatibility |

> `anon_run.run_mode` is not called `mode`. `MODE` is an Oracle reserved word, and naming the column
> that caused the first live test to fail with `ORA-00904` plus four cascading errors. Quoting it as
> `"MODE"` would have worked but would have made the identifier case-sensitive forever.

### The `atrace` compatibility surface

EPF's cascade phase reads `atrace.ref_tables_modif`. v4 exposes that name and shape as a view over
`code_map` so the existing EPF scripts keep working until EPF is ported.

A view compiles with its **owner's** rights, so `atrace` needs its own `SELECT` on
`anon_meta.code_map`, granted `WITH GRANT OPTION` so it can pass the privilege on to `op`. Missing
that produced an `ORA-00942` on view creation that looked like a missing schema and was not one.

### After handover

```sql
DROP USER anon_meta CASCADE;
DROP USER atrace CASCADE;   -- only once EPF has also run
```

`code_map` maps every anonymized identifier back to the real one. It is kept so a failed run can
resume and so verification can be re-run — not as a key to hold on to.

---

## 13. Extending coverage

Add a line to `config/inventory_op_custom.csv`:

```csv
my_new_table,entity_code,CODE,ANY,CUSTOM,Added for the 2026 module
my_new_table,contact_email,NULL_OUT,NONE,CUSTOM,
```

Then dry-run to confirm it resolves, run for real, and optionally regenerate the coverage document:

```batch
sqlplus op/<pwd>@<TNS> @tools\generate_coverage_doc.sql
```

No SQL changes anywhere. The engine, the dry run, the verifier, the report and the coverage document
all pick it up.

### Choosing the rule

| Situation | Rule | Category |
|---|---|---|
| Holds an entity / portfolio / counterparty code | `CODE` | `ANY` |
| References `compte_banque.code` | `CODE` | `BANK_ACCOUNT` |
| Free text or PII | `NULL_OUT` | `NONE` |
| PII that must stay populated (`NOT NULL`, format check) | `SELF_CODE` | the owning category |

`SELF_CODE` requires the table to have a `code` column, since the value written *is* that row's
anonymized code. The `histo_*` tables do not have one, which is why a `NOT NULL` free-text column
there is masked rather than self-coded.

### Is the inventory complete?

The tool guarantees that **the inventory is followed exactly**. It cannot know whether the inventory
lists everything that needs anonymizing — that is a data-classification question for whoever owns the
schema. `tools/scan_for_leaks.sql` samples the schema for values that look like client identifiers
but are not in the inventory, as an aid to that review.

---

## 14. Version compatibility

### Older OP versions — supported

The shipped inventory spans several KTP/CTI releases. On the tested instance 147 of 580 items did
not exist, and the run completed cleanly: missing objects are resolved at preflight, logged as
`SKIPPED`, and never touched.

Set `FAIL_ON_MISSING_OBJECT=y` for a strict run where any drift from the inventory is a failure.

### Newer OP versions — supported

Adding coverage for a new table or column is one line in `inventory_op_custom.csv`. No SQL, no
release of the tool. This path is proven: the `compte_ana` correction was delivered exactly this way.

### What would need real work

A new *kind* of anonymization — something none of the four rules expresses. That means a new rule in
the engine and matching handling in the verifier. Nothing currently on the horizon needs one.

---

## 15. Naming and vocabulary

Our own objects use English names. The vendor's schema objects are **never** renamed — doing so would
break the application.

| v3 | v4 |
|---|---|
| `atrace` (schema) | `anon_meta` |
| `pack_anonym` | `anon_engine` |
| `merge_codes` | `anon_engine.apply_code_mapping` |
| `generate_unique_mappings` | `anon_engine.generate_code_map` |
| `op_code_mapping` | `code_map` |
| `EntC` / `FoldC` / `TierC` / `CpteC` | `ANONYMIZE_ENTITY` / `_PORTFOLIO` / `_COUNTERPARTY` / `_BANK_ACCOUNT` |
| `ENTITE` / `PORTEFEUILLE` / `TIERS` / `COMPTE` | `ENTITY` / `PORTFOLIO` / `COUNTERPARTY` / `BANK_ACCOUNT` |

### The vendor's French vocabulary

| Term | Means |
|---|---|
| `entite` | Legal entity |
| `portefeuille` | Portfolio |
| `tiers` | Counterparty / third party |
| `compte_banque` | Bank account |
| `structure` | The entity table |
| `libelle` | Label, description |
| `adresse1`–`adresse5` | Address lines |
| `nom_pp` / `prenom_pp` | Surname / given name of a natural person |
| `email_adress` | Email address (the vendor's spelling) |
| `histo_*` | History tables — the bulk of the row count |
| `compte_ana` | *Compte analytique* — an **analytical** account, not a bank account |

That last one is not trivia. It is the word that caused a misclassification which survived a full run
and a verification pass.

---

## 16. File reference

### What runs

| Path | Role |
|---|---|
| `op/run_op_anonymization.bat` | The only entry point. Settles configuration, turns the CSVs into loadable SQL, calls SQL\*Plus, returns its exit code. No logic. |
| `op/sql/00_run_op_anonymization.sql` | Orchestrator. 22 positional parameters. |
| `op/sql/10_create_metadata_schema.sql` | Creates `anon_meta` and the `atrace` view. Runs as SYS. |
| `op/sql/21_validate_inventory.sql` | Rejects impossible rule/category pairs before anything runs. |
| `op/sql/30_install_engine.sql` | The `anon_engine` package — 23 procedures and functions. |
| `op/verify/verify_op_coverage.sql` | The five-part check. Writes `verify_result`. Non-zero exit on failure. |
| `op/verify/generate_report.sql` | Renders the HTML report from stored results. |

### Configuration

| Path | Role |
|---|---|
| `config/anonymization.template.ini` | Fully commented template. Copy it. |
| `config/anonymization.ini` | Your settings. **Not in version control** — it is the file that ends up holding a real SID and possibly passwords. |
| `config/inventory_op.csv` | Shipped coverage, 562 rows |
| `config/inventory_op_custom.csv` | Site additions and corrections, 18 rows |

### Optional

| Path | Role |
|---|---|
| `tools/generate_coverage_doc.sql` | Writes the coverage document from the loaded inventory |
| `tools/analyze_flag_impact.sql` | Resolves what each flag actually governs against a real instance |
| `tools/scan_for_leaks.sql` | Samples the schema for identifier-shaped values not in the inventory |
| `tests/manual/monitor_op_progress.sql` | Live progress from a second session |
| `tests/manual/row_counts.sql` | What you are dealing with, before you start |
| `tests/manual/check_tables_exist.sql` | Which inventory objects exist here |
| `tests/manual/check_locks.sql` | Who is holding what |
| `tests/manual/inspect_code_map.sql` | Mapping contents — **shows real client values; keep local** |

`tests/manual/` is ad-hoc only and never part of a run.

### Everything else

`unofficial docs/` holds the working notes from the rebuild: the test log, the defect record, open
questions, the flag-impact analysis, and the session-2 test plan. They are accurate but are working
documents, not deliverables.

---

## 17. Error codes

| Code | Raised by | Means |
|---|---|---|
| `ORA-20010` | engine | No category is enabled — every `ANONYMIZE_*` flag is `n` |
| `ORA-20011` | preflight | Columns cannot hold a generated identifier: too narrow, or not character-typed. **Nothing was changed.** |
| `ORA-20012` | preflight | Inventory items missing and `FAIL_ON_MISSING_OBJECT=y`. Nothing was changed. |
| `ORA-20013` | engine | Core entity tables not shaped as expected — no identifiers can be derived. Usually the wrong database. |
| `ORA-20020` | validation | The inventory is empty — CSV not found, or every line is a comment |
| `ORA-20021` | validation | Rows pair a rule with a category that cannot apply |
| `ORA-20023` | setup | `anon_inventory` is locked by another session. The message names the holder. |
| `ORA-20030` | verify | `code_map` is empty — nothing to verify |
| `ORA-20031` | verify | Checks failed — client data is still present |
| `ORA-20070` | report | `verify_result` is empty — run the verifier first |

### Oracle errors worth recognising

| Code | Meaning here |
|---|---|
| `ORA-03114: not connected` | The client had already lost the connection. Network, not code. |
| `ORA-03113: end-of-file` | The server-side process died. Different problem, different fix. |
| `ORA-00942` / `ORA-00904` | Missing table / column. Caught and logged as `SKIPPED`, not an error. |
| `ORA-01407` | Cannot set a `NOT NULL` column to `NULL`. Handled by masking. |

---

## 18. Known limitations

| | |
|---|---|
| **Inventory completeness is out of scope** | The tool guarantees the inventory is followed exactly. Whether the inventory lists everything that needs anonymizing is a classification question for the schema owner. `tools/scan_for_leaks.sql` assists. |
| **A re-run costs a full run** | No checkpointing, by design. See [§7](#7-restartability). |
| **Passwords are visible in the process list** | They are passed to SQL\*Plus as arguments. Inherited from v3, normal for an internal DBA tool, worth knowing on a shared host. |
| **The run needs a stable network** | One session for the length of the run. Run from a host near the database. |
| **`NOT NULL` free text on non-character columns** | Cannot be emptied or masked. Reported as a warning; there is currently one such column. |
| **EPF is not ported** | `Anonymization_EPF/` still holds the previous-generation scripts. The v4 verifier already carries EPF's best idea — residual detection — so the port is mostly a second inventory. |

---

## 19. History

| When | What | Result |
|---|---|---|
| Feb 2021 | Vendor base — `pack_anonym`, per-entity iterative rename, 98 audit triggers | 8–12 hour runtime |
| v2 | Batch driver with interactive prompts | — |
| v3 | Set-based rewrite: bulk pre-clear plus `MERGE`/`UPDATE` against a mapping table | 20–40 minutes |
| Jul 2026 | KTP/CTI table scope added, then CTI tables, then `/dryrun` and custom inclusions | Each addition brought its own numbered script and its own hand-maintained table list |
| Aug–Sep 2026 | **v4** — rebuilt around a single inventory | 580 columns, 167 tables, reconciled against v3 |

### What v4 fixed

Eleven defects were found by reading v3, including: custom inclusions could never work (the table
holding them was dropped before it was read); folder layout did not match the paths the scripts
resolved, so neither orchestrator could run; re-running after a partial failure destroyed the link
between original and anonymized values; `DROP USER atrace CASCADE` destroyed the EPF cascade source;
and the OP verifier's unescaped `LIKE 'E_%'` systematically overstated coverage.

Roughly 200 KB of the 340 KB v3 codebase was unreachable and was not carried forward.

### What real testing found

Eight further defects (T1–T8) were found and fixed by running v4 against a live instance — a reserved
word used as a column name, a privilege chain on the compatibility view, a nested aggregate, a batch
quoting bug that corrupted roughly 500 of 579 `INSERT` statements, and the `compte_ana`
misclassification that the verifier shared and therefore could not catch.

### The result

| | |
|---|---|
| Mapping | 2,885 identifiers — 76 entity, 32 portfolio, 761 counterparty, 2,016 bank account |
| Rows changed | 44,460,155 |
| Duration | 29 minutes |
| Errors | 0 |
| Triggers | 45 disabled and re-enabled |
| Verification | 432 passed, 0 failed |
| Restartability | Proven — the dry run predicted exactly one change and the execute made exactly that one change |
