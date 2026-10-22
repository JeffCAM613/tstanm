# OP Anonymization - User Guide

**KTP Payment Factory - OP schema - version 0.5.0**

This guide is for the person who runs the tool: what to prepare, what to type, what you will see,
and how to know it worked. You do not need the internals for any of it; they are in the
*OP Anonymization - Technical Guide*.

---

## 1. What this tool does

It takes a **restored copy** of a KTP Payment Factory database and removes the client data from the
OP schema, so that the copy can be used for testing and support without exposing real information.

| | |
|---|---|
| **Replaces identifiers** | Every party and bank-account code is classified once, from the data, and gets one generated replacement: `E_` for an entity, `P_` a portfolio, `T_` a counterparty, `X_` a party the data cannot classify, `CB_` a bank account. The replacement is written everywhere the code is used, so the data stays consistent and the application still works. |
| **Masks labels and attributes** | The description of a party or an account, its address lines and its contact details are overwritten with its replacement, so screens stay readable: a counterparty shows as `T_0000412`. An empty field stays empty. |
| **Empties free text** | Comments, names typed as text, labels of operations: emptied outright. |
| **Proves the result** | After a run, a verification checks every column it covers and says PASS, FAIL, REVIEW REQUIRED or INCOMPLETE. |

What is covered is listed in `config\inventory_op.csv` and `config\inventory_op_custom.csv`; what is
switched on, in `config\anonymization.ini`.

> ### Read this before anything else
>
> **This is irreversible and it changes millions of rows.** Run it against a restored copy only,
> never against production. A run asks you to type `YES` after its checks, and that is the last
> point at which you can stop with nothing changed.

---

## 2. Before you begin

- [ ] A **restored copy** of the database - not production
- [ ] Oracle **19c** or later
- [ ] The **Oracle client with SQL\*Plus** on the machine you run from, `sqlplus.exe` in `PATH` (or
      in `ORACLE_HOME\bin`), and the database reachable by an alias in `tnsnames.ora` or as
      `host:port/service`
- [ ] **Windows PowerShell 5.1** - part of every supported Windows version
- [ ] The **SYS** password and the **OP** schema password
- [ ] A **tablespace** for the tool's own metadata schema, `ANON_META` (a few MB)
- [ ] About **an hour** of uninterrupted time for a run on a production-sized copy
- [ ] A machine **on the same network as the database**

A run keeps one database session open for its whole length. A network interruption on a VPN can end
it; run from a host near the database rather than from a remote laptop.

Check that SQL\*Plus reaches the database:

```batch
sqlplus -V
tnsping YOUR_DATABASE
```

---

## 3. What is in the package

```
Anonymization_v4\
|- config\
|  |- anonymization.template.ini    copy it to anonymization.ini
|  |- inventory_op.csv              what is anonymized, shipped
|  |- inventory_op_custom.csv       this site's additions and corrections
|- op\
|  |- run_op_anonymization.bat      >>> the only thing you run <<<
|  |- lib\                          the run's screen and report (PowerShell)
|  |- sql\                          the engine and the scripts the run sends
|  |- verify\                       the verification
|  |- logs\                         one folder per run
|- docs\                            this guide and the technical guide
|- tests\manual\                    optional helper scripts
|- tools\                           optional analysis scripts
```

You only ever launch `op\run_op_anonymization.bat`. Everything else is called for you.

---

## 4. Step 1 - Configure

```batch
cd Anonymization_v4
copy config\anonymization.template.ini config\anonymization.ini
```

Open `config\anonymization.ini` and fill in the database and the tablespace. **Leave the passwords
blank**: they are then asked for when the run starts, masked, and passed to SQL\*Plus on its input
only - never on a command line, never written down. The file is fully commented.

