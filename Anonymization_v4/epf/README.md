# epf/ — not yet ported

The EPF (`OPPAYMENTS`) anonymization has **not** been rebuilt on the v4 architecture yet. It still
runs from the original location:

```
Anonymization_EPF/
├─ sql/start_epf_anonymization.bat        ← entry point
├─ sql/start_anonymous_epf.sql            ← orchestrator, phases A–H
├─ sql/anonymize_epf_itr1.sql             ← phase B: code cascade from OP
├─ sql/anonymize_epf_itr2.sql             ← phase D: users, free text, addresses
├─ sql/anonymize_epf_phase7_refdata.sql   ← phase E: REF_TIERS, REF_BANK_BRANCHE
├─ sql/anonymize_epf_phase8_swift_audit.sql
├─ sql/anonymize_epf_phase9_op_bic_bban.sql
├─ sql/bic/1..5                           ← phase C: BIC components + payment amounts
└─ sql/verify_epf_anon_coverage_final.sql
```

**Order is unchanged: OP must complete before EPF.** EPF phase B reads the code mapping OP
produces. Until the port is done, that means the *v3* mapping table — so if you run v4's OP
anonymization, EPF phase B will not find what it expects. Run both halves from the same generation
until this is resolved.

## What the port involves

Most of the work is writing `config/inventory_epf.csv`. The engine, run state, logging, dry run and
verifier are schema-agnostic and already handle a second inventory.

The EPF-specific pieces that do *not* fit the inventory model and will need engine support or
dedicated steps:

| Piece | Why it doesn't fit |
|---|---|
| **BIC/SWIFT component anonymization** (`bic/1..4`) | A BIC decomposes into bank/country/location/branch sub-fields, each mapped independently and reassembled. Not a whole-column replacement. |
| **Payment amounts** (`bic/5`) | Numeric perturbation, not identifier mapping. |
| **Password reset + hashcode recalculation** (phase H) | Application-specific; must run last, and users cannot log in without it. |
| **Orphan code synthesis** (phase A) | EPF codes with no OP counterpart get generated mappings so the cascade is total. |

## Carry this into the port: a verifier must not share the engine's assumptions

Learned the hard way on OP, and it cost a run that reported `PASS` on a database with live client
data in it.

`verify_op_coverage.sql` originally restricted its residual search **the same way the engine
does** — for a column declared `BANK_ACCOUNT`, it looked only for bank-account codes, because that
is all the engine would have substituted. That felt correct. It is not.

`param_cpta_reg_gen.compte_ana` was declared `BANK_ACCOUNT` but actually held **counterparty**
codes. The engine skipped them because of the declared category. The verifier skipped them for the
identical reason. Engine and verifier agreed, both were wrong, and five rows of real client data
survived a run that reported clean.

**A verifier that re-applies the engine's assumptions can only ever confirm them.** It cannot detect
an assumption that is itself wrong — which is the most likely kind of mistake in an inventory
assembled by hand.

The rule, for the EPF verifier:

| Share with the engine | Never share with the engine |
|---|---|
| **Definitions** — what an anonymized value looks like: the `E_`/`P_`/`T_`/`CB_` prefixes, the `ANONYMIZED` mask marker | **Scope** — which rows or columns are worth looking at |
| | **Restrictions** — any filter the engine applied for correctness or performance |

Concretely: search the **full** mapping for every identifier column whatever its declared category,
and let the check be stricter than the run. If it fails on a column the engine deliberately skipped,
that is the check doing its job — make the message explain why, rather than narrowing the search.

EPF has more of these restrictions than OP did, not fewer: BIC components are matched by
sub-field, payment amounts by numeric range, orphan codes by a synthetic mapping. Each is a place
where the verifier could quietly inherit the engine's blind spot.

Full detail in [../unofficial docs/10_test_log.md](../unofficial%20docs/10_test_log.md), defect T8.

## What v4 already took from EPF

- The `epf_anon_log` run-logging pattern, generalized into `anon_meta.anon_step_log`.
- The residual-value check from `verify_epf_anon_coverage_final.sql` PART 6 — asking "is any *real*
  identifier still present?" rather than "does this value look anonymized?" — which is now the
  primary check in `op/verify/verify_op_coverage.sql`.
- Correct escaped `LIKE … ESCAPE '\'` prefix matching, which the EPF verifier got right and the OP
  one did not.

See [../unofficial docs/05_history.md](../unofficial%20docs/05_history.md) for the full comparison.
