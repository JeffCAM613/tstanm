# 16 — Part 2: the six findings of run 1, and archived parties (2026-10-22)

> **For a reviewer.** This traces each item of
> [fixes+needed_in_v4-part2.txt](fixes+needed_in_v4-part2.txt) to the code that implements it and
> the test that proves it, says where the implementation goes beyond the text or chooses between
> two readings of it, and what the next dry run on EPFPG785 should show. Counts only: no client
> name or code appears here.

| | |
|---|---|
| Specification | `fixes+needed_in_v4-part2.txt`, prepared 2026-10-22, from run 1 on refreshed raw EPFPG785; item 7 agreed with a colleague the same day |
| Baseline | run 1: 7 FAIL columns (6,325 rows) and 3 REVIEW checks (735 rows) |
| Code | working tree, not committed yet |
| Tested | 22 scenarios on the disposable Oracle 21c XE, fictional data - section 8 |
| Not yet | run on EPFPG785. It needs the raw data again: run 1 anonymized the copy |

## Contents

1. [In short](#1-in-short)
2. [Item by item](#2-item-by-item)
3. [Column options in the inventory](#3-column-options-in-the-inventory)
4. [What the run prints now](#4-what-the-run-prints-now)
5. [Compared with the legacy row-by-row package](#5-compared-with-the-legacy-row-by-row-package)
6. [Choices made here - please confirm](#6-choices-made-here---please-confirm)
7. [What the next dry run on EPFPG785 should show](#7-what-the-next-dry-run-on-epfpg785-should-show)
8. [How it is tested](#8-how-it-is-tested)
9. [Files](#9-files)

---

## 1. In short

| Item | Run 1 | Now |
|---|---|---|
| 1 `tiers_domicile` (histo_operation, import_operation) | CODE,PARTY: 6,282 rows FAIL, 204,935 rows of bank and branch names left in clear | NULL_OUT,NONE: every populated row emptied, as `tiers_libelle` |
| 2A orphan bank accounts in account columns | 498 codes in 11 columns (2,673 rows) left in clear; 15 of those rows FAIL | each such code is captured as a bank account found only in references and gets its own CB_ |
| 2B `param_fiche_val_detail` | `code`: 4 rows FAIL (cash-flow post codes equal to party codes); `description`: never touched | `code` renamed and checked only on account reports (type FicValComp); `description` emptied |
| 3 orphan parties in party columns | 259 codes in 8 columns (1,998 rows) left in clear; 16 of those rows FAIL | each such code is captured as a party X_, reason missing master, found only in references |
| 4 `structure.pere` | 688 rows REVIEW (47 of them broken links) | every child takes what its parent node in the **same tree** became |
| 5 `structure.code` [other screens] | 39 rows REVIEW | 12 nodes on reference trees keep their code, not flagged; 27 folder rows of the client trees renamed; folder texts emptied |
| 5C NULL_OUT on a NOT NULL column | marker already used when the dictionary said NOT NULL | also when Oracle refuses NULL at run time (ORA-01407); no message either way |
| 6 `ventiler_compte.valeur_1` | 8 rows REVIEW (a code that is a party and an account) | the breakdown (`ventiler_compte.code`) decides: its other values are of one kind |
| 7 archived parties: a tiers row flagged N with no structure node at all | X_, reason no structure (3 on EPFPG785) | COUNTERPARTY, T_, everywhere it appears |

Item 7 goes against one rule of part 1 (specification section 2A, where such a party was X_). The
rest of part 1 and of items 1 to 6 stands.

---

## 2. Item by item

### Item 1 — `tiers_domicile` is free text

`config/inventory_op.csv`: both rows moved from CODE,PARTY to NULL_OUT,NONE, into section 8b next
to `tiers_libelle`, with the reason in a comment. Nothing else is needed: the NULL_OUT phase empties
them in the same statement as the table's other free-text columns, and the verifier checks them as
free text.

Test: S1 - a bank's name, a party code and an account code in `tiers_domicile` are all emptied
(`assert_core.sql`).

### Items 2A and 3 — codes found only in references

**How.** Before the identities are captured, `harvest_references` (`30_install_engine.sql`) reads
every CODE,PARTY and CODE,BANK_ACCOUNT column of the inventory for values that are no identity of
the column's domain, and records them in `anon_meta.reference_harvest` (code, column, rows). The
capture adds them to its identities. A party found only in references has no tiers row, so it
classifies as UNCLASSIFIED_PARTY, reason MISSING_MASTER, membership REFERENCE_ONLY, exactly as the
specification asks; an account is a BANK_ACCOUNT, REFERENCE_ONLY. From there they are ordinary
identities: one translation each, renamed in every column of their domain, recorded in
`identity_inventory` (a later run keeps them), listed in the EPF view.

**Not read** - each one stated in the specification or needed to keep the result right:

| | Why |
|---|---|
| a column marked `[no-harvest]` | it holds other codes too. The five the specification names: `compte_banque.code_bban`, `histo_operation.tiers_iban_compte`, `echelle_condition.code`, `echelle_cond_date.condition`, `echelle_marge.condition` |
| rows outside `[only-where: ...]` | `param_fiche_val_detail.code`: only account reports (item 2B) |
| a blank value (`TRIM` is NULL) | the specification's note on `histo_mouvement.compte_contrepartie` (1,195,066 blank rows) |
| a value longer than the master's own code column | no deleted master can have had it - see 6.3 |
| a value that is already a replacement (in `code_map`) | an earlier run's work: on a second run, nothing is captured again |
| a CHAR column | blank padding would make `'ABC  '` a code of its own - see 6.3 |

**A code of the other domain.** A value of a party column that is an account code (13 rows of
`vue_affilie_tiers.code_ref`) is captured as a party too, and a party code in an account column (14
rows of `histo_operation.compte_tiers`) as an account. That is the specification's choice ("keeps
BANK_ACCOUNT columns 100% pure"). The text is then a party AND an account: each keeps its own
translation, as for the 777 shared texts of run 1.

**The verifier** no longer counts a blank value, or a value of a `[no-harvest]` column, as an
unknown value (the warning "values that are no recorded identifier").

Tests: S1 (a party code with no master in a party column; the IBAN and the condition code not
captured), S16 (a dangling reference captured by itself; in a MIXED column it is not, and
`confirmed_identity` still brings it in), S20 (orphans in both domains, each domain's code in the
other's column, a blank value).

### Item 2B — `param_fiche_val_detail`

`code` keeps CODE,BANK_ACCOUNT, with the option
`[only-where: code_tableau in param_fiche_en_valeur.code where type = FicValComp]`. The renaming,
the harvest and the verifier's check all take only those rows; a cash-flow report's codes are not
touched and not checked. `description` is a new NULL_OUT,NONE row.

Should `param_fiche_en_valeur` be missing on an instance, preflight stops before anything changes
("scope invalid").

Test: S1 - an account report's code renamed; a cash-flow report's codes untouched, one of them
equal to a party code; every label emptied; verification PASS.

### Item 4 — `structure.pere` from the same tree

`resolve_parent_roles` is gone. In its place `anon_meta.node_lookup`, rebuilt every run: for every
node of every tree, keyed by (tree, original code), the code it ends with. `structure.code` is
renamed from it, and so is `structure.pere` - a child gets exactly what its parent node in its own
tree became, or keeps its pere when that node is not renamed. A node an earlier run already renamed
is keyed by its original, so a resumed run still finds it.

**One addition.** A pere with no node in the child's tree: on EPFPG785 there is none (9,907 of
9,907 have their parent in their tree). Should one occur, it takes the translation of the one domain
its text belongs to, and is left for review when it is both a party and an account. Shown on its own
line (`structure.pere [parent not in its tree]`) only when such a link exists.

**The verifier** checks each child against its own tree: a pere that a node of the child's tree
holds is consistent; one that no node of the tree holds must not be an original identifier.

Tests: S4 (a parent that is a party node in one tree and an account node in another: the one of the
child's tree), S18 (a node with no tree), S20 (children of a renamed folder, of a node kept as it is,
the same parent text in two trees; every link still holds after the run), S21 (a parent with no node
in its child's tree, both a party and an account: left for review).

### Item 5 — other screens, folder rows, folder texts

* **5A.** A node on a screen other than `w_tiers` and `w_compte_banque` keeps its code and its
  label, and is no longer reported for review. The verifier counts such nodes whose code is also a
  client identifier as information only.
* **5B and 5C.** `structure.code` carries the option
  `[folders: Entite Compte Tiers Compta Compta_Ato]`. A folder row (no screen) of those trees whose
  code is a party is renamed with the party's translation; one that is only an account, with the
  account's. Its label becomes the same value (under the label switches). Its children follow it
  (item 4).
* **5C, folder texts.** Every other folder row's text, in every tree, is emptied, whatever the
  switches - free text, as NULL_OUT is. `structure.description` is NOT NULL in the application, so
  it gets `ANONYMIZED`.
* **5C, the NULL_OUT rule.** `empty_text` (`30_install_engine.sql`) empties a column where it takes
  NULL and writes the marker, cut to the column's width, where it does not - also when the
  dictionary says nullable but Oracle refuses NULL at run time (ORA-01407: a NOT NULL constraint that
  is not validated). The grouped NULL_OUT statement of a table falls back to it, column by column,
  on ORA-01407. Nothing is reported as a warning: the preflight line "NOT NULL free text ... (overwritten
  with a marker)" is gone from the screen (the step log keeps it), and the verifier already counts
  the marker as empty.

Tests: S20 (folders of a folder tree renamed party first and account second, labels with them;
folder rows of other trees keep their code, their text emptied; a node on another screen
untouched), S4 (other-screen nodes not for review), S1 (free text that refuses NULL at run time
gets the marker, with nothing reported).

### Item 6 — MIXED breakdowns

`ventiler_compte.valeur_1` to `valeur_4` carry `[group: code]`. After the column's single-domain
values are renamed, a value that is a party AND an account takes the kind of its breakdown's other
values - originals or replacements alike, so a second run decides the same way: only accounts, the
account's translation; only parties, the party's. A breakdown of both kinds, or with no other value,
cannot say: those rows are left for review, as before.

The specification also gives name patterns (`'%BQ%'`, `'%CC%'`, ...). They are not used - see 6.4.

Tests: S20 (a breakdown of accounts and one of parties settle it), S21 (a breakdown of both kinds and
one of nothing else: left for review), S4 (a MIXED column with no breakdown: left for review).

### Item 7 — an archived party is a counterparty

A tiers row flagged N with no structure node at all - archived, removed from the tree - is now a
COUNTERPARTY (T_, membership MASTER_ONLY), as the colleague's CASE says. The change is in the
classification inside `capture_identities`, so the tiers row, its label and attributes, and every
reference to it get the same T_ value, and the EPF view lists it as any counterparty.

What stays X_:

| Case | Reason |
|---|---|
| no tiers row (a w_tiers node, or a code found only in references) | missing master |
| a tiers row with no node, flagged O (a portfolio is told by its w_tiers node) or with an empty or unknown flag | no structure |
| a tiers row flagged N whose only nodes are on other screens or folder rows | no party screen |
| an unknown flag, or a NULL classification | unknown flag / unknown classification |

The "no structure" text in `anon_meta.unclassified_reason` now says so.

**An identity already recorded keeps its category.** The engine never changes a translation it
has already made (part 1, section 5). If ANON_META still holds run 1's records, those 3 parties
keep their X_ and the run reports them as classified differently today (REVIEW). To have them as T_
on the refreshed copy, start from an empty ANON_META: as SYS, `DROP USER anon_meta CASCADE;` - the
next run creates it again. On a test copy that is imported raw again, nothing is lost.

Tests: S0 (the policy check: 16 cases, now 2 counterparties and 7 X_), S1 (the archived party is
T_, in its master and its references, its fields masked), S5 (it under every switch combination; an
X_ party - unknown flag - still covered), S6 and S19 (numbers and counts follow), S8 (now an X_
party flagged O, whose node is added later, keeps its X_).

---

## 3. Column options in the inventory

The exceptions of items 2A, 2B, 3, 5 and 6 are written in the inventory itself, in square brackets at
the start of the notes field, so that the CSV stays the one place that says how each column is
treated - and so that a site can change them in `inventory_op_custom.csv`:

| Option | On | Meaning |
|---|---|---|
| `[no-harvest]` | CODE,PARTY or CODE,BANK_ACCOUNT | the column holds other codes too: a value that is no identity is left as it is |
| `[only-where: <col> in <table>.<col> where <col> = <value>]` | CODE | only those rows hold identifiers |
| `[group: <col>]` | CODE,MIXED | rows with the same `<col>` hold one kind of code |
| `[folders: <tree> ...]` | `structure.code` | the trees whose folder rows are named after clients |

`21_validate_inventory.sql` reads them into four new columns of `anon_meta.anon_inventory`
(`harvest`, `row_scope`, `group_by`, `folder_trees`), where the engine and the verifier read them. A
misspelt option, or one on the wrong kind of column, stops the run before anything changes. The
`[only-where]` condition is built only from names and a value limited to letters, digits and `_ $ #
-`, and preflight tries it once before the run.

---

## 4. What the run prints now

Dry run and run, in Preflight:

* **Codes found only in references - their master row was deleted**: parties and bank accounts, each
  with codes, columns and rows; then one line per column. Counts only.
* **Structure nodes that keep a code that is also a client identifier (by design)**: on another
  screen; folder rows of a tree not in `[folders: ...]`.
* The X_ table has a new column, **only in references**. The "missing master" text says that a code
  found only in party columns is a party whose tiers row was deleted, and its listing query shows
  where each was found (`found_in`).

In the apply phase, new lines: `structure.code [folders]`, `structure.pere [parent in its tree]`,
`structure.pere [parent not in its tree]` (only if any), `<column> [party AND account, by group]`,
`structure.description [folder rows]`, and the labels `[party folders]` / `[account folders]`. Gone:
`structure.code [other screens]` and `structure.pere [parent role unresolved]`.

The verifier: `structure.code [folders]` and `[party folders]` / `[account folders]` checks; the
per-tree `structure.pere` check; `structure.description [folder rows]` in PART 3; information lines
for nodes kept by design and for parents not in their tree. The HTML report's X_ table has the
**Only in references** column.

---

## 5. Compared with the legacy row-by-row package

| Item | Legacy (`02pack_anonym_number.sql`) | Now |
|---|---|---|
| 1 | `tiers_domicile` updated as a party code (line 413): party matches renamed, the rest left in clear | emptied |
| 2A, 3 | mappings only from the masters and the screens: codes of deleted masters left in clear | captured and renamed |
| 2B | `code` updated in the account branch (line 2233) for the account rows; `description` untouched | the same for `code`, scoped by report type; `description` emptied |
| 4 | `pere` updated per branch and classification (lines 155, 815, 1474, 2205) | the parent node of the same tree, whatever the classification |
| 5 | other screens and folder rows never touched | other screens the same; folder rows of the client trees renamed; folder texts emptied |
| 6 | the party loop ran first and turned the shared code into a party value, in account breakdowns too (lines 318, 2188) | the breakdown decides: account breakdowns get the account's |
| 7 | cursors join tiers to structure: an archived tiers row is in none, its code stays everywhere | T_ everywhere |

---

## 6. Choices made here - please confirm

1. **Folder trees as a list.** Group 5A is defined by tree and 5B/5C by "ecran IS NULL in Entite,
   Compte, Tiers, Compta, Compta_Ato". Renaming any folder row anywhere would also touch folder rows
   of reference trees, should they have identifier-like codes. So the list is the specification's
   five trees, in `[folders: ...]`; another tree is added there. The dry run counts the folder rows
   of other trees that hold a client code, so a missing tree shows.
2. **Folder texts in every tree.** 5C says "all remaining folder rows where ecran IS NULL", so the
   text of a folder row of a reference tree is emptied too.
3. **What the harvest leaves out** (section 2, items 2A and 3): blank values (specified), values
   longer than the master's code column, replacements already in `code_map`, CHAR columns. The last
   three are additions: none matters on EPFPG785 as described, and each prevents a wrong capture.
4. **MIXED breakdowns by their data, not by name.** The specification gives both ("LIKE '%BQ%' or
   where the group's unambiguous rows are ACCOUNT"). The data rule gives the same result on EPFPG785,
   where every breakdown holds one kind; name patterns would put site-specific text in the product.
5. **A parent with no node in its child's tree** (none on EPFPG785): its text's one domain, or review
   when both (item 4).
6. **Folder rows named after a client** follow the switches like nodes: the code the rename switch,
   the label the label switch. Every other folder text is emptied whatever the switches.

---

## 7. What the next dry run on EPFPG785 should show

On a fresh raw import (run 1 anonymized the current copy, and a run refuses data already
anonymized), with an empty ANON_META (item 7), compared with run 1:

* **Identities**: counterparties up by 3 (the archived parties, item 7), X_ "no structure" down by
  the same 3.

* **Codes found only in references**: about 259 parties in 8 columns (1,998 rows) and about 498 bank
  accounts in 11 columns (2,673 rows). The X_ "missing master" count rises by the parties. If a column
  appears here that should not - one whose values are not codes - mark it `[no-harvest]` in
  `inventory_op_custom.csv` and dry-run again.
* **Structure**: `structure.code [folders]` about 27 rows; the 12 nodes of group 5A counted as kept
  by design - under "on another screen", or under "folder rows of a tree not in [folders: ...]"
  if they have no screen; `structure.pere [parent in its tree]` with the children of every renamed
  node; no `[parent not in its tree]` line.
* **MIXED**: `ventiler_compte.valeur_1 [party AND account, by group]` about 8 rows.
* **No REVIEW line**. One thing to look for: a code captured from references that is also a code of
  the other domain is a party AND an account. In a MIXED column without a breakdown
  (`clearing_member` columns, `param_cpta_reg_gen.compte_ana`), such a value would be left for review.
  Run 1 had none of those; the dry run would show it as `[party AND account]`.
* Then the run, and verification: **PASS** is expected.

---

## 8. How it is tested

`tests/regression/run_regression.sh`, on the disposable container, fictional data:

| | |
|---|---|
| S0 | the classification policy check follows item 7 (`design_checks.sql`) |
| S1 | adds items 1, 2B, 3, 5C and 7 to the core fixture (`fixture_data.sql`, `assert_core.sql`) |
| S5 | the archived counterparty and an X_ party under each switch combination (`assert_switches.sql`) |
| S6, S8 | item 7: one counterparty more before the new one; S8's X_ party is now the one flagged O |
| S4 | reworked: only the MIXED values with no breakdown are left for review; other screens and the ambiguous parent are not |
| S16 | reworked: a dangling reference is captured by itself; in a MIXED column it still needs `confirmed_identity` |
| S19 | the X_ counts include the code found only in a party column, and the new column |
| S20 | new: items 2A, 3, 4, 5 and 6 (`fixture_part2.sql`, `assert_part2.sql`), then a second run that rewrites nothing |
| S21 | new: what is still left for review |
| S2, S13 | counts updated: one identity more in the core fixture; two PARTY rows fewer in the inventory |

Result: see the reply that came with this file.

---

## 9. Files

| File | Change |
|---|---|
| `config/inventory_op.csv` | items 1 and 2B rows; the options on 11 rows; header: the options, codes found only in references, the structure rule, row counts |
| `config/anonymization.template.ini` | the classification table: item 7 |
| `op/sql/10_create_metadata_schema.sql` | `anon_inventory` options columns; `reference_harvest`, `node_lookup`; reason texts (item 7 included); grants |
| `op/sql/21_validate_inventory.sql` | reads and validates the options |
| `op/sql/30_install_engine.sql` | `harvest_references`; capture of codes found only in references; `node_lookup`, `apply_node_set`; `resolve_mixed_groups`; `empty_text` and the NULL_OUT fallback; folder labels and texts; `report_references`; `resolve_parent_roles` removed |
| `op/verify/verify_op_coverage.sql` | folders, per-tree pere, scope, folder texts, unknown values |
| `op/verify/generate_report.sql` | the X_ table's "only in references" column |
| `tools/generate_coverage_doc.sql` | wording of the categories |
| `tests/regression/*` | `fixture_schema.sql`, `fixture_data.sql`, `fixture_review.sql`, `assert_core.sql`, `run_regression.sh`, `README.md`; new `fixture_part2.sql`, `assert_part2.sql` |
| `unofficial docs/14_open_questions.txt` | Q1 to Q3 marked settled |