| Setting | Default | What it means |
|---|---|---|
| `ORACLE_SID` | - | The database: its alias in `tnsnames.ora`, or `host:port/service` |
| `TABLESPACE_DATA` / `TABLESPACE_INDEX` | - | Where `ANON_META` lives; the index tablespace defaults to the data one |
| `ANONYMIZE_<CATEGORY>` | `y` | Rename the codes of that category (`ENTITY`, `PORTFOLIO`, `COUNTERPARTY`, `UNCLASSIFIED_PARTY`, `BANK_ACCOUNT`) |
| `ANONYMIZE_<CATEGORY>_DESCRIPTION` | `y` | Mask the labels of that category |
| `ANONYMIZE_<CATEGORY>_ATTRIBUTES` | `y` | Mask its addresses and contact details |
| `APPROVE_STRUCTURE_ONLY_ACCOUNTS` | `y` | A `w_compte_banque` structure node with no `compte_banque` row is a bank account. Set `n` only for a client where it is not |
| `PARALLEL_DEGREE` | `4` | Parallelism for the large history tables; `1` disables it |
| `CUSTOM_INVENTORY` | `inventory_op_custom.csv` | The site inventory file, in `config\` |
| `FAIL_ON_MISSING_OBJECT` | `n` | `y` refuses to run while an inventory table or column is missing |

Leave every switch at `y` for a full anonymization. A switch at `n` leaves that client data in place,
and the verification can then be no better than INCOMPLETE.

**Without questions.** `/auto` asks nothing. Everything then comes from the file, and the
passwords from the environment:

```batch
set ANON_SYS_PASSWORD=...
set ANON_OP_PASSWORD=...
op\run_op_anonymization.bat /auto /dryrun
```

---

## 5. Step 2 - The dry run

**Always do this first.** A dry run makes every check a run makes, plans every translation, and
counts what a run would change - table by table, column by column - on the same code path. It
changes nothing.

```batch
op\run_op_anonymization.bat /dryrun
```

### Getting ready

The run finds SQL\*Plus, reads the configuration, asks what it leaves blank, connects as SYS and as
OP, creates or updates `ANON_META`, installs the engine and loads the inventory. Each is one line:

```
 OP Anonymization 0.5.0                                                  dry run
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Configuration      config\anonymization.ini

 -- Passwords ------------------------------------------------------------------
   Sent to sqlplus on its input: never on a command line, never written down.
 > SYS password: ********
 > OP password: ********
   Database           OPDB: connected as SYS and as OP (Oracle 19.21)
   Metadata           ANON_META on tablespace DATA: up to date (0:01)
   Engine             version 0.5.0 (installed, 0:03)
   Inventory          576 items (560 shipped, 16 of this site): 429 in this database,
                      147 not here (they are skipped)

   What is anonymized (config\anonymization.ini)
   Category                  Rename codes   Labels   Attributes
   Entity (E_)               yes            yes      yes
   Portfolio (P_)            yes            yes      yes
   Counterparty (T_)         yes            yes      yes
   Unclassified party (X_)   yes            yes      yes
   Bank account (CB_)        yes            yes      yes
   Free text                 always emptied
   Every switch is on: a full anonymization.
```

A missing SQL\*Plus, a wrong alias or a wrong password is a line here, before anything else happens.
Items "not here" are normal: the inventory covers several KTP/CTI versions, and no database has
every table.

### The checks

The first step plans the run and makes its checks, then shows them as a table:

```
 1 of 2  Checking and planning (read-only)                         done    0:41
         2,941 identities: 920 parties, 2,021 bank accounts

   Check                                 Needed     Now
   Identity tables                       required   ok
       tiers 1,094 rows, structure 4,230 rows, compte_banque 2,007 rows
   Data not anonymized before            required   ok
       no code in tiers, compte_banque or structure has the form of a replacement
   Earlier translations                  required   ok
       none on this database: every translation is new
   Replacements unique                   required   ok
       2,941 replacements, each used once, none equal to an original code
   Replacements fit their columns        required   ok
       429 columns checked; the widest replacement has 10 characters
   Bank accounts only on the structure   info       14 nodes
   Free text that cannot be emptied      info       1 column
   Inventory objects in this database   optional   147 not here

   Every required check is met: a run can go ahead as things are.
