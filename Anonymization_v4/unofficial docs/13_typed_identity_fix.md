# 13 — The typed identity fix (2026-10-20)

> **For a reviewer.** This traces every requirement of
> [fixes+needed_in_v4.txt](fixes+needed_in_v4.txt) to the code that implements it and the test
> that proves it, and compares the result with the legacy row-by-row package
> (`Anonymization_OP/sql/02pack_anonym_number.sql`, run by `start_anonymous.sql` with
> `config.ini`). Every statement about the legacy package can be checked against that file.
> Appendix A lists every identifier column with the evidence its type rests on.

| | |
|---|---|
| Specification | `fixes+needed_in_v4.txt` — prepared 2026-10-16, decisions updated 2026-10-20 |
| Business confirmation | 2026-10-20: an account node is any node on the `w_compte_banque` screen — section 2.4 |
| Code | branch `v4-typed-identity-fix`: commit `20b687f` (the fix), then a follow-up commit — account nodes by screen (2.4) and the X_ results (2.5) |
| Tested | 20 scenarios, 512 checks, all passing, on a disposable Oracle 21c XE with fictional data — `tests/regression/` |
| Not yet | run on a client database. EPFPG785 as it is now was anonymized by the previous v4, and the new engine refuses it by design (section 5 of the specification): it needs a fresh raw import |

## Contents

