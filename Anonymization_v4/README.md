# OP Anonymization 0.5.0

Anonymizes client-identifying data in the OP schema of a KTP Payment Factory Oracle database, so
that a copy of a production instance can be used for development, testing and support without
exposing real client information.

---

## What it does

- **Identifiers.** Every party and bank-account code is classified once, from the data, and gets one
  generated replacement - `E_` entity, `P_` portfolio, `T_` counterparty, `X_` a party the data
  cannot classify, `CB_` bank account - written everywhere that code is used.
- **Labels and attributes** of a party or an account are masked with its replacement, so screens
  stay readable.
- **Free text** - names, comments, addresses typed as text - is emptied.
- **It proves the result.** A verification checks every column afterwards and ends PASS, FAIL,
  REVIEW REQUIRED or INCOMPLETE.

---

## The one idea worth knowing

Every column this tool anonymizes is declared **once**, in `config/inventory_op.csv`. That single
file drives four things:

```
                      config/inventory_op.csv
                      config/inventory_op_custom.csv
                                  |
                    loaded into anon_meta.anon_inventory
                                  |
        +-------------+-----------+-----------+------------------+
        v             v                       v                  v
   the engine     the dry run           the verifier       the coverage doc
  (what changes) (what would change)  (what must be gone)   (generated)
```

Because all four read the same rows, **the script, the check and the documentation cannot disagree
about what is anonymized**. Adding a table means adding a line to a CSV - not editing SQL, not
updating a doc, not extending the verifier.

---

## Quick start

```batch
REM 1. A dry run: what a run would change. Changes nothing.
op\run_op_anonymization.bat /dryrun

REM 2. The run: it checks again, shows what it will change, asks for YES,
REM    anonymizes, then verifies the result.
op\run_op_anonymization.bat
```

On a Linux server, the same two steps with the shell launcher - the same engine, checks, screens
and report:

```bash
op/run_op_anonymization.sh --dryrun
op/run_op_anonymization.sh
```

Settings live in `config/anonymization.ini` (copy it from `anonymization.template.ini`). What it
leaves blank is asked for when the run starts; passwords are best left blank - they are then asked
for, masked, and passed to sqlplus on its input only.

Every run - dry runs included - leaves a folder in `op\logs\` with **`report.html`** (the result,
the figures, the checks; opened at the end), `report.txt`, `verify.txt` (a run), `console.log`,
`results.txt`, `manifest.txt` and `inventory.sql`.

While the work runs, the screen shows one live line for each kind of work - free text, identifiers,
labels and attributes - with its progress, the rows so far and the time left. **Ctrl+C** asks the
run to stop after the table or column it is working on; it enables the triggers of OP again, and a
new run resumes from there.

| Exit code | |
|---|---|
| 0 | PASS: verified complete (a dry run: completed) |
| 1 | failed, or not started (refused by its checks, or not confirmed) |
| 2 | FAIL: client data is still present |
| 3 | REVIEW REQUIRED: values were left as they are, their role ambiguous |
| 4 | INCOMPLETE: a protection was switched off |
| 5 | stopped with Ctrl+C |

`op\run_op_anonymization.bat /help` (`op/run_op_anonymization.sh --help`) lists every option.

---

## Documentation

| Read this | For |
|---|---|
| **[docs/OP_User_Guide.md](docs/OP_User_Guide.md)** | **Start here if you are running it.** Prerequisites, configuration, dry run, execution, reading the report, troubleshooting. Also as `.html` and `.docx` in the same folder. |
| **[docs/OP_Technical_Guide.md](docs/OP_Technical_Guide.md)** | **Start here if you are maintaining it.** Architecture, the inventory model, switches, identifier generation, run lifecycle, verification design, metadata schema, error codes. Also as `.html` and `.docx`. |

---

## Safety notes

- **Never run against production.** This tool performs mass irreversible `UPDATE`s. It is intended
  for a restored copy.
- **OP comes before EPF.** The EPF anonymization reads the translations this one records.
- **The mapping is the only link back to the original values.** `anon_meta.code_map` maps old code
  to new code, per category; `anon_meta.identity_inventory` records what each original was - party
  or bank account, its category, and why an unclassified (X_) party is one. A run never drops
  either. If you drop them, a partially anonymized database cannot be reconciled, and a later run
  refuses to start on it rather than translate a translation.
- **Look at the unclassified (X_) parties before the real run.** A dry run counts them by reason and
  by where they were found; its report says what would let the data classify each kind and gives
  one query per reason that lists them: fix the data first, or knowingly leave them X_.
- **A result is PASS only when nothing is left.** Values whose role cannot be established are left
  unchanged and reported as REVIEW REQUIRED; a switched-off protection gives INCOMPLETE. Neither is
  presented as complete anonymization.
- All triggers on the OP schema are disabled for the duration of a run and enabled again at its
  end - also when it fails or is stopped with Ctrl+C. **Closing the window during a run is not
  safe** on Windows: if it happens, `op\sql\run\recover.sql` ends the run and enables the triggers
  again. On Linux a closed terminal does not stop the run: it goes on to its end.
