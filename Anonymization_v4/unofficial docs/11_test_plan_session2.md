# 11 — Test plan, session 2

For the AI agent driving the next round of testing on TANM7881.

**Read [10_test_log.md](10_test_log.md) first** — eight defects (T1–T8) were found and fixed in
session 1, and several of these tests exist because of them.

---

## State at the start of this session

| | |
|---|---|
| Database | TANM7881 — **already anonymized** by session 1 (runs 2 and 4) |
| `anon_meta.code_map` | 2,885 mappings — entity 76, portfolio 32, counterparty 761, account 2,016 |
| Last verification | `PASS` — 432 passed, 0 failed, 1 warning |
| Inventory | 580 rows: 562 shipped + 18 site-specific |
| Unrun code | `18eb3d2` — masks `NOT NULL` free text, stops double-counting preflight<br>`52c8967` — HTML coverage report, generated automatically after every execute |

**Because the database is already anonymized, most runs will be near-no-ops.** That is the point: a
run that changes nothing except what it should is the strongest evidence the engine is well-behaved.
Expect `REUSED` mappings and near-universal `NOOP`.

**Run everything from a host on the same network as the database.** Session 1 lost three runs to
`ORA-03114` from a remote workstation. It is not a code fault and it will recur.

---

## Ground rules for the agent

1. **Send the raw output.** Do not summarise into a table before reporting. Session 1's two most
   important findings came from raw output — a malformed `INSERT` statement, and a `DBMS_OUTPUT`
   line that was silently missing because `SERVEROUTPUT` was off.
2. **`SET SERVEROUTPUT ON SIZE UNLIMITED` before every anonymous PL/SQL block.** A block that
   completes with no output is not a pass; it is an unread result.
3. **Never report a `PASS` without its exit code.** `echo Exit code: %ERRORLEVEL%`.
4. **Real client values must not leave the machine.** Counts, column names and category names are
   safe. Actual codes and descriptions are not. Where a test needs values, report the shape.
5. **Stop at the first unexpected result** and report it rather than continuing.

---

## T-1 — Apply the unrun change

```batch
git pull
cd Anonymization_v4\op
run_op_anonymization.bat /dryrun
```

Expect `histo_pricing_groupe.description` to show rows that would change — it is `NOT NULL`, was
skipped in session 1, and `18eb3d2` now masks it.

```batch
run_op_anonymization.bat
sqlplus -L op/<pwd>@TANM7881 @verify\verify_op_coverage.sql
echo Exit code: %ERRORLEVEL%
```

**Pass criteria**

- `histo_pricing_groupe.description` reports `OK` with a row count
- Verification: **0 warnings** — that column was the one warning
- Run summary `skipped` is roughly **152**, not 304 — preflight no longer double-counted
- Exit code 0

**Report:** the run summary block, the verification summary, the exit code.

T-1 now also produces the new HTML report as a side effect - **T-9 reads it**, so do T-9 next.

---

## T-9 — The HTML coverage report

New in `52c8967` and **never run**. The batch now runs verification and then
`verify/generate_report.sql` automatically after a successful execute, writing
`op/logs/report_<timestamp>.html`.

T-1 already exercises this — it ends with a full execute. So this test is mostly *reading* what T-1
produced. If T-1 was run before pulling `52c8967`, run one execute first.

### T-9a — The file is produced and is valid HTML

After T-1's execute, the console should end with:

```
 COMPLETE - verified clean

 Report:  logs\report_<timestamp>.html      (open in a browser)
```

```batch
dir logs\report_*.html
```

**Pass:** a file exists, is more than ~40 KB, and opens in a browser as a formatted page.

**If it renders as raw text or looks broken**, the cause is almost always SQL\*Plus spool settings —
wrapped long lines, injected blank lines, or trailing spaces. **Send the first 40 lines**:

```batch
powershell -Command "Get-Content logs\report_<ts>.html -TotalCount 40"
```

