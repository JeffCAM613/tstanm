# OP Anonymization — User Guide

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
> - **A new scope decision**, `APPROVE_STRUCTURE_ONLY_ACCOUNTS`, for account nodes that have no
>   `compte_banque` row.
> - **Four verdicts**: PASS, FAIL, REVIEW REQUIRED, INCOMPLETE — exit codes 0, 2, 3, 4.

This guide is for the person who runs the tool. It covers everything you need to complete a run
successfully: what to prepare, what to type, what you will see, and how to confirm it worked.

You do not need to understand the internals. If you want those, read the
*OP Anonymization — Technical Guide* instead.

---

## 1. What this tool does

It takes a **restored copy** of a KTP production database and removes the client data from the OP
schema, so the copy can be used for testing and support without exposing real information.

It does two things to 580 columns across 167 tables:

| | |
|---|---|
| **Replaces identifiers** | Every entity, portfolio, counterparty and bank account code is swapped for a generated one — `T_0000412` instead of the real counterparty code. The same original always becomes the same replacement, everywhere in the schema, so the data stays internally consistent and the application still works. |
| **Erases free text and PII** | Names, addresses, phone numbers, emails, IBAN and RIB fragments are emptied outright. |

A run takes **20–40 minutes** on a production-sized instance and finishes with a verification pass
and an HTML report you can open in a browser.

> ### Read this before anything else
>
> **This is irreversible and it changes millions of rows.** Run it against a restored copy only.
> Never against production. The tool will ask you to type `YES` before it starts, and that
> confirmation is the last point at which you can stop.

---

## 2. Before you begin

### Checklist

- [ ] A **restored copy** of the database — not production
- [ ] Oracle **19c** or later
- [ ] **SQL\*Plus** installed and on your `PATH`, with a working TNS entry for the database
- [ ] The **SYS** password
- [ ] The **OP** schema password
- [ ] The name of a **data tablespace** and an **index tablespace** for the tool's own metadata
      (it needs only a few MB, even on the largest instances)
- [ ] Roughly **an hour** of uninterrupted time
- [ ] You are running from a machine **on the same network as the database**

### That last point matters

Three test runs were lost to `ORA-03114: not connected to ORACLE` when driving the run from a remote
workstation across a VPN. The run holds a single session open for the better part of an hour, and a
brief network interruption kills it. The same run from a host on the database's own network
completed without incident.

If you can only reach the database remotely, run the tool from a jump box near the database rather
than from your laptop.

### Check SQL\*Plus is ready

```batch
sqlplus -V
tnsping YOUR_SID
```

Both should succeed before you go further.

---

## 3. What is in the package

```
Anonymization_v4\
├─ config\
│  ├─ anonymization.template.ini    copy this to make your own settings file
│  ├─ anonymization.ini             your settings (you create it; not in version control)
│  ├─ inventory_op.csv              the shipped list of what gets anonymized  (562 columns)
│  └─ inventory_op_custom.csv       your site's additions and corrections      (18 columns)
├─ op\
│  ├─ run_op_anonymization.bat      >>> the only thing you run <<<
│  ├─ sql\                          the engine
│  ├─ verify\                       the checker and the report generator
│  └─ logs\                         created on first run; holds logs and reports
├─ docs\                            this guide and the technical guide
├─ tests\manual\                    optional helper scripts (monitoring, row counts)
└─ tools\                           optional analysis scripts
```

You only ever launch `op\run_op_anonymization.bat`. Everything else is called for you.

---

## 4. Step 1 — Configure

Copy the template:

```batch
cd Anonymization_v4
copy config\anonymization.template.ini config\anonymization.ini
```

Open `config\anonymization.ini` and fill in the SID and the two tablespace names.

**Leave both passwords blank.** Anything left blank is asked for when you run, which keeps
credentials off disk. The file is fully commented; every setting explains itself.

The settings you are most likely to touch:

| Setting | Default | What it means |
|---|---|---|
| `ORACLE_SID` | — | The TNS name of the database |
| `TABLESPACE_DATA` / `TABLESPACE_INDEX` | — | Where the tool's small metadata schema lives |
| `ANONYMIZE_ENTITY` etc. | `y` | The four categories of identifier. Leave all four at `y` unless you have a specific reason not to |
| `PARALLEL_DEGREE` | `4` | Parallelism for the big history tables. Set to `1` to disable |
| `MIN_CODE_LENGTH` | `2` | Identifiers shorter than this are left alone, because a one-character value is almost always a checkbox state (`O`, `x`, `N`), not a client code |

> **You can skip this step entirely.** With no configuration file, the tool asks for every value
> interactively. The file just saves you the typing on later runs.

---

## 5. Step 2 — Rehearse with a dry run

**Always do this first.** A dry run is a full rehearsal on the same code path as the real thing. It
touches nothing and it tells you whether the real run will succeed.

