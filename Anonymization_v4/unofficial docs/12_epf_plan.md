# 12 — EPF anonymization: plan (draft)

Porting EPF (`OPPAYMENTS`) onto the v4 architecture, and widening coverage control across both
schemas while we are in there.

**Status: draft for review.** The method for building the EPF inventory is settled in [§9](#9-phase-5--how-the-epf-inventory-gets-built); two things still need confirming there.

---

## 1. Where EPF stands today

The existing package is `Anonymization_EPF/sql/`: an orchestrator with eight phases (A–H), two
"iteration" scripts, three phase scripts, and five BIC scripts. About 6,900 lines.

It is further along than v3 OP was in some ways — it has a real run log (`epf_anon_log` with a
`run_id`), per-step `SAVEPOINT`s, and a verifier whose residual-detection idea was good enough that
v4 OP adopted it. It is much further behind in others.

### What a careful read turned up

| | |
|---|---|
| **`anonymize_epf_itr2.sql` is truncated** | The orchestrator announces *"PHASE D: Independent Anonymization (ITR2 — 19 steps)"*. The file has three steps and ends after `admin_user`. Its own header lists Phases 1–6D and "all 15+ tables with user references cascaded" — none of which is in the file. **This is the single largest finding.** The missing work is not wrong, it is absent, which is harder to notice. |
| **`ORA_HASH(code, N)` is misused** | Phase 9 derives synthetic account numbers with `ORA_HASH(code, 1)`, `(code, 2)` … The second argument of `ORA_HASH` is `max_bucket`, not a seed. `ORA_HASH(code,1)` returns 0 or 1. So `numero_banque` takes **two** distinct values across the whole table and `numero_guichet` **three**. The values are format-valid and effectively constant. |
| **EPF writes to the OP schema** | Phase 9 updates `op.tiers` and `op.compte_banque` — eleven columns, ten of which the OP inventory does not cover. Columns OP owns get anonymized by EPF, and OP's verifier cannot see them. |
| **`compte_banque.code_bban` is covered on paper only** | Declared `CODE,BANK_ACCOUNT` in `inventory_op.csv`. A BBAN is a 23-character account string, never a `compte_banque.code`, so the lookup can never match. The TANM7881 run reported `NOOP — no rows matched`. It reads as covered, counts as covered, and does nothing. Recorded in `inventory_op_custom.csv` under *Discovered from EPF anonymization*. |
| **Phase-level error policy** | `WHENEVER SQLERROR CONTINUE` throughout, and the orchestrator always exits success. A failed phase is a line in a log nobody reads. |
| **No dry run at all** | There is no rehearsal mode. The first time you learn a column name is wrong is during the run. |
| **Coverage is undeclared** | Sixteen `oppayments` tables are touched, spread across nine files, discoverable only by reading them. There is no equivalent of `inventory_op.csv`. |

### What is worth keeping

- **The BIC component model.** Decomposing a BIC into bank / country / location / branch and mapping
  each part separately is the right answer, and `epf_anonymization_map` is the right shape for it.
- **`branch_code = 'XXX'` is preserved** — head office. Someone knew what they were doing.
- **Amount perturbation preserves workflow thresholds.** It reads `meta_condition` so that
  randomized amounts still fall on the same side of approval limits. That is careful work.
- **Password reset and hashcode recalculation.** Non-negotiable: without it nobody can log in to the
  application afterwards, which defeats the purpose of a testable copy.

---

## 2. Shape of the port

EPF becomes a second inventory against the same engine. Nothing about the architecture changes; the
inventory gains two fields and the engine gains three rules and a notion of declared procedures.

```
config/inventory_op.csv      ─┐
config/inventory_op_custom.csv│
config/inventory_epf.csv      ├─→  anon_meta.anon_inventory  ─→  anon_engine
config/inventory_epf_custom.csv ┘         (schema-qualified)         │
                                                                     ├─ engine
                                          anon_meta.code_map    ←────┤  dry run
                                          anon_meta.component_map    │  verifier
                                                                     └─ report
```

`code_map` is written by the OP run and **read** by the EPF run. That is the cascade, and it is the
same table rather than a copy — which removes `ref_tables_modif_epf` and the whole idea of a
separate EPF audit mapping.

### One engine or two

**Recommendation: one package, installed once in `anon_meta`, granted to both.** Today
`30_install_engine.sql` compiles `anon_engine` into the OP schema. Installing a second copy into
`OPPAYMENTS` would mean two bodies to keep in step, which is the drift problem again.

The cost is that `anon_meta` then needs `UPDATE` on both vendor schemas, and the package needs to be
definer's-rights so it can use those grants. That is a privilege decision to confirm with whoever
owns the database, and it is listed in [§9](#9-phase-5--how-the-epf-inventory-gets-built).

---

## 3. Inventory schema, version 2

Two new fields. Both apply to OP as well as EPF.

```csv
schema,table_name,column_name,rule,category,flag,filter,source,notes
```

| Field | New? | Purpose |
|---|---|---|
| `schema` | new | `OP` or `EPF`. Lets one loaded inventory drive both runs and keeps the report honest about which schema a column lives in. |
| `flag` | **new — your choice** | Names the config key that gates this row. Empty means always applied. |
| `filter` | new | A SQL predicate restricting which rows of the table the rule applies to. Empty means the whole table. |

Everything else keeps its current meaning.

### `flag` — coverage control becomes data

Today the mapping from category to config flag is **hardcoded in the engine**: a `SELF_CODE` row
with category `ENTITY` is gated by `ANONYMIZE_ENTITY_ATTRIBUTES` because the engine says so. Adding
a new switch means editing PL/SQL.

With a `flag` column the gate is declared per row:

```csv
EPF,payment,nominal_1,PERTURB,,ANONYMIZE_AMOUNTS,,BASE,off by default
EPF,audit_trail,ip_address,NULL_OUT,NONE,ANONYMIZE_AUDIT_TRAIL,,BASE,
OP,tiers,bank_code,COMPOSITE,BIC_BANK,ANONYMIZE_BIC,,CUSTOM,from EPF phase 9
```

Adding a switch becomes one CSV column plus one line in the `.ini`. The interactive wrapper already
reads the CSVs to list affected columns per prompt — with a `flag` column it can generate the
prompts themselves, so a new switch appears in the interview automatically and cannot drift from
what it governs.

**Migration for OP is mechanical**: fill `flag` from the existing category→flag rule, and the
current behaviour is reproduced exactly. `21_validate_inventory.sql` gains a check that every named
flag actually exists in the configuration, so a typo in the CSV fails before the run rather than
silently disabling a column.

### `filter` — because EPF has key-value tables

`bulk_payment_additional_info` is `(key, value)`. What must be anonymized is `value` **where the key
is a BIC-bearing SWIFT tag**. The unit of coverage is (table, column, predicate):

```csv
EPF,bulk_payment_additional_info,value,COMPOSITE,BIC,ANONYMIZE_BIC,"key IN ('87A','BIC','82A')",BASE,
EPF,confirmation_exchange_details,value,NULL_OUT,NONE,,"key = '83J'",BASE,ordering customer name
```

Without this, a flat row on `value` either misses rows or destroys unrelated ones. `filter` is
appended to the engine's `WHERE`, validated at preflight by running `SELECT COUNT(*) … WHERE
<filter> AND 1=0` so a syntax error is caught before any DML.

> `filter` is injected SQL from a CSV. It is a config file an administrator edits, not user input,
> and the engine already builds dynamic SQL from the same file — but preflight must parse-check it,
> and this should be stated plainly in the technical guide rather than left implicit.

---

## 4. New rules

Four rules today: `CODE`, `NULL_OUT`, `DESCRIPTION`, `SELF_CODE`. Three more.

### `COMPOSITE` — structured identifiers

For values built from fixed-width parts that must stay consistent everywhere they appear. BIC is the
case that forces it.

```
BIC   D E U T   D E   F F   X X X
      └ bank ┘  └cty┘ └loc┘ └brch┘
        4         2     2      3
```

Each component is mapped independently into `anon_meta.component_map` (the replacement for
`epf_anonymization_map`), so the same bank code becomes the same replacement in
`op.tiers.bank_code`, in `oppayments.ref_bank_branche`, and inside an 11-character BIC embedded in a
SWIFT tag value.

Component layouts are declared, not hardcoded — a `component_type` table giving offset, length and
character class. `category` on a `COMPOSITE` row names either a single component (`BIC_BANK`) or the
whole composite (`BIC`), depending on whether the column holds a part or the assembled value.

Generation is **set-based and deterministic**, as in OP: `ROW_NUMBER()` over the distinct source
values, encoded into the component's alphabet. Not `dbms_random` with a collision probe, which is
what the current BIC scripts do.

**Preserved by declaration**, not by an `IF` buried in an update: `branch_code = 'XXX'` (head
office), and — a question for review — whether `iso_country_code` should be anonymized at all. A
country code is barely identifying on its own and rewriting it makes every BIC structurally invalid.
Proposal: **leave country codes alone by default**, gated behind `ANONYMIZE_BIC_COUNTRY=n`.

### `DERIVE` — format-valid synthetics

For a column that cannot be emptied and cannot hold a code, because something validates its shape:
bank account numbers, IBAN check digits, SIRET.

The value is derived deterministically from the row's already-anonymized key, so it is reproducible
and stable across re-runs — the property that makes the whole thing restartable.

```sql
-- correct: ORA_HASH(expr, max_bucket, seed)
LPAD(MOD(ORA_HASH(code, 4294967295, 1), 90000) + 10000, 5, '0')
```

Replaces Phase 9's broken expression. Formats are declared per `category` (`ACCOUNT`, `IBAN_KEY`,
`SIRET`), not inlined.

### `PERTURB` — numeric randomization

**Off by default**, per your answer. `nominal_1` randomized 0.5×–1.5×, `nominal_2` kept in sync, bulk
totals recalculated so a parent still equals the sum of its children, and workflow thresholds read
from `meta_condition` so amounts stay on the same side of approval limits.

That last part is the reason this is a declared **procedure** rather than a column rule — it is
cross-table logic. It is declared in the inventory so it appears in the dry run, the step log, the
verifier and the report, but its body is PL/SQL.

Worth stating in the guides: OP never touches amounts because it breaks reconciliation. Enabling
`ANONYMIZE_AMOUNTS` on EPF makes the two schemas disagree about the same payment. That is a
legitimate choice for some test copies and a trap for others.

---

## 5. Post-run procedures

Some work is not per-column at all. These get declared in the inventory with rule `PROCEDURE` so
they are logged, verified and reported like anything else, but they run as named PL/SQL after the
column work.

| Procedure | What it does |
|---|---|
| `epf_reset_passwords` | **Keep as close to the original as possible.** Same `oppayments.epf_utils.BCRYPT_ENCRYPT('EPF')`, same `allow_to_validate=0`, `allow_to_sign=0`, `connexion_hit=0`, `locked=0`, `expired_date=SYSDATE+365`, then `epf_utils.GetDataHashCode` per user into `hashcode`. Without this nobody can log in and the copy is useless for testing. Ported verbatim, not redesigned. |
| `epf_perturb_amounts` | The amount work above. Off by default. |
| `epf_recalc_bulk_totals` | Called by the above; also useful alone after a cascade changes payment membership. |

`epf_reset_passwords` is the one piece of this port where "improve it" is the wrong instinct. It
depends on vendor package behaviour we do not control, and it is verifiable only by logging in.

---

## 6. The cascade contract

EPF reads `anon_meta.code_map` directly rather than through the `atrace.ref_tables_modif` view.

The view collapses `ENTITY`, `PORTFOLIO` and `COUNTERPARTY` into the single label `tiers`, because
that is what v3 EPF expected. Reading `code_map` natively gives EPF the **category**, which is what
makes flags cascade: if OP ran with `ANONYMIZE_COUNTERPARTY=n`, there are no counterparty rows in
the mapping, and every EPF column that references a counterparty is left alone automatically — the
same mechanism that already works inside OP, extended across the schema boundary.

`atrace.ref_tables_modif` stays until the old EPF scripts are retired, then goes.

### Preflight must check the cascade

Three states, three different responses:

| State | Response |
|---|---|
| `code_map` empty | **Stop.** EPF cannot cascade from a mapping that does not exist. Run OP first. |
| `code_map` present, some categories absent | **Warn and continue.** The operator disabled them in OP. Report which, so it is a decision rather than a surprise. |
| `code_map` present, OP run failed midway | **Stop.** `anon_run.status` says so. Finish OP first. |

Today EPF's Phase B silently produces zero rows in this situation, which looks like a clean run.

### A latent cascade bug

`anonymize_epf_itr1.sql` maps `payment.portfolio_code` from `table_name = 'tiers'`. Portfolios are a
separate category. It works today only because the compatibility view labels portfolios as `tiers`
too. Reading `code_map` natively would break it — correctly — and it needs to be declared
`category = PORTFOLIO`. Worth checking whether `portfolio_code` really holds portfolio codes on a
live instance before deciding.

---

## 7. Verification and reporting

The OP verifier generalizes with almost no change, because it is already inventory-driven. It gains:

- a `schema` dimension, so one run reports on both;
- residual checks for `COMPOSITE` — is any original component still present in `component_map`? —
  which is the same residual-detection idea applied one level down;
- a check that `DERIVE` columns are **distinct enough**: the Phase 9 defect would have been caught
  instantly by asserting that a derived column has more than a handful of distinct values.

The HTML report gains a schema grouping and sections for the two new inventories. Everything else —
verdict, tiles, coverage by treatment, failures sorted to the top — works unchanged.

The v3 EPF verifier is retired. Its residual-detection idea (PART 6) is already in the v4 OP
verifier; the rest is prefix matching and static `PROMPT` text that computes nothing.

---

## 8. Implementation order

Each phase leaves the tree working. OP keeps running throughout.

| Phase | Work | Risk |
|---|---|---|
| **1** | Inventory schema v2: add `schema`, `flag`, `filter`. Migrate OP's inventory mechanically. Extend the loader, the validator and the wrapper. **OP behaviour must be provably identical** — a dry run before and after producing the same numbers is the gate. | Low, high value: this is the flexibility you asked for, and it lands on the schema we have already tested |
| **2** | Move the engine to `anon_meta`, parameterise by schema. Still only OP runs. | Medium — privilege changes |
| **3** | `DERIVE`, plus the OP account-number rows from *Discovered from EPF anonymization*. Gated off by default. Fixes `code_bban`. | Low |
| **4** | `COMPOSITE` + `component_map` + component layouts. Activate the OP BIC rows. | Medium |
| **5** | Build `inventory_epf.csv` from a live schema - see [§9](#9-phase-5--how-the-epf-inventory-gets-built) | **The real work** |
| **6** | `PROCEDURE` rule; port password reset verbatim; port amount perturbation off by default. | Low, except that password reset needs a login test |
| **7** | Extend verifier and report; retire the v3 EPF verifier. | Low |
| **8** | Guides updated; EPF sections written; release rebuilt. | Low |

Phases 1–4 deliver value to OP alone even if EPF stalls. Phase 5 is where the uncertainty is.

---

## 9. Phase 5 — how the EPF inventory gets built

**Decided: from a live schema.** TANM7881 has no `OPPAYMENTS`, but another instance does, and that
is where discovery happens.

The scripts cannot tell us EPF's coverage — ITR2 implements 3 of the 19 steps it announces, so a
list extracted from them would be confidently, invisibly incomplete. Measuring beats reading.

### Why the existing leak scan will not do

`tools/scan_for_leaks.sql` asks *"does this column still contain a value that appears in
`anon_meta.code_map` as an original?"* That needs an anonymization to have already run. On a fresh
instance `code_map` does not exist and the scan has nothing to search for.

Discovery needs the same idea one step earlier: build the reference population **directly from the
OP identifier tables on that instance**, then ask which `OPPAYMENTS` columns contain those values.

```
   op.structure.code      ┐
   op.tiers.code          ├──→  candidate identifier population  (read-only, never written down)
   op.compte_banque.code  ┘                  │
                                             ▼
              every character column in OPPAYMENTS
                                             │
                                             ▼
              hit count per (table, column)  ──→  inventory_epf.csv draft
```

A hit means that column references an OP identifier and therefore needs `CODE` with the matching
category. It finds tables nobody remembered, which is the entire point, and it is exactly what would
have caught `compte_ana` in OP.

### `tools/discover_epf_coverage.sql` — new

Read-only. Issues no DML, creates nothing, and works on an instance that has never been anonymized.

Three passes:

1. **Identifier references.** Every character column in `OPPAYMENTS` against the candidate
   population above, per category. Output: table, column, hit count, category, total rows.
2. **Free text and PII by shape.** Columns whose *name* matches known PII vocabulary — `name`,
   `address`, `adresse`, `email`, `phone`, `tel`, `iban`, `bban`, `siret`, `bic`, `swift`, `ip`,
   `comment`, `libelle`, `description` — cross-checked against the column being character-typed and
   non-empty. Output: candidates for `NULL_OUT`, ranked by populated-row count.
3. **Structured values.** Columns matching a BIC pattern (`^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$`) or
   an IBAN pattern, including inside key-value tables where the pass reports per `key`. Output:
   candidates for `COMPOSITE` and `DERIVE`, and the `filter` predicate each one needs.

Each pass writes to `anon_meta.discovery_result` if it exists, and always prints a summary.

### The output must be safe to send by construction

`scan_for_leaks.sql` prints a `sample_value` per hit, which is a real client value. **The discovery
script must not.** Its output will be pasted back into a conversation, so it is built so that
everything it emits is safe to share:

| Emitted | Never emitted |
|---|---|
| Table and column names | Any column value |
| Hit counts, row counts, populated counts | Samples, even truncated |
| Category, inferred rule, suggested filter | Distinct-value listings |
| Pattern matched (`BIC`, `IBAN`) | The matching strings |

Safety by construction rather than by remembering to redact.

### What to confirm before running it

Whether that instance is a restored copy or something closer to production. The script is read-only
and prints no values, but a full-schema scan is not free, and running anything against a live
system is a decision for whoever owns it rather than a default.

**Also to confirm, for phase 2:** may `anon_meta` hold `UPDATE` on both `OP` and `OPPAYMENTS`
([§2](#2-shape-of-the-port))? Only relevant when the engine moves; OP runs unchanged until then.

---

## 10. Decisions already taken

| | |
|---|---|
| Coverage control | `flag` column in the CSV — gating becomes data, not engine code |
| New rules | `COMPOSITE`, `DERIVE`, `PERTURB`, `PROCEDURE` |
| Amounts | Implemented, **off by default** |
| Password reset | Ported **verbatim** — application login must still work |
| OP-schema gaps | Recorded in `inventory_op_custom.csv` under *Discovered from EPF anonymization*, commented out, to be gated off by default when activated. Source file to review: `Anonymization_EPF/sql/anonymize_epf_phase9_op_bic_bban.sql` |
| EPF inventory | Built by measuring a live `OPPAYMENTS` schema, not by reading the scripts — `tools/discover_epf_coverage.sql`, read-only, emits no client values |