The `<style>` block should be intact and unwrapped. A CSS rule broken across two lines mid-token is
the signature of a `LINESIZE` problem.

### T-9b — The numbers match the verifier

Open the report and compare against the verification console output from T-1.

| Report | Must equal |
|---|---|
| Verdict banner | the verifier's `RESULT:` line |
| "Columns in scope" tile | `Inventory items` — 580 |
| "Verified clean" tile | the verifier's `passed` count for parts 1–3 |
| "Rows exposed" tile | **0** on a clean run |
| "Identifiers mapped" tile | `Mappings` — 2,885 |
| Verdict-line `warnings` | the verifier's `warnings` count — **all** parts, mapping integrity included |
| Shipped section tally | 562 columns |
| "Custom-added inventory" section tally | 18 columns |
| Shipped + site-specific | **580** |

**Any disagreement between the report and the verifier is a report bug**, since the report only
reads `anon_meta.verify_result` and performs no checks of its own.

### T-9c — Row counts are populated

`52c8967` also fixed the verifier to record `total_rows` for `FREETEXT` and `LABELS`. Before that
only `RESIDUAL` did, so 115 of 580 columns would have shown a blank Rows column.

**Pass:** no `—` in the **Rows** column for any row whose status is `Pass`. A `—` is correct only
for rows marked `Not present`, `Checkbox` or `No code col`.

```sql
SELECT part, COUNT(*) AS total,
       COUNT(CASE WHEN total_rows IS NULL THEN 1 END) AS missing_total
  FROM anon_meta.verify_result
 WHERE part IN ('RESIDUAL','FREETEXT','LABELS')
 GROUP BY part;
```

**Pass:** `missing_total` equals the number of `SKIP` rows in that part and no more.

### T-9d — Regeneration is independent

```batch
sqlplus -L op/<pwd>@TANM7881 @verify\generate_report.sql
```

**Pass:** a second file appears with a new timestamp and identical content. It reads stored results,
so it must not need a run and must not change anything.

Then confirm it refuses to render nothing:

```sql
DELETE FROM anon_meta.verify_result; COMMIT;
```
```batch
sqlplus -L op/<pwd>@TANM7881 @verify\generate_report.sql
```

**Pass:** fails with `ORA-20070` saying to run the verifier first — rather than writing an empty
report. Then re-run `verify_op_coverage.sql` to restore the results.

### T-9e — A failure still produces a report

The most important behaviour, because it is when the report matters most.

Reuse T-5's missing-object row, but point it at a **real** column and force an exposure — the
simplest way is to temporarily narrow a category so the engine under-anonymizes, exactly as
`compte_ana` did in session 1. In `config/inventory_op_custom.csv`:

```csv
param_cpta_reg_gen,compte_ana,CODE,BANK_ACCOUNT,CUSTOM,T-9e deliberate regression
```

That reverts the session-1 correction. Then:

```batch
run_op_anonymization.bat
echo Exit code: %ERRORLEVEL%
```

**Pass criteria**

- The run itself succeeds; **verification fails**
- **Exit code is non-zero** — verification decides the final code
- A report is **still written**
- `param_cpta_reg_gen.compte_ana` appears in the "Custom-added inventory" section, shaded red, showing 5
  exposed rows, **sorted to the top of its table group**
- The verdict banner reads `FAIL`

**Then restore** `CODE,ANY` in the custom file and re-run to leave the database clean.

> This is a deliberate regression on a disposable instance. Do not run T-9e anywhere else.

**Report:** the exit code, the verdict banner text, and the `compte_ana` row.

---

## T-2 — Move rows from the site inventory into the shipped one

**The point of this test.** Session 1 moved 17 columns *out* of `inventory_op.csv` into
`inventory_op_custom.csv`. This tests the reverse: promoting site-specific rows into the shipped
inventory, which is what happens when the consultant decides a column belongs in the product
baseline rather than at one site.