```batch
cd Anonymization_v4\op
run_op_anonymization.bat /dryrun
```

### What it asks you

The tool walks you through five short sections. Press Enter to accept anything shown in brackets.

**1. Load the config file?**

```
Found: config\anonymization.ini
  ORACLE_SID ............ TANM7881
  SYS_PASSWORD .......... (not set - will ask)
  OP_PASSWORD ........... (not set - will ask)
  TABLESPACE_DATA ....... USERS
  ...

Load it? Anything missing is still asked for [Y/n]:
```

**2. Connection** — SID, the two passwords, the two tablespaces. Anything the config file already
supplied is marked `[config]` and not asked again.

**3. What to anonymize** — the four categories:

```
 Anonymize entity codes,       prefix E_  [y]:
 Anonymize portfolio codes,    prefix P_  [y]:
 Anonymize counterparty codes, prefix T_  [y]:
 Anonymize bank account codes, prefix CB_ [y]:
```

**4. Description labels and PII attributes** — before each of these prompts the tool prints **the
actual list of columns that prompt governs**, read live from the inventory files:

```
 Entity - columns affected:
       tiers.adresse1 - applies to every category
       tiers.adresse2 - applies to every category
       ...
       tiers.telephone [site]
       tiers.fax [site]
       tiers.email_adress [site]
       tiers.nom_pp [site]
       tiers.prenom_pp [site]
   Anonymize these? [y]:
```

`[site]` marks a column that came from `inventory_op_custom.csv` — your site added it, rather than
it being shipped with the tool.

**5. Run behaviour** — parallel degree, custom inventory filename, and two safety settings. Each
shows its default; press Enter four times.

Then a summary, and the dry run begins.

### What a good dry run looks like

```
Inventory file: C:\Users\...\AppData\Local\Temp\anon_inventory_13913.sql
loaded ............ 579 items
  shipped ......... 561
  site-specific ... 18

NULL_OUT       NONE              92
CODE           ANY              391
CODE           BANK_ACCOUNT      71
DESCRIPTION    ANY                2
DESCRIPTION    BANK_ACCOUNT       1
SELF_CODE      ANY                5
SELF_CODE      BANK_ACCOUNT       3
SELF_CODE      COUNTERPARTY       4
SELF_CODE      ENTITY             5
SELF_CODE      PORTFOLIO          5

--- Preflight -------------------------------------------------
CHECKBOX    ventiler_corresp_bqe.tiers_entite  (VARCHAR2(1)) - will be left alone
CHECKBOX    val_ssi_account.tiers_entite  (VARCHAR2(1)) - will be left alone
NOT NULL    histo_pricing_groupe.description  (cannot be emptied)
resolved .......... 427
missing tables .... 68
missing columns ... 79
checkbox columns .. 4   (left alone)
too narrow ........ 0
wrong type ........ 0
not nullable ...... 1
```

### How to read that

| Line | What it means | Act on it? |
|---|---|---|
| `loaded 579 items` | The inventory parsed correctly | No |
| `missing tables 68`, `missing columns 79` | Those objects do not exist on this instance | **No — this is normal.** The shipped inventory covers several KTP/CTI versions, and no single instance has every table. They are skipped, not failed. |
| `checkbox columns 4` | One-character columns the tool will deliberately leave alone, because a single character is a checkbox state rather than a client code | No |
| `too narrow 0`, `wrong type 0` | Every target column can physically hold a generated identifier | Only if non-zero — then the run would stop, and the message names the columns |
| `not nullable 1` | A free-text column is mandatory, so it cannot be emptied. It is overwritten with the word `ANONYMIZED` instead | No |

**The dry run exits non-zero if anything would fail.** A clean dry run means the real run will get
through the preflight.

Run a dry run again any time you edit an inventory CSV. It is the cheap way to find a typo in a
column name before a 40-minute run finds it for you.

---

## 6. Step 3 — Run it

```batch
run_op_anonymization.bat
```

Same prompts. Then:

```
This will irreversibly modify schema OP on TANM7881.
Type YES to proceed:
```

Type `YES` in capitals. Anything else cancels and changes nothing.

### What you will see

Abridged. The figures below are from a real run against a 44-million-row test instance;
yours will differ.