1. [What changed](#1-what-changed)
2. [Points explained](#2-points-explained) — approval, column typing, review, account nodes, X_ results
3. [Requirement by requirement](#3-requirement-by-requirement)
4. [Compared with the legacy row-by-row package](#4-compared-with-the-legacy-row-by-row-package)
5. [Decisions that need confirmation](#5-decisions-that-need-confirmation)
6. [Known gaps and limits](#6-known-gaps-and-limits)
7. [How it is tested](#7-how-it-is-tested)
8. [Files](#8-files)
- [Appendix A — every identifier column and its evidence](#appendix-a--every-identifier-column-and-its-evidence)
- [Appendix B — labels, attributes and free text](#appendix-b--labels-attributes-and-free-text)
- [Appendix C — metadata objects](#appendix-c--metadata-objects)
- [Appendix D — statuses, verdicts, exit and error codes](#appendix-d--statuses-verdicts-exit-and-error-codes)

---

## 1. What changed

**Before.** Every identifier column except the ones declared BANK_ACCOUNT looked its value up in one
untyped table, `anon_meta.code_map_any`, holding a single "winning" replacement per text, chosen by
the priority ENTITY > PORTFOLIO > COUNTERPARTY > BANK_ACCOUNT. Both defects of the specification
came from it:

- **A** — a party whose text matched only a bank account received that account's CB_ value
  (754 tiers records on EPFPG785), and kept no party translation;
- **B** — an account node whose text matched a party received the party's E_/P_/T_ value while its
  compte_banque master received CB_.

**Now.**

1. **Identities are captured, typed and recorded before anything changes.** One statement reads
   `tiers`, `compte_banque` and `structure` and records every identity in
   `anon_meta.identity_inventory`, keyed `(domain, old_code)`:
   - **PARTY** — tiers rows, structure nodes on the `w_tiers` screen, and confirmed references;
   - **ACCOUNT** — compte_banque rows and structure nodes on the `w_compte_banque` screen (the
     screen alone decides — section 2.4).

   Each party gets exactly one category, in the order of specification section 2A: PORTFOLIO
   (P_), ENTITY (E_), COUNTERPARTY (T_), or UNCLASSIFIED_PARTY (X_) with the reason recorded. The
   classification is recorded once and never silently changed afterwards.
2. **Columns are typed.** Each identifier column says which domain it holds — `PARTY`,
   `BANK_ACCOUNT`, `MIXED` (reviewed: both) or `NODE_ROLE` (structure.code and structure.pere,
   typed per row) — and only that domain's translations are ever written into it. `ANY` is refused.
3. **One plan per run.** Preflight builds `anon_meta.identity_plan`: every identity, its single
   translation (reused, or appended after the existing numbers), its three switches and its parent
   role. A dry run estimates against that plan; an EXECUTE run persists it, then applies it. Anything
   unsafe — data already anonymized, incompatible earlier translations, unapproved structure-only
   accounts, collisions, a value that cannot fit its column — stops the run before any update.
4. **Fifteen independent switches.** ID / DESCRIPTION / ATTRIBUTES for each of ENTITY, PORTFOLIO,
   COUNTERPARTY, UNCLASSIFIED_PARTY and BANK_ACCOUNT, all on by default. Labels and attributes
   receive the identity's translation — also when its identifier is kept — and an empty attribute
   stays empty.
5. **No checkbox exceptions.** `MIN_CODE_LENGTH` and the width-1 column rule are gone. Every listed
   column is processed; the four width-1 columns the old rule skipped silently are now excluded in
   the inventory, with the reason.
6. **An honest verdict.** The verifier checks the data against the plan of the last completed run
   and answers PASS (exit 0), FAIL (2), REVIEW REQUIRED (3) or INCOMPLETE (4). The report, the batch
   file and the tools follow.
7. **Unclassified parties are shown, not just counted.** A dry run lists the X_ parties by reason
   and by where they were found, says why each kind is X_ and what would classify it, and prints one
   query per reason that lists them. The real run and its report give the counts, by reason and by
   table, with the reasons — section 2.5.

---

## 2. Points explained

### 2.1 Structure-only bank accounts need an explicit approval

A bank account is found in two places: its master row in `compte_banque`, and usually a node in the
structure tree on the screen `ecran = 'w_compte_banque'` (classified `structure = 'Compte'`; the
screen alone decides — section 2.4). Section 2 of the specification makes the account population
the union of both, and records where each account was found:

| Found in | Recorded as |
|---|---|
| compte_banque and a node | BOTH |
| compte_banque only | MASTER_ONLY |
| a node only | **STRUCTURE_ONLY** |

STRUCTURE_ONLY accounts are new scope: neither the legacy package nor the previous v4 anonymized
them as accounts (the previous v4 renamed such a node only if its text happened to match some other
map). The specification asks to confirm, per client, that such a node really is a bank account, and
to stop for scope review until then. That is the setting `APPROVE_STRUCTURE_ONLY_ACCOUNTS`:

- `y` — confirmed. Each structure-only node gets its own CB_ translation, written to the node and to
  every account column referring to it.
- `n` — not confirmed. If the data has structure-only nodes, preflight stops the run before
  changing anything and says how many; a dry run shows the same count. If the data has none, `n`
  changes nothing.

Where the value comes from:

- `config/anonymization.template.ini` sets it to `n`.
- The working `config/anonymization.ini` leaves it **blank**. The batch file asks for every blank
  value when run interactively — *"Structure-only account nodes are bank accounts here [n]"*, Enter
  meaning `n`. With `/auto` nothing is asked and `n` applies.
- A configuration written before this fix has no such line, which behaves as blank.

It only matters when structure-only accounts exist. Section 2 of
`tests/manual/typed_identity_diagnostics.sql` counts them, read-only, before any run.

### 2.2 How each column was typed

Each identifier column must now say what it holds. That was decided from what the programs
actually wrote into it, never from its name — a name misleads: `param_cpta_reg_gen.compte_ana`
contains "compte" and holds party codes.

**Evidence 1 — the legacy package.** `start_anonymous.sql` calls `pack_anonym.anonymous_tables`
four times, one per branch: Entite, Portefeuille, Tiers, then Compte. Each branch walks its own
codes and updates a fixed list of columns with the code it is processing
(`update op.X set C = :1 where C = :2`). A column updated only by the three party branches held
party codes; only by the Compte branch, account codes; by both, either.

**Evidence 2 — v3.** `06_op_setbased_anonym.sql` restricted bank-account columns to account
mappings by passing `'COMPTE'` to `merge_codes`.

| Type | Columns | Basis |
|---|---:|---|
| PARTY | 364 | 223 updated only by the legacy party branches (tiers.code among them); 141 added by v4 (CTI and KTP tables) whose names name a party — entity, portfolio, counterparty, bank, issuer, depositaire, correspondant… |
| BANK_ACCOUNT | 83 | 71 already BANK_ACCOUNT — the account master, 43 legacy account-branch columns, `compte_banque.code_bban`, `val_bank_account.code`, 25 v4 additions naming an account; **12 retyped from ANY** |
| MIXED | 10 | the five `clearing_member` columns and `ventiler_compte.valeur_1-4`, which the legacy package wrote in all four branches; `param_cpta_reg_gen.compte_ana`, the known analytical exception |
| NODE_ROLE | 2 | `structure.code`, `structure.pere` — they hold party AND account nodes |
| excluded | 3 | the one-character `tiers_entite` discriminators |

**The ten mis-copied columns.** v3 wrote the account restriction two ways: as a named argument,
`merge_codes(..., p_entity_type => 'COMPTE')` (48 calls), and as a fourth positional argument after
a parallel hint, `merge_codes('histo_operation', 'compte_tiers', 'PARALLEL(4)', 'COMPTE')`
(10 calls). When the v4 inventory was built from v3, the 48 became BANK_ACCOUNT and the 10 became
ANY:

```
histo_mouvement.compte            histo_operation.compte_tiers       histo_reglement.compte
histo_mouvement.compte_contrepartie histo_operation.compte_tiers_2   histo_reglement.cpty_account
histo_operation.compte_entite     histo_operation.compte_entite_2
histo_operation.compte_filiale    histo_operation.tiers_iban_compte
```

The legacy package updates exactly these ten only in its Compte branch. Two independent sources
agree, so they are BANK_ACCOUNT again. The other two of the twelve, `param_fiche_val_detail.code`
and `vue_affilie_compte.code_ref`, rest on the legacy package alone (v3 did not restrict them).

**What a type means at run time:**

| Column type | value known only as a party | only as an account | as both | as neither |
|---|---|---|---|---|
| PARTY | its party translation | **left — verification FAILs**: the column holds the other domain | its party translation | left (warning) |
| BANK_ACCOUNT | **left — FAIL** | its account translation | its account translation | left (warning) |
| MIXED | its party translation | its account translation | **left — REVIEW** | left (warning) |

If a column holds the other domain, the verifier says so ("original(s) of the OTHER domain
remain") and `tools/analyze_flag_impact.sql` lists it under *Columns holding the other domain*. The
correction is one line in `config/inventory_op_custom.csv`.

### 2.3 Values left for review instead of guessed

In three situations the data does not say which object a value refers to. A guess would write the
wrong replacement or break a link, silently. So the value is left unchanged, counted in the run log
with status `REVIEW`, and the verdict is **REVIEW REQUIRED** (exit 3) rather than PASS — the client
value is still in place, and the report lists it.

| Situation | Example — fictional, from the regression fixture | Why it cannot be decided |
|---|---|---|
| A structure node on a screen other than `w_tiers` (party nodes) and `w_compte_banque` (account nodes) whose code is a client identifier | node `OSCN` on screen `w_autre`, where OSCN is also a tiers code | Specification section 3: other nodes need an explicit reviewed policy — "never infer from text alone". The node may be the same party shown in another tree, or something else with the same code |
| A `structure.pere` whose text is carried by both a party node and an account node, or by a node on another screen | a node whose pere is `SHRD`, where SHRD is both an Entite node and an account node | Section 4: "if party/account keys coincide and the parent role cannot be established, require explicit review". Which of the two nodes is the parent? |
| In a MIXED column, a text that is both a party and a bank account | `ventiler_compte.valeur_1 = 'SHRD'` | The column holds either kind and both translations exist; neither is provably right |

**"No way to record a reviewed decision yet."** Once someone has decided, the tool should be told.
For MIXED columns it already can be, per column: retype the column in `inventory_op_custom.csv`
(MIXED → PARTY or BANK_ACCOUNT) and its ambiguous values follow that domain. For other-screen nodes
and ambiguous parents there is no setting yet. The improvement phase should add one — for example
a reviewed list of screens whose nodes are party nodes, account nodes, or not identifiers.
Sections 5 and 6 of `typed_identity_diagnostics.sql` show how many such cases a database has.

### 2.4 Account nodes: the screen decides

The specification identified an account node by two conditions, `structure = 'Compte'` **and**
`ecran = 'w_compte_banque'`. The business confirmed on 2026-10-20 that the screen alone is enough:
every node on `w_compte_banque` is a bank-account node, whatever its classification. The engine,
the verifier, the diagnostics and every text now test `ecran = 'w_compte_banque'` only.

A node's role is therefore its screen, and the three roles cannot overlap:

| `structure.ecran` | Role | What happens to `code` | Its `pere` points at |
|---|---|---|---|
| `w_compte_banque` | account node | the account's CB_ — its master's, or its own when it has no compte_banque row (approval, 2.1) | whatever its parent is (section 4 of the specification) |
| `w_tiers` | party node | the party's E_/P_/T_/X_ | the same |
| anything else, or empty | other screen | left unchanged; REVIEW when it holds an identifier (2.3) | the same |

**What changed in practice.** A node on `w_compte_banque` classified other than `Compte`, or not
classified at all, used to count as a node "on another screen": left unchanged and reported for
review — or, when its code was also a party's, a reason to classify that party NO_PARTY_SCREEN. It
is now an account node: it takes its account's CB_, the pere of its children follows, its label is
masked as an account label, and it does not count as one of a party's nodes. A `Compte` node on
`w_tiers` is unaffected: it is a party node (a counterparty), by its screen.

On data where every `w_compte_banque` node is classified `Compte`, nothing changes. Section 5 of
`tests/manual/typed_identity_diagnostics.sql` lists every (classification, screen) pair with its
role, so the client data shows whether any other classification exists on `w_compte_banque`.

Proved by S18: an account node classified `Banque` with a compte_banque row, and an unclassified
one without, both become bank-account identities — the first holds its master's CB_, the second
its own, the second's pere becomes the first's CB_, both labels are masked, nothing is left for
review, PASS. Before this change both would have been left for review.

### 2.5 Unclassified parties (X_) in the results

An X_ party is one whose kind — entity, portfolio or counterparty — the data does not establish
(section 2A of the specification). It is anonymized like every other party, with an X_ value. But
the X_ population is worth seeing before the real run: some are fixable data problems, some are
leftovers that are fine as X_. So:

| | Dry run | Real run (EXECUTE) |
|---|---|---|
| Count by reason, and by where the parties were found (tiers row, w_tiers node, node on another screen) | yes | yes |
| The general reason each kind is X_ | yes | yes |
| What would let the data classify each kind | yes | — |
| One query per reason that lists them | yes | — |
| Identifier rows that get an X_ value, by table — and per column, on each column's line | yes, "would be renamed" | yes, "renamed by this run" |
| The coverage report (HTML) | — (a dry run has none) | section *Unclassified parties (X_)*: by reason with the reason, and by table |

"Category" in the request is read as the X_ **reason** — the five sub-kinds of X_. "Table" is read
both ways: where the parties were found (tiers, structure), which is where a fix would go, and
which tables receive their X_ values, which is what leaving them costs.

**The dry run output**, from the regression fixture (fictional codes; the counts are of parties,
not rows):

```
    Unclassified parties (X_) 7
      The data does not say which kind of party these are. By reason, and by
      where each party was found (parties, not rows):

      reason                     parties      tiers   w_tiers node   other screen
      missing master                   2          0              2              0
      no structure                     2          2              0              0
      unknown flag                     2          2              2              0
      unknown classification           1          1              1              0

      Why they are X_:
        missing master           The code is a party in the structure tree (a w_tiers node) or a
                                 confirmed reference, but tiers has no row for it - so there is no
                                 flag_portefeuille to tell a portfolio from an entity or a
                                 counterparty.
        ...

      Before the real run, fix the data or leave them X_:
        missing master           Add the missing tiers row with its flag_portefeuille, or correct
                                 the node's code if it is a typo. A node left over from a deleted
                                 party can stay X_.
        ...

      To list them - one query per reason. They read this dry run's plan, so
      run them before the next run starts:

        -- missing master
        SELECT p.old_code AS code, p.membership, s.ecran, s.structure, s.pere
          FROM anon_meta.identity_plan p
          LEFT JOIN op.structure s
                 ON s.code = p.old_code AND NVL(s.ecran, '~') <> 'w_compte_banque'
         WHERE p.run_id = 1 AND p.domain = 'PARTY'
           AND p.category = 'UNCLASSIFIED_PARTY' AND p.x_reason = 'MISSING_MASTER'
         ORDER BY p.old_code, s.ecran, s.structure;
        ...
```

and at the end of the run:

```
    Unclassified parties (X_): 7 - identifiers that would be renamed to X_, by table
      structure ............................ 5 rows        1 column
      tiers ................................ 5 rows        1 column
      histo_operation ...................... 2 rows        2 columns
      compte_regle ......................... 1 row         1 column
      total ................................ 13 rows in 4 tables
```

Each identifier column's own line says it too: `tiers.code  DRYRUN  15 rows would change, 5 to X_`.

**The five reasons**, in the order the classification tests them:

| Reason | Why the party is X_ | What would classify it | What its query lists |
|---|---|---|---|
| missing master | a w_tiers node or a confirmed reference has the code, but tiers has no row: no flag_portefeuille to read | add the tiers row, or correct a mistyped node code; an orphan node can stay X_ | each code with where it was found (STRUCTURE_ONLY / REFERENCE_ONLY) and its nodes: screen, classification, parent |
| no structure | the tiers row has no node in the structure tree (a w_compte_banque node with the same text is a bank account, not this party) | add its w_tiers node, or leave it X_ | the whole tiers rows, so they can be recognised |
| no party screen | the tiers row has nodes, but none on w_tiers; a node on another screen classifies nothing | add a w_tiers node, or leave it X_ and decide what its other nodes are | its nodes on other screens, with the flag |
| unknown flag | flag_portefeuille is not O or N — empty, another value, or different on duplicate tiers rows | set the flag; remove the duplicate | the whole tiers rows |
| unknown classification | flag N, but every w_tiers node has an empty classification: neither Entite nor a counterparty | set the classification on its w_tiers node | its w_tiers nodes, with the flag |

**How it is built.**

- The texts and the five queries live in one place, a new table `anon_meta.unclassified_reason`,
  refreshed by every run. The run output and the report read it; so can anyone:
  `SELECT label, why, fix FROM anon_meta.unclassified_reason ORDER BY sort_order`.
- The run output never contains an identifier — the queries are **printed for the operator to
  run**, with the run id filled in. They read the dry run's plan (`anon_meta.identity_plan`), which
  the next run replaces: run them before starting another run. After a fix, a new dry run shows the
  new counts.
- The X_ rows per column are counted in the pass that already happens — in the dry run's count,
  and in the real run's `UPDATE` through a `RETURNING COUNT(...)` aggregate, so no table is read
  twice. They are stored per step in a new column, `anon_step_log.x_rows`; the summary and the
  report add them up by table:
  `SELECT object_name, x_rows FROM anon_meta.anon_step_log WHERE run_id = <run> AND x_rows > 0`.
- With `ANONYMIZE_UNCLASSIFIED_PARTY=n` the counts and reasons are still shown, and the output says
  their codes are kept.
- The run output used to lose its indentation and blank lines (SQL*Plus's default
  `SERVEROUTPUT` format strips them), which made tables hard to read and the queries awkward to
  copy. `00_run_op_anonymization.sql` now sets `FORMAT WRAPPED`, as the verifier already did.

Proved by S19: on the fixture plus the review cases (all five reasons, eight parties), the dry run
shows the five reason lines with the right counts, the reasons, the fixes and five queries; **each
printed query is run and lists the expected parties**; the by-table figures are right (14 rows in 4
tables); the real run shows counts and reasons but no fixes and no queries, the same by-table
figures, and the same total in the step log; the report has the section; and none of the eight
codes appears in the run output or the report. A second real run with `ANONYMIZE_UNCLASSIFIED_PARTY=n`
says the codes are kept.

---

## 3. Requirement by requirement

Engine procedures are in `op/sql/30_install_engine.sql`; "verifier" is
`op/verify/verify_op_coverage.sql`; S-numbers are the scenarios of
`tests/regression/run_regression.sh` (section 7).

### Section 1 — the two defects

| Requirement | Implementation | Proved by |
|---|---|---|
| **A.** Party references accept only party translations; missing parties are discovered and classified separately; COUNTERPARTY is never inferred from a name; a missed identifier is not simply made T_ | Party columns are typed PARTY. `apply_code` → `apply_lookup(.., 'PARTY')` reads `anon_meta.code_lookup` domain PARTY, which holds party identities only — no fallback to any other. Every tiers row is a party candidate (`capture_identities`), classified from its own master row and nodes; one the data cannot classify is X_ | S1 "party columns holding SHRD got the PARTY translation, not CB_", "tiers.code holds no CB_ value", "no party column holds an account translation". Verifier PART 2 fails a CB_ value in a PARTY column |
| **B.** An account node takes its master's BANK_ACCOUNT translation whatever party shares its text; more account maps alone do not fix it | `structure.code` is `NODE_ROLE`: account nodes (`ecran='w_compte_banque'`) read the ACCOUNT lookup, party nodes (`ecran='w_tiers'`) the PARTY lookup — two statements with disjoint predicates | S1 "shared text: account node holds the SAME account translation", "... party node keeps the PARTY translation". Verifier PART 1 "account nodes carry their master's translation" |

### Section 2 — the account inventory

| Requirement | Implementation | Proved by |
|---|---|---|
| Union of compte_banque and the account nodes (specification: `Compte` nodes on `w_compte_banque`); NULL codes excluded | `capture_identities`, CTEs `bm` and `nd` (role A) | S1 |
| *Changed 2026-10-20 by business confirmation:* an account node is identified by `ecran = 'w_compte_banque'` alone, not also by `structure = 'Compte'` — section 2.4 | role A is the screen alone, in the engine, the verifier and the diagnostics | S18 |
| The union deduplicates; one stable CB_ per distinct code; a party with the same text keeps its own; key (category, old_code); replacements globally unique | identity key `(domain, old_code)`; `code_map` primary key `(category, old_code)` and unique index on `new_code` kept; a unique index on the plan; `validate_plan` collision checks | S1 "duplicate account nodes: both rows, one identity", "shared text: party and account translations differ" |
| Record MASTER_ONLY, BOTH, STRUCTURE_ONLY and report the counts | `identity_inventory.membership`; printed by preflight (`report_plan`); verifier PART 1 | S1 "account sources: MASTER_ONLY 3, BOTH 3, STRUCTURE_ONLY 1" |
| Stop for scope review until the account-node population is approved | `APPROVE_STRUCTURE_ONLY_ACCOUNTS`; `validate_plan` blocks new structure-only accounts unless `y` — section 2.1 | S3 |
| A STRUCTURE_ONLY identity stays in scope; no master is inserted or repaired | its own CB_; no master created | S1 "structure-only account node renamed with its own translation" |
| FLAG_GERE is no gate; no node is required; w_tiers nodes are not account sources | no such filter; role A only | S1 "FLAG_GERE is no selection gate" |
| Exact text; one-character identifiers included, with no exception list | no TRIM or UPPER anywhere; no length filter | S1 "one-character account Q ..." |

### Section 2A — party classification and X_

| Requirement | Implementation | Proved by |
|---|---|---|
| Candidates: tiers rows, w_tiers nodes, separately confirmed reference-only identities. Nothing silently excluded; not every node or string | `capture_identities` keys: tiers ∪ role-P nodes ∪ `anon_meta.confirmed_identity` (domain PARTY) ∪ identities already recorded. Nodes on other screens are not candidates | S16 |
| One category per identity, examining all its nodes, in the order PORTFOLIO, ENTITY, COUNTERPARTY, X_ | CTE `c` of `capture_identities` | S0 (the specification's 7A check), S1 (all 17 fixture parties) |
| X_ for a NULL or unknown flag, a missing master, no structure node, no qualifying node; a NULL classification with flag N is X_, not a counterparty | the same | S1: NFLG, IFLG, NMEN, NMCP, NSTN, NSTO, NCLN |
| A missing master is X_ even for a Compte/w_tiers node | `n_master = 0` is tested first | S1 NMCP |
| ENTITY wins for flag N with Entite and non-Entite w_tiers nodes; the overlap is logged; one E_ everywhere | E before T in the order; `entity_overlap`, logged by `report_plan`, shown by the verifier | S1 "entity precedence logged for EOVL only" |
| Account-screen nodes stay BANK_ACCOUNT even when their text equals a party's | role-A nodes do not count as a party's nodes | S1 SHRD |
| X_ reasons recorded as non-sensitive metadata | `identity_inventory.x_reason`, constrained to the five reasons | S1 |
| Classification follows source facts, never the switches; switching ENTITY off cannot turn an entity into X_ | classification ignores the switches; `apply_switches` requires the switch of the recorded category AND of the translation's category | S5, S7 |

Reason order is my choice — the specification lists the reasons but not their order when several
apply: MISSING_MASTER → NO_STRUCTURE (no node at all, account nodes not counted) → NO_PARTY_SCREEN
(nodes, none on w_tiers) → UNKNOWN_FLAG → UNKNOWN_CLASSIFICATION.

### Section 2B — PARTY lookup and UNCLASSIFIED_PARTY

| Requirement | Implementation | Proved by |
|---|---|---|
| PARTY = {ENTITY, PORTFOLIO, COUNTERPARTY, UNCLASSIFIED_PARTY}, never BANK_ACCOUNT; a lookup policy, never a mapping category | inventory category `PARTY`; `code_map` holds only the five real categories | verifier PART 5 "every mapping has a known category" |
| Resolved directly from the allowed set — no ANY winner filtered afterwards | `code_lookup` built per domain from the plan; `code_map_any` dropped | S1 |
| Genuine account fields BANK_ACCOUNT only; reviewed mixed fields explicit; ANY not mass-replaced | each column typed from evidence (Appendix A); 10 MIXED | — |
| X_ implemented consistently: generation, gates, description and attribute handling, configuration, loader, run metadata, preflight, dry run, verifier, report, tools, tests | `allocate_maps` (X_ prefix), `anon_run_setting`, `merge_owned`, ini/template/batch/`configure`, CHECK constraints, `report_plan`, verifier, report, scan_for_leaks, analyze_flag_impact, generate_coverage_doc, inspect_code_map | S5 runs X_ through all 8 combinations |
| Category constraints extended on new AND existing metadata | `10_create_metadata_schema.sql` recreates `ck_anon_inv_cat` after its TRUNCATE | S13 |
| code_map keeps its `(category, old_code)` key and unique `new_code`; no CHECK was there | unchanged; two columns added (`run_id`, `id_applied`) | S13 |
| Every category CASE/ELSE audited: X_ never falls into BANK_ACCOUNT handling, is never silently disabled, never ties | `prefix_of` has no ELSE; the old `ELSE 4` priority went with code_map_any | — |
| X_ in the prefix diagnostics; membership and category validated, never a prefix taken as proof | verifier PART 7 counts `X\_`; PART 5 checks every translation's format against its RECORDED category; residuals use recorded membership (`verify_key`), never prefixes | S1 "X_ translations have the X_ format" |
| Width, uniqueness and old/new collisions for X_ too | `needed_width` (a party value is 9 wide), `validate_plan` | S14 |
| An X_ never silently becomes E/P/T after master data changes; incompatible earlier party maps detected before updates | classification recorded once; a change is reported REVIEW and the recorded translation kept; two earlier party translations with none matching stop the run | S8, S11, S12 |
| X_ owners' descriptions, names, addresses, phone, fax, email masked | the tiers DESCRIPTION and SELF_CODE rows are typed PARTY — decision 5.1 | S1 "X_ owner (no structure): description, address, phone, name masked" |
| X_ counts and reasons reported without claiming the business category; disabled coverage never a PASS | report sections *Identities* and *Unclassified parties (X_)*; the run output by reason and by table, and in a dry run one query per reason (section 2.5); INCOMPLETE verdict | S5, S19 |

### Section 3 — apply by identity domain and row context

| Target | Allowed translation | Implementation |
|---|---|---|
| `compte_banque.code` | BANK_ACCOUNT only | inventory BANK_ACCOUNT; `21_validate_inventory.sql` refuses anything else |
| `structure.code` on `w_compte_banque` | BANK_ACCOUNT, by the node's own code | NODE_ROLE, the account-node statement |
| `tiers.code` and party references | PARTY | inventory PARTY; tiers.code fixed by validation |
| party nodes (`w_tiers`) | PARTY | NODE_ROLE, the party-node statement |
| other nodes, mixed references | explicit reviewed policy | other nodes left and reported REVIEW; mixed columns MIXED |

| Requirement | Implementation | Proved by |
|---|---|---|
| With account renaming on, the SAME BANK_ACCOUNT.new_code on master and node | one lookup for both | S1; verifier PART 1 |
| A translation made only for labels or attributes renames nothing | `code_lookup` holds only identities whose ID switch is on. The EPF view lists only translations applied to identifiers in THIS data (`code_map.id_applied`, recomputed each run from `seen_renamed`) | S5 "master identifier kept", "in the EPF view only when renamed"; S7 |
| Not by retyping all of structure.code, not by processing order; mutually exclusive handling; no row processed by two rules | the NODE_ROLE handler; the two predicates are disjoint by construction (`ecran = 'w_compte_banque'` against `ecran = 'w_tiers'`). There is no separate runtime assertion | — |
| Unknown nodes visible as REVIEW, never treated as clean | `count_review` "[other screens]"; verifier REVIEW | S4 |
| The inventory key is (table, column): no competing duplicate rows | a small structure handler instead | — |
| PARTY enforced in metadata, loader, validation, preflight, engine, verifier and report together | all of the above | S14 refuses ANY, a single party category on CODE, tiers.code as BANK_ACCOUNT |

### Section 4 — structure.pere and other references

| Requirement | Implementation | Proved by |
|---|---|---|
| PERE takes the parent's typed translation, established from the hierarchy and the pre-update context — never the child's domain | `resolve_parent_roles`, per text, from the nodes carrying it before the run: one kind of node → that kind; no node → the one domain it is an identity of; party AND account nodes, or a node on another screen → AMBIGUOUS / OTHER. Stored in the plan as `parent_role`; `apply_code` uses lookup `PERE` | S1: an account node under a party node gets the party translation; a parent known only as an account gets the account translation |
| Coinciding keys with an unestablished parent role → explicit review | AMBIGUOUS / OTHER left unchanged, REVIEW | S4 |
| The legacy PERE filter (`structure='Compte'` without the screen) is not taken as proof | not used | — |
| Account-reference and analytical fields reviewed individually; compte_ana is an exception; BBANs and account numbers out of scope | Appendix A; compte_ana MIXED; code_bban unchanged (section 6) | — |

### Section 5 — preflight, map reuse, masked copies

| Requirement | Implementation | Proved by |
|---|---|---|
| **1.** A consistent dataset identity; candidates, membership, row roles, parent roles | one `INSERT ... SELECT` reads the three core tables, so one read-consistent statement captures every identity; `anon_run.dataset_json` records the database, OP's creation date, row and identity counts; the plan holds membership, node facts and parent roles | S1 |
| **2.** Unknown or conflicting roles resolved or excluded; required objects, widths, enabled categories, uniqueness, old/new overlap checked; no other domain's map borrowed when a switch is off | other-screen and ambiguous values excluded and reported; -20013 for missing core objects; `check_inventory` widths per type; `anon_run_setting`; `validate_plan`; lookups are per domain | S4, S14 |
| **3.** All missing translations allocated before any CODE update; reused; appended, never renumbered. The old "return if the category has any map" is gone | `allocate_maps` numbers after the highest existing number of the category; `generate_code_map` persists before `apply_inventory` starts | S2, S6, S11 "new translations continue after the existing numbers" |
| **4.** Exactly one permitted translation per candidate; every target unambiguous; the dry run estimates against the plan | the last check of `validate_plan`; verifier PART 1; the lookups are built from the plan in both modes | S1 "dry run estimated against its plan", "dry run persisted no mapping and froze no classification" |
| Masked copies: never treat current replacements as raw identities; use preserved provenance or reimport | a row an earlier run renamed is resolved back only through its OWN domain's recorded translation. A master or node holding any other replacement, or a value that looks generated and that no translation owns, stops the run | S9, S10 |
| A lookup change does not undo wrong substitutions; no repair by prefix | no repair attempted | — |

### Section 5A — checkbox safeguards removed

| Requirement | Implementation | Proved by |
|---|---|---|
| `is_flag_column` and its width exclusions gone from preflight, CODE, NULL_OUT, DESCRIPTION, SELF_CODE, dry run and verification | removed from the engine and the verifier | S14 "a one-character free-text column is processed ... emptied, not skipped" |
| `MIN_CODE_LENGTH` / `g_min_code_length` and every LENGTH filter gone | removed from the engine, the orchestrator's parameters, the batch file, both ini files, the verifier, and `scan_for_leaks.sql` (its `MIN_LEN`) | S1 one-character Z and Q |
| Gone from parsing, defaults, validation and newly recorded configuration; historical run metadata untouched and not used | `config_json` no longer records it; the verifier no longer reads it | S13 keeps an old run record carrying min_code_length |
| No CHECKBOX / SKIPPED results, no short-code exemption or text | removed from the engine, verifier and report; the guides carry an out-of-date banner until rewritten | — |
| A control field not to be touched is excluded explicitly, not by width | `tiers.flag_pp` and the three `tiers_entite` excluded, with the reason, in the CSVs | S1 "natural-person flag untouched", "tiers_entite discriminator untouched" |
| Capacity checks kept: a replacement that cannot fit stops preflight; never skipped or truncated | `check_inventory` TOO NARROW, by type: a party value is 9 wide, an account value 10 | S14 |

### Section 5B — switches and defaults

| Requirement | Implementation | Proved by |
|---|---|---|
| ID, DESCRIPTION, ATTRIBUTES independent for the five categories, all on — in the working config, the template and the program defaults; validated; recorded per run | both ini files; `configure` defaults `'Y'`; a value that is neither yes nor no is refused (-20014); `anon_run_setting` | S5, S15 |
| Configurations relying on the old master switch warned; resolved settings shown before execution | batch summary table and NOTE; the same table and NOTE from `start_run` | the batch was exercised with a fake sqlplus (not in the suite) |
| A translation is made when any of the three is on | `allocate_maps` | S5 |
| CODE updates only when ID is on | `code_lookup` | S5 |
| DESCRIPTION and SELF_CODE write the translation's new_code, never the row's current code | `merge_owned` writes `owner_key.new_code` | S5 "original code never written as a mask" |
| Owners found by original or by replacement | `owner_key` holds both keys; a collision between them is refused | S5 (labels with ID off), S17 |
| NULL kept per SELF_CODE field; DESCRIPTION may fill a NULL label | `CASE WHEN col IS NOT NULL THEN new_code END`, per column | S1, S5 "empty attribute stays empty"; verifier PART 4 "[empty fields kept]" |
| Addresses under ATTRIBUTES | adresse1-5 are SELF_CODE | S1 |
| NULL_OUT independent: NULL when nullable; a marker cut to width when NOT NULL character; no valid value → blocked | `apply_null_out`, `check_inventory` | S1 marker; S14 NOT NULL number refused |
| Compensateur references: the identity's ordinary translation | PARTY columns, the same lookup | S1 |
| Each disabled protection and its remaining population reported; never an unqualified PASS | verifier PART 6, DISABLED statuses, INCOMPLETE | S5, S7 |
| The 8 combinations for every category, X_ included | S5: each combination for all five categories at once — 40 identity-combination cases, 320 assertions | S5 |
| Capacity, uniqueness, provenance and domain checks for field-only translations too | the same plan and checks | S5 |

### Section 6 — acceptance checks, as the verifier implements them

| Acceptance check | Verifier check (PART) |
|---|---|
| every approved account input has one BANK_ACCOUNT map | "each identity needing a translation has one", "translations are of the identity's own domain" (1) |
| each account target holds its translation; a node with a master has the master's | "account masters carry their translation", "account nodes carry their master's translation" (1); residuals "[account nodes]" (2) |
| STRUCTURE_ONLY nodes checked without a master join | the node check reads the plan's `has_account_node`, never a master join (1) |
| zero cross-domain substitutions, by provenance | per column, replacements of the wrong domain counted from the plan's recorded translations (2) |
| party nodes stay party; parents resolve to their typed identity | residuals "[party nodes]" (2); pere: originals left where a role is established, and translations of the wrong role (`pere_bad`) (2) |
| one E/P/T/X per party; an overlap gives one E_ | "each party has one translation" (1) |
| X_ with its reason, its fields masked | "every unclassified party has its reason" (1); labels and attributes (4) |
| PARTY never BANK_ACCOUNT; disablement never bypassed | (2), and the switch rule of `apply_switches` |
| an existing map extended safely; a second run changes nothing; disabled maps do not leak | S6, S2, S7 |
| unmapped, ambiguous, missing → REVIEW / INCOMPLETE, never a PASS | REVIEW and DISABLED statuses and the verdict rule |
| one-character identifiers in masking, dry run and verification | no length filter anywhere; S1 |
| switches on by default; the 8 combinations | S5 |
| a NULL attribute never filled; addresses under ATTRIBUTES; NULL_OUT independent; unsupported masking blocks | "[empty fields kept]" (4); free text (3) |
| compensateur references match the ordinary translation | (2); S1 |

**One deviation.** A value in an identifier column that is no recorded identity — a currency
code, or a reference to a party that no longer exists — is reported as a WARN, outside the verdict.
Section 2A says not every unknown string is sensitive. A reviewed one is brought into scope by
inserting it into `anon_meta.confirmed_identity` (S16).

### Sections 7 and 7A — the design checks

`tests/regression/design_checks.sql` runs both queries of the specification — verbatim except
that an account node is tested by its screen alone (2.4) — and checks their figures: 3 / 0 / 1
and 16 / 0 / 4 / 3 / 1 / 8 (S0). The engine's own classification is checked separately on real
tables (S1), with the same cases plus the shared text SHRD and the one-character party Z.

### Section 8 — implementation locations

Every file the section names changed as it describes — see section 8 of this document.

### Section 9 — legacy differences A to F

| | Decision | Implementation |
|---|---|---|
| A | a NULL attribute is never filled — per SET expression | `merge_owned` |
| B | addresses stay under ATTRIBUTES; both switches on by default | inventory section 10 |
| C | descriptions and attributes without renaming identifiers | independent switches; `owner_key` |
| D | independent clearing and markers; unsupported masking blocks, never passes | `check_inventory`, verifier PART 3. CHECK constraints are not validated — section 6 |
| E | one translation for compensateur references | PARTY columns |
| F | suffix format and the extra NULL_OUT targets | unchanged: a seven-digit sequence; the NULL_OUT list is untouched and its per-schema review stays open |

---

## 4. Compared with the legacy row-by-row package

The legacy package typed its columns implicitly: a column updated only in the Compte branch only
ever received account replacements, and its structure updates filtered by classification and
screen. The previous v4 replaced that with one untyped lookup, which is where defects A and B came
from. The fix makes the typing explicit — and departs from the legacy package where the legacy
package was itself wrong.

| Topic | Legacy row-by-row (`02pack`) | v4 before the fix | v4 now |
|---|---|---|---|
| How it runs | one cursor per branch (Entite, Portefeuille, Tiers, Compte); per code, one UPDATE per column | one set-based UPDATE per inventory column | the same, from a typed plan |
| Entity | Entite node on w_tiers joined to a tiers row with flag N | the same | flag N and an Entite node on w_tiers, among all the party's nodes |
| Portfolio | Entite node on w_tiers joined to a tiers row with flag O | the same | flag O and a w_tiers node of any classification, NULL included |
| Counterparty | any Compte node on w_tiers — no tiers row needed | the same | flag N, a non-NULL non-Entite w_tiers node, no Entite node — and a tiers row |
| Other parties — no qualifying node, no master, unknown flag | in no cursor: their codes are left as they are | renamed only when the text matched some map, e.g. an account's CB_ (754 tiers rows on EPFPG785) | X_, with the reason |
| Bank accounts | compte_banque | compte_banque | compte_banque ∪ the nodes on w_compte_banque, whatever their classification; structure-only ones need approval |
| Unclassified parties | not processed | not reported | X_, counted by reason and by table; a dry run explains each reason and prints a query per reason to list them |
| A text that is two things | in a column several branches update, the first branch to run wins (E, P, T, then C); a column one branch updates gets that branch's value | one priority E > P > T > CB for every column not declared BANK_ACCOUNT | each object keeps its own translation; each column takes its own domain's |
| A party with Entite and Compte/w_tiers nodes | master and Entite node get E_ from the Entite branch; the Compte/w_tiers node then gets T_ from the Tiers branch — a split | E_ and T_ maps both; ANY picks E_ | one E_ on the master, every node and every reference |
| structure.code | per branch: `where code=:2 and structure=:3 and ecran=:4` | the ANY lookup | by node role; other screens left for review |
| structure.pere | `where pere=:2 and structure=:3` — the Compte branch filters `structure='Compte'` without the screen | the ANY lookup | the parent's typed translation from pre-run roles; ambiguous left for review |
| Replacement | prefix + `abs(mod(dbms_random.random, 9999999))`, not padded | prefix + a seven-digit sequence | the same, appended after the highest existing number, never renumbered |
| Compensateur columns | a second, independent random value (`COLNPENS`) | the identity's ordinary translation | the same |
| Code renaming off (`xC = n`) | descriptions and slot attributes still processed | category off ⇒ its descriptions and attributes off too | three independent switches |
| Descriptions | under `xD`: structure node and master descriptions | DESCRIPTION rows, writing the row's own code column | the identity's translation, also when the code is kept |
| Addresses adresse1-5 | under `xD`, each guarded `IS NOT NULL` | SELF_CODE under ATTRIBUTES; one populated field could fill a NULL sibling | under ATTRIBUTES; NULL kept per field |
| Optional attributes | five column-name slots per category (Ent1-5 …), each guarded `IS NOT NULL` | SELF_CODE per category, needing the category flag | SELF_CODE typed PARTY: every party — decision 5.1 |
| One-character codes | processed like any other | skipped (`MIN_CODE_LENGTH = 2`), width-1 columns skipped | processed; width-1 targets excluded explicitly, or the run stops |
| Free text | cleared inside the code branches, plus the launcher's pre-clear | NULL_OUT, always; NOT NULL character → marker; NOT NULL other → skipped | NULL_OUT, always; marker; NOT NULL other → the run stops |
| compte_banque.code_bban | `set code_bban = :1 where code = :2` runs after `code` was renamed, so it matches nothing | a lookup that never matches | unchanged — known gap |
| Verification | none in the package | every original in every column; PASS / FAIL; checkbox columns and short codes exempt | typed, against the plan; PASS / FAIL / REVIEW / INCOMPLETE |

---

## 5. Decisions that need confirmation

| # | Decision | Why | To reverse it |
|---|---|---|---|
| 5.1 | Every tiers attribute row (contact, names, birth department, grouping, classification, telex) and the tiers description and addresses apply to **every party** — category PARTY | Each row used to cover the one category whose old slot chose it, so an X_ party, whose category is unknown, was covered by none. A rule is per column, so covering X_ covers E, P and T too. Each owner is still gated by its own category's ATTRIBUTES switch | change PARTY back to one category in `inventory_op_custom.csv` — X_ owners then keep that column's real value |
| 5.2 | `tiers.flag_pp` and the three `tiers_entite` columns excluded from the inventory | One-character flags (`O`/`N`, `T`/`E`), VARCHAR2(1) on TANM7881; no replacement can fit; listed, preflight would stop every run. The old checkbox rule skipped them silently | uncomment them — preflight then stops on the width |
| 5.3 | `APPROVE_STRUCTURE_ONLY_ACCOUNTS` is `n` by default, blank in the working config | "Stop for scope review" until the client confirms — section 2.1 | set `y` once confirmed |
| 5.4 | Values whose role cannot be established are left and reported REVIEW, not translated | Section 2.3. Leaving them keeps the client value in place until reviewed; the verdict says so | MIXED columns: retype the column. Screens and parents: needs the setting proposed for the improvement phase |
| 5.5 | An identity whose classification has changed since it was recorded keeps its translation; the run continues; the verdict is REVIEW | "Preserve the existing identity or plan a consistent migration" (2B). Stopping the run would block every import whose master data was corrected | — |
| 5.6 | Earlier translations (from the previous v4 or an earlier import) are reused when they agree with the identity; when a party has two and one matches its category, that one is used and the other counted as superseded; when none matches, the run stops | Reuse keeps replacements stable across imports; a choice between two non-matching ones would silently change values already written | drop `anon_meta` to start without history |
| 5.7 | Unrecognised values in identifier columns are a WARN outside the verdict | Section 6, "one deviation" | confirm them in `anon_meta.confirmed_identity` |
| 5.8 | The EPF view `atrace.ref_tables_modif` lists exactly one row per identity, typed by domain, and only translations applied to identifiers in this data | EPF reads it with scalar subqueries per (table_name, old_value), which fail on a second row; and EPF must not rename what OP kept | — |
| 5.9 | The order of X_ reasons when several apply | Section 3, after the 2A table | — |
| 5.10 | `val_bank_account.code` stays BANK_ACCOUNT although the legacy package wrote party values into it | v3 restricted it to accounts and the table holds bank accounts; the legacy writes come from its val_* block copied into every party branch, and it never wrote account values there | retype it MIXED if the data says so — the verifier fails it then |
| 5.11 | `param_fiche_val_detail.code` and `vue_affilie_compte.code_ref` are BANK_ACCOUNT on the legacy evidence alone | the legacy package writes them only in its Compte branch; v3 left them unrestricted | the same |
| 5.12 | An account node is any node on `w_compte_banque`, whatever its classification | **Confirmed by the business, 2026-10-20** — replaces the specification's `structure = 'Compte' AND ecran = 'w_compte_banque'` (section 2.4) | — |
| 5.13 | The run output and the report show X_ parties as counts and reasons only; a dry run prints one query per reason for the operator to run, rather than listing the codes itself | the specification forbids identifiers in reports, and run logs travel; the queries show the codes only to someone who can already read the data | print the codes in the log — not recommended |
| 5.14 | X_ rows by table count identifier (CODE) columns only, not the labels and attributes of X_ parties | those are masked too, but they are the same rows of tiers and structure; counting them needs another scan per column in a real run | — |

---

## 6. Known gaps and limits

- **CHECK constraints** on the columns that receive the `ANONYMIZED` marker are not validated in
  preflight. A violation fails the run loudly — never silently — but mid-run.
- **BBANs and account numbers** (`compte_banque.code_bban`, `numero_compte` …) are out of scope, as
  the specification says. `code_bban` keeps its never-matching CODE row, documented as such.
- **No reviewed policy yet** for structure nodes on other screens or for ambiguous parents —
  section 2.3.
- **Row discriminators** such as `tiers_entite` are not used to resolve values in MIXED columns.
- **The structure predicates** are disjoint by construction (one value of `ecran` each); there is no
  runtime assertion of it.
- **X_ rows on a view with an INSTEAD OF trigger** are not counted in a real run: such a view takes
  no `RETURNING` clause, so the update runs again without it (the failed attempt changed nothing).
  Triggers are disabled during a run, so this only happens if one could not be disabled.
- **Tested on Oracle 21c XE**, the closest free version to the client's Oracle 19; no syntax newer
  than 19 is used. Not yet run on Oracle 19 itself.
- **EPF** is not ported; only its view changed (5.8).
- `analyze_flag_impact.sql` and `scan_for_leaks.sql` create result tables in `anon_meta` and need
  CREATE ANY TABLE — run them as SYS. Unchanged from before.
- **The guides** in `docs/` carry an out-of-date banner until the new documentation replaces them.

---

## 7. How it is tested

`tests/regression/run_regression.sh` runs the real engine, verifier and inventory — the inventory
built by `run_op_anonymization.bat /inventory` from the shipped CSVs — against a disposable Oracle
XE container, on fictional data in which each identity is named after the case it exercises.
Details and how to run it: `tests/regression/README.md`.

| | Scenario | Expected — and found |
|---|---|---|
| S0 | sections 7 and 7A of the specification, SELECT only | 3 / 0 / 1 and 16 / 0 / 4 / 3 / 1 / 8 |
| S1 | the core fixture: a dry run, then every switch on | the dry run changes and records nothing; PASS; 56 assertions on categories, reasons, translations, the shared text, parents, one-character identifiers, NULLs, X_ contacts, discriminators, markers and the EPF view |
| S2 | the same run again | no translation changed or added; no row rewritten; PASS |
| S3 | structure-only accounts not approved | refused before any update; nothing persisted |
| S4 | roles that cannot be established | left unchanged; four REVIEW items; REVIEW REQUIRED |
| S5 | the eight switch combinations, all five categories at once | 320 assertions; INCOMPLETE unless all on |
| S6 | new inputs on mapped data | appended after the existing numbers; nothing renumbered |
| S7 | raw data re-imported, translations kept, a category switched off | its originals kept; the others reuse their values; the EPF view drops the kept ones |
| S8 | an X_ party whose master data is repaired later | keeps its X_; the change reported; REVIEW REQUIRED |
| S9 | data already anonymized, translations lost | refused |
| S10 | data anonymized by the previous version | refused: a master holds the other domain's replacement |
| S11 | translations of the previous version on raw data | the matching one reused, the other superseded, a changed category reported |
| S12 | two earlier party translations, neither matching | refused |
| S13 | the previous version's metadata schema | migrated in place; run and verification pass |
| S14 | inventory validation and column capacity | ANY, a party category on CODE, a wrong master domain, an oversized value and a NOT NULL number refused; a one-character free-text column processed |
| S15 | a switch that is neither y nor n | refused |
| S16 | a dangling party reference, then confirmed | a warning until confirmed; then X_ MISSING_MASTER, renamed, PASS |
| S17 | resuming after a run that stopped partway | nothing reclassified; the restored originals get the same translations; PASS |
| S18 | account nodes classified other than `Compte`, or not at all (2.4) | bank-account identities: CB_, account parent, labels masked, nothing for review; PASS |
| S19 | X_ parties in a dry run, a real run, and with X_ renaming off (2.5) | counts by reason and where found; reasons; in the dry run the fixes and five queries, each run and checked; X_ rows by table in the output, the step log and the report; no identifier in any output |

Result on commit `20b687f`: 478 passed, 0 failed. With the follow-up (2.4, 2.5): **512 passed, 0 failed.**

Outside the suite:

- the batch file was run with a fake sqlplus to check the 25 parameters it passes, the summary
  table, the NOTE for an old-style configuration, and the exit code for each verdict (0, 2, 3, 4);
- the HTML report was rendered and inspected for a REVIEW verdict;
- `scan_for_leaks.sql`, `analyze_flag_impact.sql`, `generate_coverage_doc.sql`,
  `inspect_code_map.sql` and `typed_identity_diagnostics.sql` were run against the fixture.

---

## 8. Files

| File | Change |
|---|---|
| `op/sql/30_install_engine.sql` | the engine: capture, classification, plan, allocation, validation, typed lookups, owner keys, NODE_ROLE handler, NULL-preserving attributes; checkbox and short-code logic removed. Follow-up: account nodes by screen; `report_unclassified`, X_ rows per column (`apply_lookup`), `print_unclassified_by_table` |
| `op/sql/10_create_metadata_schema.sql` | new tables, migration of an existing schema, `code_map_any` dropped, EPF view redefined — Appendix C. Follow-up: `unclassified_reason`, `anon_step_log.x_rows` |
| `op/sql/21_validate_inventory.sql` | rule and category pairs, fixed master contracts, ANY refused |
| `op/sql/00_run_op_anonymization.sql` | 25 parameters (15 switches, the approval); `MIN_CODE_LENGTH` gone. Follow-up: `SERVEROUTPUT FORMAT WRAPPED` keeps the output's layout |
| `op/run_op_anonymization.bat` | the five categories' independent switches, the approval question, the resolved-settings table and NOTE, verdict exit codes, `/inventory <file>` |
| `op/verify/verify_op_coverage.sql` | rebuilt: plan-based typed checks, four verdicts. Follow-up: account nodes by screen |
| `op/verify/generate_report.sql` | four verdicts, *Needs attention*, *Identities*, *Switches used*; checkbox labels gone. Follow-up: *Unclassified parties (X_)* |
| `config/inventory_op.csv`, `config/inventory_op_custom.csv` | retyped (Appendix A, B); headers rewritten; exclusions recorded |
| `config/anonymization.ini`, `config/anonymization.template.ini` | 15 switches all `y`; the approval; `MIN_CODE_LENGTH` gone |
| `tools/scan_for_leaks.sql`, `analyze_flag_impact.sql`, `generate_coverage_doc.sql` | typed originals, five categories, no width filter, "columns holding the other domain" |
| `tests/manual/inspect_code_map.sql` | typed health checks instead of code_map_any |
| `tests/manual/typed_identity_diagnostics.sql` | **new** — read-only, counts only. Follow-up: account nodes by screen |
| `tests/regression/` | **new** — the suite of section 7. Follow-up: S18, S19; account nodes by screen in `assert_core.sql` and `design_checks.sql` |
| `docs/OP_User_Guide.*`, `docs/OP_Technical_Guide.*` | an out-of-date banner, rebuilt by `tools/build_docs.js` |
| `README.md`, `tests/README.md`, `tools/README.md`, `tools/make_release.ps1` | follow the changes. Follow-up: README on the X_ results |
| `config/*.ini`, `config/inventory_op.csv` headers, `op/run_op_anonymization.bat`, `tools/generate_coverage_doc.sql` | follow-up: account nodes described by their screen |
| `/.gitattributes` | **new** — keeps `.sh` in LF and `.bat` in CRLF |

---

## Appendix A — every identifier column and its evidence

All CODE rows of the inventory before and after the fix, generated from the files themselves:

- **Before** — the category in `inventory_op.csv` at commit `daae970`; *(site)* when
  `inventory_op_custom.csv` overrode it.
- **Legacy branches** — the branches of `02pack_anonym_number.sql` that update the column with the
  code being processed (`update op.X set C = :1 where C = :2`): **E**ntite, **P**ortefeuille,
  **T**iers, **C**ompte. `-` means the legacy package never updates it — a column v4 added.
- **v3** — `COMPTE` when `06_op_setbased_anonym.sql` restricted the column to bank-account
  mappings, `any` when it called `merge_codes` without the restriction, `-` when it did not
  process the column.

### NODE_ROLE — 2 columns

| Column | Before | Legacy branches | v3 | Basis |
|---|---|---|---|---|
| `structure.code` | ANY | EPTC | any | holds party AND account nodes: typed per row by node role |
| `structure.pere` | ANY | EPTC | any | holds party AND account nodes: typed per row by node role |

### PARTY — 364 columns

| Column | Before | Legacy branches | v3 | Basis |
|---|---|---|---|---|
| `budget_filtre.entite` | ANY | EPT | any | legacy party branches only |
| `budget_regle.entite` | ANY | EPT | any | legacy party branches only |
| `charge_contract_criteria.bank` | ANY | - | - | v4 addition naming a party |
| `charge_contract_criteria.entity` | ANY | - | - | v4 addition naming a party |
| `charge_contract_process.bank` | ANY | - | - | v4 addition naming a party |
| `charge_contract_process.entity` | ANY | - | - | v4 addition naming a party |
| `charge_missing_process.bank` | ANY | - | - | v4 addition naming a party |
| `charge_missing_process.entity` | ANY | - | - | v4 addition naming a party |
| `cm_account_of_bkstmt_file.bank` | ANY | - | - | v4 addition naming a party |
| `cm_account_of_bkstmt_file.entity` | ANY | - | - | v4 addition naming a party |
| `cm_archived_forecast.bank` | ANY | - | - | v4 addition naming a party |
| `cm_archived_forecast.entity` | ANY | - | - | v4 addition naming a party |
| `cm_bkstmt_file_config.bank` | ANY | - | - | v4 addition naming a party |
| `cm_bkstmt_file_config.collator` | ANY | - | - | v4 addition naming a party |
| `cm_bsi_bank_statement.entity` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_accounts.bank` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_accounts.entity` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.contrepartie` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_1` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_2` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_3` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_4` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_5` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_receiver1` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_receiver2` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_sender1` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.correspondant_sender2` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.depositaire` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.depositaire_2` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.emetteur` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.entity` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.filiale` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.intermediaire` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.portefeuille` | ANY | - | - | v4 addition naming a party |
| `cm_cash_concent_header.portefeuille_tiers` | ANY | - | - | v4 addition naming a party |
| `cm_cms_exceptions.counterparty` | ANY | - | - | v4 addition naming a party |
| `cm_cms_exceptions.entity` | ANY | - | - | v4 addition naming a party |
| `cm_cms_exceptions.issuer` | ANY | - | - | v4 addition naming a party |
| `cm_cms_exceptions.portfolio` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.compensateur` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.contrepartie` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.corresp_inter_receiver1` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.corresp_inter_receiver2` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.corresp_inter_sender1` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.corresp_inter_sender2` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_1` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_10` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_2` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_3` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_4` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_5` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_6` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_7` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_8` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_9` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_receiver1` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_receiver2` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_sender1` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.correspondant_sender2` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.depositaire` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.depositaire_2` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.depositaire_2_bis` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.depositaire_bis` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.emetteur` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.entity` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.filiale` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.intermediaire` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.portefeuille` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.portefeuille_deposit` | ANY | - | - | v4 addition naming a party |
| `cm_deal_deal.portefeuille_tiers` | ANY | - | - | v4 addition naming a party |
| `cm_fli_flow.counterparty` | ANY | - | - | v4 addition naming a party |
| `cm_fli_flow.entity` | ANY | - | - | v4 addition naming a party |
| `cm_fli_flow.portfolio` | ANY | - | - | v4 addition naming a party |
| `cm_flow_to_pay_rules.bank` | ANY | - | - | v4 addition naming a party |
| `cm_flow_to_pay_rules.entity` | ANY | - | - | v4 addition naming a party |
| `cm_foi_forecast.bank` | ANY | - | - | v4 addition naming a party |
| `cm_foi_forecast.entity` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.bank` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.branch` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.corresp_receiver1` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.corresp_receiver2` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.corresp_sender1` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.corresp_sender2` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.entity` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.portfolio` | ANY | - | - | v4 addition naming a party |
| `cm_forecast.subsidiary_cpty` | ANY | - | - | v4 addition naming a party |
| `cm_payt_payment.corresp_receiver1` | ANY | - | - | v4 addition naming a party |
| `cm_payt_payment.corresp_receiver2` | ANY | - | - | v4 addition naming a party |
| `cm_payt_payment.corresp_sender1` | ANY | - | - | v4 addition naming a party |
| `cm_payt_payment.corresp_sender2` | ANY | - | - | v4 addition naming a party |
| `cm_payt_payment.portfolio` | ANY | - | - | v4 addition naming a party |
| `cm_pooling_convention.counterparty` | ANY | - | - | v4 addition naming a party |
| `cm_pooling_convention.entity` | ANY | - | - | v4 addition naming a party |
| `cm_process.entity` | ANY | - | - | v4 addition naming a party |
| `cms_file_bkd.counterparty` | ANY | - | - | v4 addition naming a party |
| `cms_file_bkd.entity` | ANY | - | - | v4 addition naming a party |
| `compte_banque.agence` | ANY | EPT | any | legacy party branches only |
| `compte_banque.banque` | ANY | EPT | any | legacy party branches only |
| `compte_banque.entite` | ANY | EPT | any | legacy party branches only |
| `compte_banque.portefeuille_defaut` | ANY | EPT | any | legacy party branches only |
| `compte_devise.entite` | ANY | EPT | any | legacy party branches only |
| `compte_filiale.entite` | ANY | EPT | any | legacy party branches only |
| `compte_filiale.filiale` | ANY | EPT | any | legacy party branches only |
| `compte_regle.contrepartie` | ANY | EPT | any | legacy party branches only |
| `compte_regle.depositaire` | ANY | EPT | any | legacy party branches only |
| `compte_regle.entite` | ANY | EPT | any | legacy party branches only |
| `compte_regle.portefeuille` | ANY | EPT | any | legacy party branches only |
| `compte_regle_bqe.contrepartie` | ANY | EPT | any | legacy party branches only |
| `compte_regle_bqe.correspondant` | ANY | EPT | any | legacy party branches only |
| `compte_regle_bqe.depositaire` | ANY | EPT | any | legacy party branches only |
| `compte_regle_bqe.entite` | ANY | EPT | any | legacy party branches only |
| `compte_regle_bqe.portefeuille` | ANY | EPT | any | legacy party branches only |
| `compte_regle_liv.contrepartie` | ANY | EPT | any | legacy party branches only |
| `compte_regle_liv.depositaire` | ANY | EPT | any | legacy party branches only |
| `compte_regle_liv.entite` | ANY | EPT | any | legacy party branches only |
| `compte_regle_liv.portefeuille` | ANY | EPT | any | legacy party branches only |
| `compte_titre.depositaire` | ANY | EPT | any | legacy party branches only |
| `compte_titre.entite` | ANY | EPT | any | legacy party branches only |
| `contrat.emetteur` | ANY | EPT | any | legacy party branches only |
| `contrat_cadre.entite` | ANY | EPT | any | legacy party branches only |
| `contrat_cadre.federateur` | ANY | EPT | any | legacy party branches only |
| `contrat_instrument.entite` | ANY | EPT | any | legacy party branches only |
| `contrat_instrument.federateur` | ANY | EPT | any | legacy party branches only |
| `ctpyrating.counterparty` | ANY | EPT | any | legacy party branches only |
| `deposit_fils.portefeuille` | ANY | EPT | any | legacy party branches only |
| `deposit_fils.portefeuille_pere` | ANY | EPT | any | legacy party branches only |
| `deposit_pere.portefeuille` | ANY | EPT | any | legacy party branches only |
| `deposit_pere.portefeuille_depo` | ANY | EPT | any | legacy party branches only |
| `dm_hedge_request.counterparty` | ANY | - | - | v4 addition naming a party |
| `dm_hedge_request.entity` | ANY | - | - | v4 addition naming a party |
| `dm_hedge_request.portfolio` | ANY | - | - | v4 addition naming a party |
| `dm_hr_autovalid_bkd.entity` | ANY | - | - | v4 addition naming a party |
| `dm_hr_ctrp_map.counterparty` | ANY | - | - | v4 addition naming a party |
| `dm_hr_cutoff_bkd.counterparty` | ANY | - | - | v4 addition naming a party |
| `dm_hr_cutoff_bkd.entity` | ANY | - | - | v4 addition naming a party |
| `dm_hr_cutoff_bkd.portfolio` | ANY | - | - | v4 addition naming a party |
| `dm_hr_limit_bkd.entity` | ANY | - | - | v4 addition naming a party |
| `dm_hr_limit_bkd.portfolio` | ANY | - | - | v4 addition naming a party |
| `dm_hr_ptf_bkd.cts_counterparty` | ANY | - | - | v4 addition naming a party |
| `dm_hr_ptf_bkd.issuer` | ANY | - | - | v4 addition naming a party |
| `dm_hr_quotation.bank` | ANY | - | - | v4 addition naming a party |
| `dm_hr_quotation.entity` | ANY | - | - | v4 addition naming a party |
| `echelle.entite_mere` | ANY | EPT | any | legacy party branches only |
| `echelle.portefeuille_mere` | ANY | EPT | any | legacy party branches only |
| `echelle_cond_date.condition` | ANY | EPT | any | legacy party branches only |
| `echelle_condition.code` | ANY | EPT | any | legacy party branches only |
| `echelle_marge.condition` | ANY | EPT | any | legacy party branches only |
| `fifo_solde_depo.compensateur` | ANY | EPT | any | legacy party branches only |
| `fifo_solde_depo.depositaire` | ANY | EPT | any | legacy party branches only |
| `fifo_solde_depo.portefeuille` | ANY | EPT | any | legacy party branches only |
| `frais_gestion.portefeuille` | ANY | EPT | any | legacy party branches only |
| `groupe_detail.portefeuille` | ANY | EPT | any | legacy party branches only |
| `groupe_provision.entite` | ANY | EPT | any | legacy party branches only |
| `histo_budget.entite` | ANY | EPT | any | legacy party branches only |
| `histo_compta.entite` | ANY | EPT | any | legacy party branches only |
| `histo_compta.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_compta.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_compta_solde.entite` | ANY | EPT | any | legacy party branches only |
| `histo_courtage.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_couverture.tiers_deposit` | ANY | EPT | any | legacy party branches only |
| `histo_couverture.tiers_reception` | ANY | EPT | any | legacy party branches only |
| `histo_deposit.depositaire` | ANY | EPT | any | legacy party branches only |
| `histo_deposit.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_detenteur.ancien_detenteur` | ANY | EPT | any | legacy party branches only |
| `histo_detenteur.nouveau_detenteur` | ANY | EPT | any | legacy party branches only |
| `histo_evenement.contrepartie` | ANY | EPT | any | legacy party branches only |
| `histo_evenement.depositaire` | ANY | EPT | any | legacy party branches only |
| `histo_evenement.entite` | ANY | EPT | any | legacy party branches only |
| `histo_evenement.entity_corresp1` | ANY | EPT | any | legacy party branches only |
| `histo_evenement.entity_corresp2` | ANY | EPT | any | legacy party branches only |
| `histo_facture.entite` | ANY | EPT | any | legacy party branches only |
| `histo_facture.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_fifo_solde.compensateur` | ANY | EPT | any | legacy party branches only |
| `histo_fifo_solde.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_fiscalite.entite` | ANY | EPT | any | legacy party branches only |
| `histo_fiscalite.foyer` | ANY | EPT | any | legacy party branches only |
| `histo_flux.entite` | ANY | EPT | any | legacy party branches only |
| `histo_flux.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_flux.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_limite_tr.entite` | ANY | EPT | any | legacy party branches only |
| `histo_limite_tr.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_liv_solde.entite` | ANY | EPT | any | legacy party branches only |
| `histo_livraison.entite` | ANY | EPT | any | legacy party branches only |
| `histo_livraison.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_livraison.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_matiere.entite` | ANY | EPT | any | legacy party branches only |
| `histo_matiere.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_matiere.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_mouv_titre_solde.compensateur` | ANY | EPT | any | legacy party branches only |
| `histo_mouvement.entite` | ANY | EPT | any | legacy party branches only |
| `histo_operation.compensateur` | ANY | EPT | any | legacy party branches only |
| `histo_operation.contrepartie` | ANY | EPT | any | legacy party branches only |
| `histo_operation.corresp_receiver1` | ANY | EPT | any | legacy party branches only |
| `histo_operation.corresp_receiver2` | ANY | EPT | any | legacy party branches only |
| `histo_operation.corresp_sender1` | ANY | EPT | any | legacy party branches only |
| `histo_operation.corresp_sender2` | ANY | EPT | any | legacy party branches only |
| `histo_operation.depositaire` | ANY | EPT | any | legacy party branches only |
| `histo_operation.depositaire_2` | ANY | EPT | any | legacy party branches only |
| `histo_operation.emetteur` | ANY | EPT | any | legacy party branches only |
| `histo_operation.entite` | ANY | EPT | any | legacy party branches only |
| `histo_operation.filiale` | ANY | EPT | any | legacy party branches only |
| `histo_operation.intermediaire` | ANY | EPT | any | legacy party branches only |
| `histo_operation.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_operation.portefeuille_deposit` | ANY | EPT | any | legacy party branches only |
| `histo_operation.portefeuille_tiers` | ANY | EPT | any | legacy party branches only |
| `histo_operation.tiers_domicile` | ANY | EPT | any | legacy party branches only |
| `histo_parapheur.filiale` | ANY | EPT | any | legacy party branches only |
| `histo_parapheur_det.filiale` | ANY | EPT | any | legacy party branches only |
| `histo_position_tr.entite` | ANY | EPT | any | legacy party branches only |
| `histo_pricing_detail.entite` | ANY | EPT | any | legacy party branches only |
| `histo_pricing_detail.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_pricing_detail.portefeuille_tiers` | ANY | EPT | any | legacy party branches only |
| `histo_reg_releve.entite` | ANY | EPT | any | legacy party branches only |
| `histo_reg_solde.entite` | ANY | EPT | any | legacy party branches only |
| `histo_reg_solde.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.corresp_receiver1` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.corresp_receiver2` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.corresp_sender1` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.corresp_sender2` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.entite` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.portefeuille` | ANY | EPT | any | legacy party branches only |
| `histo_reglement.tiers` | ANY | EPT | any | legacy party branches only |
| `histo_titre_solde.compensateur` | ANY | EPT | any | legacy party branches only |
| `histo_titre_solde.portefeuille` | ANY | EPT | any | legacy party branches only |
| `import_evenement.contrepartie` | ANY | EPT | any | legacy party branches only |
| `import_evenement.cpty_corresp1` | ANY | T | any | legacy party branches only |
| `import_evenement.cpty_corresp2` | ANY | T | any | legacy party branches only |
| `import_evenement.entite` | ANY | EPT | any | legacy party branches only |
| `import_evenement.entity_corresp1` | ANY | T | any | legacy party branches only |
| `import_evenement.entity_corresp2` | ANY | T | any | legacy party branches only |
| `import_operation.compensateur` | ANY | EPT | any | legacy party branches only |
| `import_operation.contrepartie` | ANY | EPT | any | legacy party branches only |
| `import_operation.corresp_receiver1` | ANY | EPT | any | legacy party branches only |
| `import_operation.corresp_receiver2` | ANY | EPT | any | legacy party branches only |
| `import_operation.corresp_sender1` | ANY | EPT | any | legacy party branches only |
| `import_operation.corresp_sender2` | ANY | EPT | any | legacy party branches only |
| `import_operation.depositaire` | ANY | EPT | any | legacy party branches only |
| `import_operation.depositaire_2` | ANY | EPT | any | legacy party branches only |
| `import_operation.emetteur` | ANY | EPT | any | legacy party branches only |
| `import_operation.entite` | ANY | EPT | any | legacy party branches only |
| `import_operation.filiale` | ANY | EPT | any | legacy party branches only |
| `import_operation.groupe_1` | ANY | EPT | any | legacy party branches only |
| `import_operation.groupe_2` | ANY | EPT | any | legacy party branches only |
| `import_operation.groupe_3` | ANY | EPT | any | legacy party branches only |
| `import_operation.intermediaire` | ANY | EPT | any | legacy party branches only |
| `import_operation.portefeuille` | ANY | EPT | any | legacy party branches only |
| `import_operation.portefeuille_deposit` | ANY | EPT | any | legacy party branches only |
| `import_operation.portefeuille_tiers` | ANY | EPT | any | legacy party branches only |
| `import_operation.tiers_domicile` | ANY | EPT | any | legacy party branches only |
| `marge_compte_de.contrepartie` | ANY | EPT | any | legacy party branches only |
| `marge_regle.contrepartie` | ANY | EPT | any | legacy party branches only |
| `marge_regle.entite` | ANY | EPT | any | legacy party branches only |
| `mpm_file_bkd.counterparty` | ANY | - | - | v4 addition naming a party |
| `mpm_file_bkd.entity` | ANY | - | - | v4 addition naming a party |
| `param_arrete.entite` | ANY | EPT | any | legacy party branches only |
| `param_bafi_cpt.entite` | ANY | EPT | any | legacy party branches only |
| `param_clonage.por_clone` | ANY | EPT | any | legacy party branches only |
| `param_clonage.por_maitre` | ANY | EPT | any | legacy party branches only |
| `param_cpta_reg_gen.portefeuille` | ANY | EPT | any | legacy party branches only |
| `param_cpta_reg_ven.banque` | ANY | EPT | any | legacy party branches only |
| `param_cpta_reg_ven.entite` | ANY | EPT | any | legacy party branches only |
| `param_cpta_reg_ven.portefeuille` | ANY | EPT | any | legacy party branches only |
| `param_date.contrepartie` | ANY | EPT | any | legacy party branches only |
| `param_date.portefeuille` | ANY | EPT | any | legacy party branches only |
| `param_garanti_taux.assureur` | ANY | EPT | any | legacy party branches only |
| `param_marge_titre.entite` | ANY | EPT | any | legacy party branches only |
| `param_ope_bloc.portefeuille_fils` | ANY | EPT | any | legacy party branches only |
| `param_ope_bloc.portefeuille_pere` | ANY | EPT | any | legacy party branches only |
| `param_parapheur_det.filiale` | ANY | EPT | any | legacy party branches only |
| `param_rappro_stock.depositaire` | ANY | EPT | any | legacy party branches only |
| `param_sign_user.filiale` | ANY | EPT | any | legacy party branches only |
| `photo.entite` | ANY | EPT | any | legacy party branches only |
| `photo_budget.entite` | ANY | EPT | any | legacy party branches only |
| `photo_flux.entite` | ANY | EPT | any | legacy party branches only |
| `prevision_param.entite` | ANY | EPT | any | legacy party branches only |
| `regle_rappro_auto.banque` | ANY | EPT | any | legacy party branches only |
| `regle_rappro_auto.entite` | ANY | EPT | any | legacy party branches only |
| `reglement_decalage.banque` | ANY | EPT | any | legacy party branches only |
| `reglement_flux.entite` | ANY | EPT | any | legacy party branches only |
| `reglement_flux.tiers` | ANY | EPT | any | legacy party branches only |
| `reglement_regle.banque` | ANY | EPT | any | legacy party branches only |
| `spread_breakdown.entity` | ANY | EPT | any | legacy party branches only |
| `spread_breakdown.issuer` | ANY | EPT | any | legacy party branches only |
| `spread_breakdown.portfolio` | ANY | EPT | any | legacy party branches only |
| `stress_results.portefeuille` | ANY | EPT | any | legacy party branches only |
| `tiers.code` | ANY | EPT | any | the party master |
| `tiers.entite_fifo` | ANY | EPT | any | legacy party branches only |
| `tiers.entite_pere` | ANY | EPT | any | legacy party branches only |
| `tiers.tiers_conso` | ANY | EPT | any | legacy party branches only |
| `tiers.tiers_conso2` | ANY | EPT | any | legacy party branches only |
| `tiers.tiers_conso3` | ANY | EPT | any | legacy party branches only |
| `tiers.tiers_federateur` | ANY | EPT | any | legacy party branches only |
| `tiers_compteur.tiers` | ANY | EPT | any | legacy party branches only |
| `tiers_foyer.foyer` | ANY | EPT | any | legacy party branches only |
| `tiers_foyer.foyer_appartenance` | ANY | EPT | any | legacy party branches only |
| `tiers_limite.entite` | ANY | EPT | any | legacy party branches only |
| `tiers_limite.tiers` | ANY | EPT | any | legacy party branches only |
| `titre.bafi_garant` | ANY | EPT | any | legacy party branches only |
| `titre.depositaire` | ANY | EPT | any | legacy party branches only |
| `titre.domiciliataire` | ANY | EPT | any | legacy party branches only |
| `titre.emetteur` | ANY | EPT | any | legacy party branches only |
| `tp_comm_entity_dim.bank` | ANY | - | - | v4 addition naming a party |
| `tp_comm_entity_dim.entity` | ANY | - | - | v4 addition naming a party |
| `tp_contact.entity` | ANY | - | - | v4 addition naming a party |
| `tp_data_profile_bankaccount.counterparty` | ANY | - | - | v4 addition naming a party |
| `tp_data_profile_ctrp.entity` | ANY | - | - | v4 addition naming a party |
| `tp_data_profile_entity.portfolio` | ANY | - | - | v4 addition naming a party |
| `tp_data_profile_ptf.bank` | ANY | - | - | v4 addition naming a party |
| `tp_pos_snapshot.entity` | ANY | - | - | v4 addition naming a party |
| `tp_pos_snapshot_results.entity` | ANY | - | - | v4 addition naming a party |
| `tp_tenant_entity.entity` | ANY | - | - | v4 addition naming a party |
| `tp_users.counterparty` | ANY | - | - | v4 addition naming a party |
| `tp_users.entity` | ANY | - | - | v4 addition naming a party |
| `tp_wv_mailing_rule.counterparty` | ANY | - | - | v4 addition naming a party |
| `tp_wv_mailing_rule.entity` | ANY | - | - | v4 addition naming a party |
| `tp_wv_transition_rule.counterparty` | ANY | - | - | v4 addition naming a party |
| `tp_wv_transition_rule.entity` | ANY | - | - | v4 addition naming a party |
| `trade_repository_breakdown.entity` | ANY | - | - | v4 addition naming a party |
| `val_affilied_code.code_ref` | ANY | EPT | any | legacy party branches only |
| `val_cptyrating.counterparty` | ANY | - | - | v4 addition naming a party |
| `val_currency_account.entity` | ANY | - | - | v4 addition naming a party |
| `val_security_account.contrepartie` | ANY | - | - | v4 addition naming a party |
| `val_security_account.correspondant` | ANY | - | - | v4 addition naming a party |
| `val_security_account.depositaire` | ANY | - | - | v4 addition naming a party |
| `val_security_account.entite` | ANY | - | - | v4 addition naming a party |
| `val_ssi_account.depositaire` | ANY | - | - | v4 addition naming a party |
| `val_ssi_account.portefeuille` | ANY | - | - | v4 addition naming a party |
| `val_ssi_corresp.banque` | ANY | - | - | v4 addition naming a party |
| `val_ssi_corresp.contrepartie` | ANY | - | - | v4 addition naming a party |
| `val_ssi_corresp.correspondant_1` | ANY | - | - | v4 addition naming a party |
| `val_ssi_corresp.correspondant_2` | ANY | - | - | v4 addition naming a party |
| `val_table_security.code` | ANY | EPT | any | legacy party branches only |
| `val_third_party.adresse1` | ANY | EPT | any | legacy party branches only |
| `val_third_party.code` | ANY | EPT | any | legacy party branches only |
| `val_third_party.tiers_conso` | ANY | EPT | any | legacy party branches only |
| `val_third_party_limit.entite` | ANY | - | - | v4 addition naming a party |
| `val_third_party_limit.tiers` | ANY | - | - | v4 addition naming a party |
| `valo_ccy_volat_rule.entity` | ANY | EPT | any | legacy party branches only |
| `valo_ccy_volat_rule.portfolio` | ANY | EPT | any | legacy party branches only |
| `valo_regle.entite` | ANY | EPT | any | legacy party branches only |
| `valo_regle.portefeuille` | ANY | EPT | any | legacy party branches only |
| `ventiler_contrat_cadre.entite` | ANY | EPT | any | legacy party branches only |
| `ventiler_contrat_cadre.tiers` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp.banque` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp.contrepartie` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp.correspondant_1` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp.correspondant_2` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp_bqe.banque` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp_bqe.contrepartie` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp_bqe.correspondant_1` | ANY | EPT | any | legacy party branches only |
| `ventiler_corresp_bqe.correspondant_2` | ANY | EPT | any | legacy party branches only |
| `ventiler_portef.contrepartie` | ANY | EPT | any | legacy party branches only |
| `ventiler_portef.portefeuille` | ANY | EPT | any | legacy party branches only |
| `ventiler_reg_liv.contrepartie` | ANY | EPT | any | legacy party branches only |
| `ventiler_reg_liv.depositaire` | ANY | EPT | any | legacy party branches only |
| `ventiler_reg_liv.portefeuille` | ANY | EPT | any | legacy party branches only |
| `vue_affilie_tiers.code_ref` | ANY | EPT | any | legacy party branches only |
| `zba_payment_breakdown.entity` | ANY | EPT | any | legacy party branches only |
| `zba_payment_breakdown.mirrored_entity` | ANY | EPT | any | legacy party branches only |
| `zba_payment_breakdown.mirrored_portfolio` | ANY | EPT | any | legacy party branches only |
| `zba_payment_breakdown.portfolio` | ANY | EPT | any | legacy party branches only |
| `zba_transfer_breakdown.counterparty` | ANY | EPT | any | legacy party branches only |
| `zba_transfer_breakdown.entity` | ANY | EPT | any | legacy party branches only |
| `zba_transfer_breakdown.portfolio` | ANY | EPT | any | legacy party branches only |

### BANK_ACCOUNT — 83 columns

| Column | Before | Legacy branches | v3 | Basis |
|---|---|---|---|---|
| `charge_contract_criteria.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `charge_contract_process.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `charge_missing_process.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_account_of_bkstmt_file.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_bsi_bank_statement.bank_account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_cash_concent_accounts.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_cash_concent_header.compte_entite` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_cash_concent_header.compte_filiale` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_cash_concent_header.compte_tiers` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_cash_concent_header.master_account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_deal_deal.compte_entite` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_deal_deal.compte_filiale` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_deal_deal.compte_tiers` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_deal_deal.compte_tiers_2` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_fli_flow.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `cm_payt_payment.cpty_account_code` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `compte_banque.code` | BANK_ACCOUNT | C | COMPTE | the account master |
| `compte_banque.code_bban` | BANK_ACCOUNT | - | COMPTE | unchanged - KNOWN GAP: the lookup never matches a BBAN. Legacy tried code_bban = :1 WHERE code = :2 only AFTER renaming code, so it matched nothing either |
| `compte_banque.compte_previs_glob` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `compte_devise.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `compte_filiale.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `compte_regle.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `compte_regle_bqe.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `compte_regle_liv.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `contrat_cadre.compte_echelle` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `decouvert_compte.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `dm_hr_quotation.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `echelle.compte_reglement` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `echelle_compte.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_effet.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_effet.compte_effet` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_fiscalite.compte_fiscal` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_ligne.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_mouv_solde.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_mouvement.compte` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_mouvement.compte_contrepartie` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_operation.compte_entite` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_operation.compte_entite_2` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_operation.compte_filiale` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_operation.compte_tiers` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_operation.compte_tiers_2` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_operation.tiers_iban_compte` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_prevision.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_reg_conso.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_reg_releve.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_reg_solde.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `histo_reglement.compte` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `histo_reglement.cpty_account` | ANY | C | COMPTE | legacy account branch only + v3 restricted to accounts |
| `import_evenement.cpty_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `import_evenement.entity_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `import_operation.compte_entite` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `import_operation.compte_filiale` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `import_operation.compte_tiers` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `import_operation.compte_tiers_2` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `mpm_file_bkd.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `param_cpta_reg_ven.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `param_effet_paye.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `param_effet_recu.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `param_fiche_val_detail.code` | ANY | C | any | legacy account branch only |
| `param_net_reg.compte_comp` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `param_net_reg.compte_pivot` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `prevision_param.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `regle_rappro_auto.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `reglement_decalage.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `reglement_flux.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `reglement_regle.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `tp_comm_entity_dim.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `tp_contact.bank_account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `tp_data_profile_ptf.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `tp_pos_snapshot.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `tp_pos_snapshot_results.account` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `val_bank_account.code` | BANK_ACCOUNT | EPT | COMPTE | unchanged; v3 restricted to accounts (legacy: party branches) |
| `val_currency_account.compte` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `val_ssi_account.compte` | BANK_ACCOUNT | - | - | unchanged; v4 addition naming an account |
| `virement_compte.compte` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `vue_affilie_compte.code_ref` | ANY | C | any | legacy account branch only |
| `zba_breakdown.centralizer_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `zba_payment_breakdown.centralizer_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `zba_payment_breakdown.current_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `zba_payment_breakdown.mirrored_current_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `zba_transfer_breakdown.centralizer_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `zba_transfer_breakdown.counterparty_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |
| `zba_transfer_breakdown.entity_account` | BANK_ACCOUNT | C | COMPTE | unchanged; legacy account branch |

### MIXED — 10 columns

| Column | Before | Legacy branches | v3 | Basis |
|---|---|---|---|---|
| `ccp_breakdown.clearing_member` | ANY | EPTC | any | legacy wrote party AND account values |
| `clearing_member_breakdown.clearing_member` | ANY | EPTC | any | legacy wrote party AND account values |
| `cm_deal_deal.clearing_member` | ANY | - | - | same field as the other clearing_member columns |
| `histo_operation.clearing_member` | ANY | EPTC | any | legacy wrote party AND account values |
| `import_operation.clearing_member` | ANY | EPTC | any | legacy wrote party AND account values |
| `param_cpta_reg_gen.compte_ana` | ANY (site) | C | COMPTE | analytical account: held party codes on TANM7881 (spec: known exception) |
| `ventiler_compte.valeur_1` | ANY | EPTC | any | legacy wrote party AND account values |
| `ventiler_compte.valeur_2` | ANY | EPTC | any | legacy wrote party AND account values |
| `ventiler_compte.valeur_3` | ANY | EPTC | any | legacy wrote party AND account values |
| `ventiler_compte.valeur_4` | ANY | EPTC | any | legacy wrote party AND account values |

### Excluded from the inventory — 3 columns

| Column | Before | Legacy branches | v3 | Basis |
|---|---|---|---|---|
| `val_ssi_account.tiers_entite` | ANY | - | - | one-character discriminator (VARCHAR2(1) on TANM7881): cannot hold an identifier |
| `val_ssi_corresp.tiers_entite` | ANY | - | - | one-character discriminator (VARCHAR2(1) on TANM7881): cannot hold an identifier |
| `ventiler_corresp_bqe.tiers_entite` | ANY | EPT | any | one-character discriminator (VARCHAR2(1) on TANM7881): cannot hold an identifier |

---

## Appendix B — labels, attributes and free text

| Row | Before | After | Why |
|---|---|---|---|
| `structure.description` DESCRIPTION | ANY | NODE_ROLE | a node's label belongs to the identity its role names |
| `tiers.description` DESCRIPTION | ANY | PARTY | every party, X_ included |
| `compte_banque.description` DESCRIPTION | BANK_ACCOUNT | BANK_ACCOUNT | — |
| `tiers.adresse1` … `adresse5` SELF_CODE | ANY | PARTY | every party, X_ included |
| `tiers.telephone`, `fax`, `email_adress`, `nom_pp`, `prenom_pp` SELF_CODE *(site)* | ENTITY | PARTY | decision 5.1 |
| `tiers.groupe_1` … `groupe_3`, `dpt_naissance` SELF_CODE *(site)* | PORTFOLIO | PARTY | decision 5.1 |
| `tiers.sector`, `seniority`, `telex`, `type_interne` SELF_CODE *(site)* | COUNTERPARTY | PARTY | decision 5.1 |
| `tiers.flag_pp` SELF_CODE *(site)* | PORTFOLIO | excluded | decision 5.2 |
| `compte_banque.groupe_1` … `groupe_3` SELF_CODE *(site)* | BANK_ACCOUNT | BANK_ACCOUNT | — |
| `param_cpta_reg_gen.compte_ana` *(site override)* | CODE ANY | retired | the shipped row is now MIXED |
| the 92 NULL_OUT rows | NONE | NONE | unchanged; a NOT NULL non-character column now stops the run instead of being skipped |

---

## Appendix C — metadata objects

Created by `10_create_metadata_schema.sql`, which upgrades an existing `anon_meta` in place and
keeps everything that records an original value.

| Object | | Purpose |
|---|---|---|
| `code_map` | changed | translations per (category, old_code); **+ run_id** (allocating run; NULL for rows of earlier versions), **+ id_applied** (applied to identifiers in this data) |
| `code_map_any` | **dropped** | the untyped lookup at the root of defects A and B; a derived cache, nothing lost |
| `identity_inventory` | new | every identity, recorded once: domain, category, X_ reason, membership, the category of its one translation |
| `confirmed_identity` | new | reviewed sensitive identities that exist only as references — maintained by hand, never from a file |
| `identity_plan` | new | one run's plan: facts, classification today, parent role, translation, status, the three switches. Kept for the current run and the latest completed EXECUTE run |
| `code_lookup` | new | the typed lookups of one run: PARTY, ACCOUNT, MIXED, AMBIGUOUS, PERE, PERE_REVIEW |
| `owner_key` | new | the original and the replacement of each identity, both leading to its translation — how labels and attributes find their owner |
| `anon_run_setting` | new | the three switches of each category, per run |
| `field_baseline` | new | NULL counts of every SELF_CODE column before masking |
| `verify_key` | new | the verifier's scratch: what each original or replacement is |
| `unclassified_reason` | new | the five X_ reasons: label, why, what would classify the party, and a query listing one run's parties with that reason — refreshed every run (section 2.5) |
| `anon_step_log` | changed | **+ x_rows**: of the rows a CODE step changed, or would change, how many got an X_ value |
| `anon_run` | changed | **+ dataset_json**: database, OP creation date, row and identity counts — never an identifier |
| `anon_inventory` | changed | category constraint recreated with PARTY, MIXED, NODE_ROLE, UNCLASSIFIED_PARTY (ANY still loadable so validation can name the rows) |
| `atrace.ref_tables_modif` | redefined | one row per identity, typed, applied translations only — decision 5.8 |

---

## Appendix D — statuses, verdicts, exit and error codes

**Run log** (`anon_step_log.status`): OK · NOOP · SKIPPED · DISABLED · **REVIEW** (rows deliberately
left unchanged) · DRYRUN · ERROR.

**Verification** (`verify_result.status`): PASS · FAIL · **REVIEW** · **DISABLED** · WARN (outside
the verdict) · INFO · SKIP. Verdict: FAIL if any FAIL, else REVIEW if any REVIEW, else INCOMPLETE if
any DISABLED, else PASS.

**Exit codes** of the batch file: 0 PASS · 1 the run failed · 2 FAIL · 3 REVIEW REQUIRED ·
4 INCOMPLETE. The verifier exits 0, 2, 3 or 4 likewise, and 1 when it cannot run at all.

| Error | Raised by | Meaning |
|---|---|---|
| -20011 | preflight | one or more findings make the run unsafe; the list is in the run log with status ERROR |
| -20012 | preflight | an inventory object is missing and `FAIL_ON_MISSING_OBJECT=y` |
| -20013 | plan | a core table or column (tiers, structure, compte_banque) is missing |
| -20014 | configure | a switch is neither yes nor no, or `PARALLEL_DEGREE` is not a number |
| -20015 | apply | a category the engine cannot apply reached it — validation should have stopped it |
| -20016 | capture | an identifier is longer than the 80 characters anon_meta records |
| -20017 | apply | a NOT NULL non-character NULL_OUT column reached the apply phase |
| -20020 / -20021 | `21_validate_inventory.sql` | the inventory is empty / pairs a rule with a category that cannot apply |
| -20023 | `10_create_metadata_schema.sql` | the inventory table is held by another session |
| -20030 | verifier | no completed run with a plan to verify |
| -20070 | report | nothing verified yet |