```

A **required** check that is not met stops the run there, with what happens and what to do. An
**info** check says what the run will do with what it found.

### Counting what a run would change

One line for each kind of work, rewritten in place while it counts:

```
 2 of 2  Counting what a run would change
         Free text              [####################] 100%   39 tables       31,204,331 rows   2:58
         Identifiers            [###########.........]  58%   148 of 252 columns . histo_operation.entite 45% . 4,120,388 rows . 2:41 left
```

`Ctrl+C` stops it after the table or column it works on.

### The end of a dry run

```
 ===============================================================================
  A run would change 41,862,770 rows in 158 tables.
  It would end REVIEW REQUIRED: 1,204 values in 3 columns would be left for review.
  About 31 minutes, a rough estimate. Nothing was changed.
 ===============================================================================
   What                          Columns   Rows to change   Of them X_
   Free text emptied                  61       31,204,331            -
   Identifiers renamed               252        9,412,118       41,203
   Labels masked                       3            5,077            -
   Attributes masked                  21           18,940            -
   Left as they are, for review        3            1,204            -
```

Then the identities by category, the **unclassified parties (X_)** by reason, what would be **left for
review**, and **Good to know**. The run folder and its `report.html` follow (section 7).

**What to act on before the real run:**

- **Left for review** - values whose role the data does not settle (a value that is a party AND a
  bank account in a column that can hold both). A run leaves them as they are, and its verification
  says REVIEW REQUIRED while they remain.
- **Unclassified parties (X_)** - section 9.
- A required check not met - the dry run says what to do.

Run a dry run again after any change to an inventory CSV: it is the cheap way to find a typo in a
column name.

---

## 6. Step 3 - The run

```batch
op\run_op_anonymization.bat
```

The same getting ready and the same checks, on the database as it is now. If they pass, the run
says what it will change and asks:

```
 ===============================================================================
  Ready. This replaces the client data of OP on OPDB:
  - 2,941 identities get their E_, P_, T_, X_ or CB_ value, in 252 identifier columns; their labels
    and attributes are masked with it
  - 61 free-text columns emptied, 24 label and attribute columns masked
  About 31 minutes, from the dry run R-000001. It cannot be undone: run it on a restored copy
  only.
 ===============================================================================
 > Type YES to start: YES
```

Anything but `YES` ends the run with nothing changed. A run its checks refuse never asks.

Then:

```
 2 of 4  Recording the translations                                done    0:03
         2,941 new translations recorded

 3 of 4  Anonymizing
         triggers of OP: 45 disabled until the end of the run
         Free text              [####################] 100%   39 tables       31,204,331 rows   9:48
         Identifiers            [####################] 100%   252 columns      9,412,118 rows  16:31
         Labels and attributes  [####################] 100%   24 columns          24,017 rows   0:52
         triggers of OP: 45 enabled again
 4 of 4  Verifying (read-only)                                     done    1:54

 ===============================================================================
  DONE   41,861,566 rows changed in 29:47. Verification: PASS.
         Every protection was on, no original value was found where the inventory covers, and
         nothing was left for review.
 ===============================================================================
```

The translations are recorded **before** anything in OP changes. Each table or column is then
changed in its own transaction, and the triggers of OP are disabled for the work and enabled again
at its end - also when it fails or is stopped.

### The verdict

| Verdict | Exit code | Means |
|---|---|---|
| **PASS** | 0 | Every protection on, no original value found, nothing left for review |
| **FAIL** | 2 | An original value is still where it should have been replaced. Do not hand over the copy |
| **REVIEW REQUIRED** | 3 | Values were left as they are on purpose, because their role is not settled. Decide on them (`report.html`, "Left for review") |
| **INCOMPLETE** | 4 | Nothing exposed where protection was on, but a switch was off |

Every run ends with its exit code in words, for example `Exit code 0: done, verified: PASS.`

---

## 7. The run folder and report.html

Every run - dry runs, refused and failed runs included - leaves a folder
`op\logs\<date>_<time>_R-<run>\`:

| File | |
|---|---|
| `report.html` | The result: opened in your browser at the end (`/no-open` leaves it closed) |
| `report.txt` | What the engine printed, line by line |
| `verify.txt` | What the verification printed (a run) |
| `console.log` | Every line of the screen, and the engine's |
| `results.txt` | The figures `report.html` is built from - counts only |
| `manifest.txt` | The run in `key=value` lines: settings, steps and their times, checks, verdict, exit code |
| `inventory.sql` | The inventory as it was loaded |

`report.html` is one self-contained file: it can be printed, attached to a ticket or sent as it is. It
holds **counts and names of tables and columns only - never a client identifier**. It shows:

- the verdict in a word and the result in one sentence, with the main figures;
- what was done (or, for a dry run, what a run would change), by kind of work;
- the verification, part by part (a run);
- what was left for review, column by column;
- the unclassified parties (X_) by reason - for a dry run with what to do about each reason and one
  query per reason that lists them, with a Copy button;
- the identities by category, the checks, the switches used, the duration of each step;
- Good to know, and Next;
- folded: every column of the inventory with its figures and a filter, what is not in this
  database, and the full text output.

It reads what the run and the verification recorded; it re-checks nothing.

---

## 8. Stopping a run, and when something goes wrong

### Ctrl+C

`Ctrl+C` asks the run to stop **after the table or column it is working on**. The run completes that
one, enables the triggers of OP again, and ends **STOPPED** (exit code 5). Every table or column done
is complete; nothing is half done.

**Closing the window during a run is not safe:** the triggers of OP could stay disabled. If it
happens, run this from SQL\*Plus as OP:

```batch
sqlplus op/<password>@<database> @op\sql\run\recover.sql <run id>
```

While the run is still working in the database it changes nothing - the run then ends by itself and
enables the triggers again. Otherwise it records the run as failed and enables the triggers of OP
again. Then a new run resumes.

### A new run resumes

**It is safe to run again.** Fix the cause and run the same command: no restore, no flag. The
translations recorded so far are kept, so every identity gets the same replacement as before, and
what is already done is found done. A run after a stop or a failure therefore converges on the same
result as one that never stopped. It takes about as long as the first, because every table is read
again.

### When you must NOT simply run again

**After restoring the database again.** `ANON_META` then holds translations of values the restore
has put back. A run uses them - the same originals get the same replacements - which is what you
want on a new import of the same client. To start from nothing instead:

```sql
DROP USER anon_meta CASCADE;
DROP USER atrace CASCADE;
```

### How a run ends when it does not complete

| Screen | Exit | Means | What to do |
|---|---|---|---|
| `NOT STARTED   ...: not met.` | 1 | A required check refused the run. Nothing was changed | What the check says - for example, import the raw data again when the copy was anonymized before. Then a dry run |
| `NOT STARTED   You did not type YES.` | 1 | Not confirmed. Nothing was changed | Run again when ready |
| `FAILED   ...` | 1 | An error, named on the screen and in `report.txt` | Remove the cause and run again: it resumes |
| `STOPPED   On request ...` | 5 | Ctrl+C | Run again: it resumes |

### Common problems

| What you see | What it means | What to do |
|---|---|---|
| `sqlplus not found` | No Oracle client in `PATH` or `ORACLE_HOME\bin` | Install the client, or add its `bin` folder to `PATH` |
| `the connection as SYS ... failed: ORA-12154` | The database alias is unknown | Check `ORACLE_SID` and `tnsnames.ora`, or use `host:port/service` |
| `... failed: ORA-01017` | Wrong password | It is asked again, three times at most |
| `Inventory  it cannot be used as written` | A CSV row pairs a rule with a category that cannot apply, or a column option is misspelt | The lines are named; correct them (in `inventory_op_custom.csv` for a site row) |
| `Data not anonymized before - NOT MET` | This copy was anonymized before | Import the raw data again |
| `Replacements fit their columns - NOT MET` | A column cannot hold a generated value: too narrow, or not text | Correct the rule of the column named, or leave it out of the inventory |
| `ORA-20023 anon_inventory is held by another session` | A previous session still holds it | `tests\manual\check_locks.sql` as SYS names the holder |
| Much slower than expected | Usually stale statistics on a `histo_*` table, or `PARALLEL_DEGREE=1` | The duration of each step is in `report.html` |

---

## 9. Unclassified parties (X_)

A party is unclassified when the data does not say which kind of party it is. It still gets its own
replacement, `X_0000001`, written everywhere its code is used - nothing is left in clear - but the
reason is worth knowing before the real run:

| Reason | Means | What would classify it |
|---|---|---|
| missing master | The code is a party - a `w_tiers` node, or a value in a party column - but `tiers` has no row for it | Add the `tiers` row; a code left over from a deleted party can stay X_ |
| no structure | The `tiers` row has no structure node, and its flag is not N | Add its `w_tiers` node, or set the flag to N for an archived counterparty |
| no party screen | Its nodes are on other screens only | Add a `w_tiers` node if it belongs in the party tree |
| unknown flag | `flag_portefeuille` is neither O nor N | Set it to O or N |
| unknown classification | Flag N, but its `w_tiers` nodes have no classification | Set the classification on its node |

The dry run's `report.html` lists, for each reason, a query that lists those parties, ready to copy.
The queries read that dry run's plan: run them before the next run starts. **What they return is
client codes: keep it on the database's machine.**

---

## 10. Adding a column of your own

You do not edit any SQL. Add a line to `config\inventory_op_custom.csv`:

```csv
my_new_table,entity_code,CODE,PARTY,CUSTOM,entity of the new module
my_new_table,account_code,CODE,BANK_ACCOUNT,CUSTOM,
my_new_table,contact_email,NULL_OUT,NONE,CUSTOM,
```

The fields are `table_name,column_name,rule,category,source,notes`. No commas in the notes.

| Rule | Category | What happens |
|---|---|---|
| `CODE` | `PARTY` | Party codes are replaced with their party's translation |
| `CODE` | `BANK_ACCOUNT` | Bank-account codes are replaced with their account's translation |
| `CODE` | `MIXED` | Both, once reviewed; a value that is a party AND an account is left for review |
| `NULL_OUT` | `NONE` | Emptied - the marker `ANONYMIZED` where the column cannot be empty |
| `SELF_CODE` | `PARTY`, `BANK_ACCOUNT` or one party category | Overwritten with the owner's replacement; an empty field stays empty |

A row here also **replaces** the shipped row for the same table and column. Then a dry run: it
checks the line and counts what it would change. The engine, the verification and the report all
pick it up - there is no second list to keep in step.

---

## 11. After the copy is handed over

`anon_meta.code_map` maps every replacement back to the real code. It is kept so that a run can
resume and the verification can be repeated - **not** as a key to hold on to. Once the copy is
verified and handed over - and the EPF anonymization, which reads it, has run - remove it:

```sql
DROP USER anon_meta CASCADE;
DROP USER atrace CASCADE;
```

Keep the run folders: they hold counts only, and say what was done to the copy.

---

## 12. Quick reference

```batch
op\run_op_anonymization.bat /dryrun           what a run would change; changes nothing
op\run_op_anonymization.bat                   the run: checks, then asks for YES
op\run_op_anonymization.bat /auto             asks nothing (still asks for YES)
op\run_op_anonymization.bat /auto /force      asks nothing at all
op\run_op_anonymization.bat /verbose          every line of the engine on the screen
op\run_op_anonymization.bat /no-open          report.html not opened at the end
op\run_op_anonymization.bat /help             every option
```

| | |
|---|---|
| Run folder | `op\logs\<date>_<time>_R-<run>\` |
| Passwords without questions | `ANON_SYS_PASSWORD`, `ANON_OP_PASSWORD` |
| Verify again | `sqlplus op/<pwd>@<database> @op\verify\verify_op_coverage.sql` |
| Stop a run from another session | `sqlplus op/<pwd>@<database> @op\sql\run\stop.sql <run id>` |
| After a closed window | `sqlplus op/<pwd>@<database> @op\sql\run\recover.sql <run id>` |
| Exit codes | `0` PASS (a dry run: completed) - `1` failed or not started - `2` FAIL - `3` REVIEW REQUIRED - `4` INCOMPLETE - `5` stopped |