```
triggers disabled: 45

--- Identifier mapping ----------------------------------------
ENTITY                        GENERATED   76 mappings
PORTFOLIO                     GENERATED   32 mappings
COUNTERPARTY                  GENERATED   761 mappings
BANK_ACCOUNT                  GENERATED   2,016 mappings
total                                     2,885 mappings

--- Free text and PII -----------------------------------------
tiers.nom                                 OK        869 rows
tiers.adresse                             OK        869 rows
...

--- Identifiers -----------------------------------------------
histo_flux.tiers                          OK        8,441,203 rows
histo_position.entite                     OK        6,220,118 rows
tp_users.entity                           SKIPPED
tp_wv_mailing_rule.entity                 NOOP      no rows matched
...

--- Labels and entity attributes ------------------------------
structure.[description]                   OK        1,863 rows
tiers.[description]                       OK        869 rows
tiers.[adresse1,adresse2,...,adresse5]    OK        569 rows
triggers enabled: 45

==============================================================
Run summary (EXECUTE)
==============================================================
applied ........... 156
no rows matched ... 236
skipped ........... 152   (not present on this instance)
disabled .......... 0     (excluded by configuration)
errors ............ 0
rows affected ..... 44,460,155
step time ......... 1,757s
==============================================================
```

Then verification and the report run automatically:

```
Verifying coverage...
 RESULT: PASS

Building report...
Report written to logs/report_20260901_142233.html

====================================================================
 COMPLETE - verified clean

 Report:  logs\report_<timestamp>.html      (open in a browser)
 Full output: logs\
====================================================================
```

### The four per-item statuses

| Status | Meaning | Worry? |
|---|---|---|
| `OK` | Applied, *n* rows changed | No |
| `NOOP` | Applied, **zero** rows changed | **Sometimes.** Normal for a column that was already clean. On a column you expected to change, it means the column name is wrong or that category is disabled. |
| `SKIPPED` | The table or column does not exist here | No, unless you expected it to exist |
| `DISABLED` | Turned off by your configuration | No |
| `ERROR` | Anything else | **Yes — the run failed** |

To list what matched nothing:

```sql
SELECT object_name, phase FROM anon_meta.anon_step_log
 WHERE run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)
   AND status = 'NOOP';
```

---

## 7. Watching a long run

SQL\*Plus only prints its output when a whole block finishes, so the window goes quiet for long
stretches. That is normal — the run is working. Progress is written to the database as it happens,
so you can watch it from a second window:

```batch
sqlplus op/<password>@<TNS> @tests\manual\monitor_op_progress.sql
```

Re-run it whenever you want a fresh picture. It takes no locks and cannot interfere.

---

## 8. Step 4 — The report

The run writes `op\logs\report_<timestamp>.html`. Open it in any browser — it is a single
self-contained file with no dependencies, so you can email it or attach it to a ticket.

### What is in it

**A verdict banner** — `PASS` or `FAIL`, with the headline numbers.

**Six summary tiles** — columns in scope, verified clean, rows exposed, columns not present on this
instance, identifiers mapped, rows changed.

**Coverage by treatment** — a row for each of the four rules (`CODE`, `NULL_OUT`, `DESCRIPTION`,
`SELF_CODE`) showing how many columns each covers and how they fared.

**Shipped inventory** — every column from `inventory_op.csv`, grouped by table, with rows, clean,
exposed and a status.

**Custom-added inventory** — the same for `inventory_op_custom.csv`.

**Not checked on this instance** — the tables that do not exist here, grouped, with the reason.

**Mapping integrity** — that the generated identifiers are unique and the lookup is complete.

### The one number that matters

**Exposed** — rows still holding an original client value. On a clean run this is **0** everywhere.
Anything else is shaded red and sorted to the top of its table so you cannot miss it.

### Why "Clean / Exposed" and not "anonymized / not anonymized"

Because an identifier column legitimately holds values that were never client data — currency codes,
product codes, system references. Those correctly have no generated prefix. Counting them as "not
anonymized" would show alarming figures on a perfectly clean database. **Exposed** means something
precise: the value is still one of the originals recorded in the mapping.

### Regenerating the report

It reads stored results and re-checks nothing, so you can regenerate it at any time:

```batch
sqlplus op/<password>@<TNS> @verify\generate_report.sql
```

It always reflects the most recent verification run. If you want fresh numbers, run
`verify\verify_op_coverage.sql` first.

---

## 9. If something goes wrong

### The single most important thing to know

**It is safe to re-run.** Fix the cause and run it again — no restore, no special flag, no
`--resume`.

Every operation is written so that doing it twice is the same as doing it once, and the identifier
mapping is **kept** between runs rather than regenerated. A run that failed at 5% and one that
failed at 95% both converge on the same correct result when re-run.

The cost is time: a re-run re-scans every table, so expect it to take about as long as the original
even though it changes almost nothing.

### The one case where you must NOT re-run

**After restoring the database.** The mapping in `anon_meta` refers to values the restore has just
put back, so the two are out of step. Clear it first:

```sql
DROP USER anon_meta CASCADE;
DROP USER atrace CASCADE;
```

Then start over from the dry run.

### Common problems

