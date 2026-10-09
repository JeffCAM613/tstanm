# KTP Payment Factory — Data Anonymization (v4)

Anonymizes client-identifying data in the KTP Payment Factory Oracle databases so that a copy of a
production instance can be used for development, testing and support without exposing real client
information.

> **v4 is a rebuild.** `Anonymization_OP/` and `Anonymization_EPF/` are kept unchanged as backup and
> reference. Nothing in v4 reads from or writes to them. See
> [docs/OP_Technical_Guide.md](docs/OP_Technical_Guide.md) for what changed and why.

---

## Status

| Schema | State |
|---|---|
| **OP** | Complete. Run from `op/`, verified against a live instance |
| **EPF (OPPAYMENTS)** | Not yet ported — still runs from the previous-generation `Anonymization_EPF/` scripts |

---

## The one idea worth knowing

Every column this tool anonymizes is declared **once**, in `config/inventory_op.csv`. That single
file drives four things:

```
                      config/inventory_op.csv
                      config/inventory_op_custom.csv
                                  │
                    loaded into anon_meta.anon_inventory
                                  │
        ┌─────────────┬───────────┴───────────┬──────────────────┐
        ▼             ▼                       ▼                  ▼
   the engine     the dry run           the verifier       the coverage doc
  (what changes) (what would change)  (what must be gone)   (generated)
```

Because all four read the same rows, **the script, the check and the documentation cannot disagree
about what is anonymized**. Adding a table means adding a line to a CSV — not editing SQL, not
updating a doc, not extending the verifier.

---

## Quick start

```batch
cd Anonymization_v4\op

REM 1. Rehearse. Reads the inventory, checks every table/column exists on this
REM    instance, checks generated codes fit, reports rows that WOULD change.
REM    Makes no changes and returns non-zero if anything would fail.
run_op_anonymization.bat /dryrun

REM 2. Execute.
run_op_anonymization.bat

REM 3. Verify.
sqlplus op/<password>@<TNS> @verify\verify_op_coverage.sql
```

Settings live in `config/anonymization.ini`. Anything left blank is prompted for at runtime —
which is the recommended handling for passwords.

---

## Documentation

| Read this | For |
|---|---|
| **[docs/OP_User_Guide.md](docs/OP_User_Guide.md)** | **Start here if you are running it.** Prerequisites, configuration, dry run, execution, reading the report, troubleshooting. Also as `.html` and `.docx` in the same folder. |
| **[docs/OP_Technical_Guide.md](docs/OP_Technical_Guide.md)** | **Start here if you are maintaining it.** Architecture, the inventory model, flags, identifier generation, run lifecycle, verification design, metadata schema, compatibility, error codes. Also as `.html` and `.docx`. |

Both guides are written in Markdown; the `.html` and `.docx` beside them are generated from it
by `tools/build_docs.js` in the source repository. Edit only the `.md`.

### Working notes

The rebuild's notes — the test log, the defect record, open questions, the flag-impact analysis and
the session-2 test plan — live in `unofficial docs/` in the source repository. They are accurate,
but they are working documents and are not part of a release.

---

## Safety notes

- **Never run against production.** This tool performs mass irreversible `UPDATE`s. It is intended
  for a restored copy.
- **OP must complete before EPF.** EPF cascades read the code mapping OP produces.
- **The mapping is the only link back to the original values.** `anon_meta.code_map` maps old code →
  new code. v4 never drops it as part of a run. If you drop it, a partially anonymized database
  cannot be reconciled.
- All triggers on the target schema are disabled for the duration of a run and re-enabled at the
  end, including on failure.