It exercises three things never tested together: that the shipped file accepts new rows, that
removing a row from the custom file orphans nothing, and that totals stay consistent when rows move
between files.

### T-2a — Move the four counterparty attribute columns

Cut these **four lines** from `config/inventory_op_custom.csv`:

```csv
tiers,sector,SELF_CODE,COUNTERPARTY,CUSTOM,was Tier1
tiers,seniority,SELF_CODE,COUNTERPARTY,CUSTOM,was Tier2
tiers,telex,SELF_CODE,COUNTERPARTY,CUSTOM,was Tier3
tiers,type_interne,SELF_CODE,COUNTERPARTY,CUSTOM,was Tier4
```

Add them to `config/inventory_op.csv` in **SECTION 10**, immediately after the address-line block,
with `source` changed to `BASE`:

```csv
# --- Counterparty attributes. Promoted from the site inventory 2026-08-xx.
tiers,sector,SELF_CODE,COUNTERPARTY,BASE,
tiers,seniority,SELF_CODE,COUNTERPARTY,BASE,
tiers,telex,SELF_CODE,COUNTERPARTY,BASE,
tiers,type_interne,SELF_CODE,COUNTERPARTY,BASE,
```

Leave the `# SECTION 11 - MOVED OUT` comment block in place, but strike the four `was Tier1..4`
lines from its reference list so the note stays accurate.

```batch
run_op_anonymization.bat /dryrun
```

**Pass criteria**

| Line | Before | After |
|---|---|---|
| `loaded` | 580 | **580** — total unchanged |
| `shipped` | 562 | **566** |
| `site-specific` | 18 | **14** |

- The `Counterparty` attributes prompt still lists all four columns, now **without** the `[site]` tag
- Everything reports `NOOP` — the data is already anonymized, so moving a row between files must
  change nothing about the outcome

**That last point is the core assertion: where a row lives must not affect what happens to it.**

**Report:** the three inventory counts, the counterparty attributes prompt, the run summary.

### T-2b — Execute and verify

```batch
run_op_anonymization.bat
sqlplus -L op/<pwd>@TANM7881 @verify\verify_op_coverage.sql
echo Exit code: %ERRORLEVEL%
```

**Pass:** nothing reports `OK` except the two trigger steps. Verification still `PASS`, still 580
items accounted for, exit code 0.

**A single data row changing here is a failure** — it would mean moving a row altered behaviour.

### T-2c — Confirm the source column in the database

```sql
SELECT source, COUNT(*) FROM anon_meta.anon_inventory GROUP BY source;
```

Expect `BASE 566`, `CUSTOM 14`. This proves the loader reads `source` from the file rather than
inferring it, so reports that distinguish shipped from site-specific stay correct.

---

## T-3 — Override still works after the move

Session 1 added `DELETE`-before-`INSERT` so a custom row can override a shipped one. T-2 removed
four custom rows; confirm the mechanism still works.

`param_cpta_reg_gen,compte_ana,CODE,ANY,CUSTOM` should still be in the custom file and still
overriding the shipped `CODE,BANK_ACCOUNT` row.

```sql
SELECT rule, category, source FROM anon_meta.anon_inventory
 WHERE table_name = 'PARAM_CPTA_REG_GEN' AND column_name = 'COMPTE_ANA';
```

**Pass:** exactly one row — `CODE`, `ANY`, `CUSTOM`. Two rows, or `BANK_ACCOUNT`, is a failure.

---

## T-4 — Adding a genuinely new column (forward compatibility)

Tests the path a future OP version takes. Pick any **existing** OP table with a free-text column
**not** currently in the inventory — `tests/manual/check_tables_exist.sql` output or
`all_tab_columns` will find one. A low-row-count table is ideal.

Add to `config/inventory_op_custom.csv`:

```csv
<table>,<column>,NULL_OUT,NONE,CUSTOM,T-4 forward compatibility test
```