| What you see | What it means | What to do |
|---|---|---|
| `ORA-03114: not connected` | The network dropped the session mid-run | Re-run from a host on the database's network. Nothing is corrupted; the mapping survived. |
| `ORA-20010 No category is enabled` | All four `ANONYMIZE_*` flags are `n` | Set at least one to `y` |
| `ORA-20011 column(s) cannot hold a generated identifier` | A target column is too narrow or not text | Nothing was changed. `SELECT object_name, message FROM anon_meta.anon_step_log WHERE status='ERROR'` names them |
| `ORA-20013 core entity tables are not shaped as expected` | No `structure` / `tiers` / `compte_banque` in the expected form | You are probably connected to the wrong database |
| `ORA-20020 The inventory is empty` | `inventory_op.csv` was not found, or every line is a comment | Check the file is where the config says |
| `ORA-20023 anon_inventory is held by another session` | A previous run left a session open | The message names the holding session; end it, then re-run |
| `ORA-20030 code_map is empty` (during verify) | The anonymization has not run, or `anon_meta` was dropped | Run the anonymization first |
| `ORA-20070 verify_result is empty` (during report) | You asked for a report before verifying | Run `verify\verify_op_coverage.sql` first |
| Lots of `SKIPPED` | Normal — the inventory spans several KTP versions | Confirm with `tests\manual\check_tables_exist.sql` if you want to be sure |
| A `NOOP` you did not expect | Wrong column name in the inventory, or that category is off | Check the spelling against the data dictionary |
| Much slower than 40 minutes | Usually stale statistics on a `histo_*` table, or `PARALLEL_DEGREE=1` | Query the slowest steps (below) |

```sql
-- the ten slowest steps of the last run
SELECT object_name, rows_affected, ROUND(elapsed_ms/1000) AS secs
  FROM anon_meta.anon_step_log
 WHERE run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)
 ORDER BY elapsed_ms DESC FETCH FIRST 10 ROWS ONLY;

-- everything that errored
SELECT phase, object_name, message
  FROM anon_meta.anon_step_log
 WHERE run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)
   AND status = 'ERROR';
```

### If the run fails before it starts

The generated inventory file is **kept** rather than deleted, and its path is printed. Open it — a
malformed line in it points straight at the CSV row that caused the problem. (This is how a batch
quoting bug was found that had corrupted roughly 500 of 579 `INSERT` statements.)

---

## 10. Adding a column of your own

You do not need to edit any SQL. Add a line to `config\inventory_op_custom.csv`:

```csv
my_new_table,entity_code,CODE,ANY,CUSTOM,Added for the 2026 module
my_new_table,contact_email,NULL_OUT,NONE,CUSTOM,
```

The fields are `table_name,column_name,rule,category,source,notes`.

| Rule | What happens to the column |
|---|---|
| `CODE` | The identifier is replaced from the mapping. Use `ANY` as the category, or `BANK_ACCOUNT` if the column references `compte_banque.code` |
| `NULL_OUT` | Emptied. Use category `NONE`. For free text and PII |
| `SELF_CODE` | Overwritten with the anonymized code of its own row. Use when the column must stay populated (`NOT NULL`, or a format check) |

Then dry-run to confirm it resolves, and run for real. The engine, the verifier and the report all
pick it up automatically — there is no second list to keep in step.

A row here also **overrides** the shipped inventory for the same table and column, which is how a
wrong classification gets corrected without editing the shipped file.

---

## 11. After the copy is handed over

`anon_meta.code_map` maps every anonymized identifier back to the real one. It is kept so a failed
run can resume and so verification can be re-run — **not** as a key to hold on to.

Once the copy is verified and handed over, remove it:

```sql
DROP USER anon_meta CASCADE;
DROP USER atrace CASCADE;   -- only once EPF has also run, if it is going to
```

---

## 12. Quick reference

```batch
cd Anonymization_v4\op

run_op_anonymization.bat /dryrun      rehearse, change nothing
run_op_anonymization.bat              run for real (asks for YES)
run_op_anonymization.bat /auto        no prompts, use anonymization.ini as-is
run_op_anonymization.bat /auto /force no prompts at all, including the YES
```

| | |
|---|---|
| Run log | `op\logs\op_anon_<timestamp>.log` |
| Report | `op\logs\report_<timestamp>.html` |
| Re-verify | `sqlplus op/<pwd>@<TNS> @verify\verify_op_coverage.sql` |
| Rebuild the report | `sqlplus op/<pwd>@<TNS> @verify\generate_report.sql` |
| Watch a running job | `sqlplus op/<pwd>@<TNS> @tests\manual\monitor_op_progress.sql` |
| Exit code | `0` = success and verified clean; anything else = failure |

### A note on credentials

Passwords are passed to SQL\*Plus as command-line arguments, so they are briefly visible in the
process list to anyone who can see it on the same host. That is normal for an internal DBA tool, but
worth knowing before running on a shared jump box. Leaving passwords out of `anonymization.ini`
keeps them off disk at least.