```batch
run_op_anonymization.bat /dryrun
```

**Pass:** `loaded` rises by 1, `site-specific` rises by 1, and the new column appears with a
would-change row count. Then execute, and confirm the verifier now checks it — `PART 2` count rises
by 1.

**Then remove the row and re-run the dry run.** `loaded` must return to its previous value. This
confirms coverage can be withdrawn as well as added.

**Report:** counts before, after adding, after removing.

---

## T-5 — Backward compatibility, deliberately

Add a row for a table that **does not exist** on TANM7881:

```csv
zz_does_not_exist,some_column,CODE,ANY,CUSTOM,T-5 missing object test
```

```batch
run_op_anonymization.bat /dryrun
```

**Pass:** `missing tables` rises by 1, the run **completes cleanly**, exit code 0.

Then set `FAIL_ON_MISSING_OBJECT=y` in `config/anonymization.ini` and re-run the dry run.

**Pass:** the run **fails** with `ORA-20012` naming the count, and **nothing is changed**.

Restore `FAIL_ON_MISSING_OBJECT=n` and remove the row.

**These two runs are the whole lower-version compatibility story:** tolerant by default, strict on
request.

---

## T-6 — Coverage document regeneration

Never run against a real database.

```batch
cd Anonymization_v4
sqlplus -L op/<pwd>@TANM7881 @tools\generate_coverage_doc.sql
```

Writes `op/logs/coverage.md`.

**Pass:** the file is written, its totals match the run's `loaded` count, and the per-table sections
show the promoted counterparty columns as shipped rather than site-specific.

**Report:** the first 60 lines.

---

## T-7 — Flag impact analysis

Also never run. Read-only.

```batch
sqlplus -L op/<pwd>@TANM7881 @tools\analyze_flag_impact.sql
```

**Pass:** completes, writes `op/logs/flag_impact.md`.

**Report:** the first two sections — "governed by exactly one flag" and, more importantly,
**"columns holding unmapped values"**. The second lists columns whose values belong to no source
population, which no flag setting will ever anonymize. Read it closely for anything that looks like
a client identifier.

Note the database is already anonymized, so the populations it builds are of *current* values.
Interpret accordingly — this tool is more informative on a fresh database.

---

## T-8 — Leak scan (optional, expensive)

Ignores the inventory entirely and sweeps every character column in OP for surviving original
identifiers. **This is the test for inventory completeness** — the one question verification is
structurally unable to answer.

```batch
sqlplus -L op/<pwd>@TANM7881 @tools\scan_for_leaks.sql
```

Reads the whole schema; budget the length of a full run. Set `SAMPLE_PCT = 1` in the script header
for a faster first look.

**Pass:** the "MISSED" section is empty. Anything in it is a column holding client data that nobody
listed.

Scope note: the consultant owns inventory completeness. Run this only if there is appetite for the
answer now.

---

## After the session

Append results to [10_test_log.md](10_test_log.md), newest session first, in the existing format:
what was run, what happened, what broke, what changed as a result. Record what *worked* as well —
several session 1 entries note previously untested assumptions that held, and those are worth
having.

If any test fails, capture the raw output and stop. Session 1's pattern was consistent: **one root
cause producing several error messages.** Do not fix downstream symptoms.

---

## Quick reference

| Test | What it proves | Changes data? |
|---|---|---|
| T-1 | The unrun masking change works | yes — one column |
| T-9 | The HTML report is produced, accurate, and survives a failure | T-9e only |
| T-2 | Where a row lives does not change what happens to it | no — expect zero changes |
| T-3 | Custom-overrides-shipped still works | no |
| T-4 | New columns can be added, and withdrawn | yes — one column |
| T-5 | Missing objects skip by default, fail on request | no |
| T-6 | The coverage document regenerates accurately | no |
| T-7 | Which columns each flag governs; what is unmapped | no |
| T-8 | Whether the inventory itself is complete | no |
