#!/usr/bin/env bash
# ============================================================================
# OP Anonymization - regression suite
# ============================================================================
# Runs the engine, the verifier and the assertions against a DISPOSABLE Oracle
# database in a local container, on fictional data. See README.md.
#
#   export ANON_TEST_SYS_PASSWORD=<the container's SYS password>
#   tests/regression/run_regression.sh            every scenario
#   tests/regression/run_regression.sh S1 S5      some of them
#
# Settings (environment):
#   ANON_TEST_CONTAINER     container name                     anonv4-xe
#   ANON_TEST_SERVICE       service inside the container       localhost:1521/XEPDB1
#   ANON_TEST_SYS_PASSWORD  SYS password                       (required)
#
# Exit code: 0 when every check passed, 1 otherwise.
# ============================================================================

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V4="$(cd "$HERE/../.." && pwd)"
CT="${ANON_TEST_CONTAINER:-anonv4-xe}"
SVC="${ANON_TEST_SERVICE:-localhost:1521/XEPDB1}"
SYSPWD="${ANON_TEST_SYS_PASSWORD:?set ANON_TEST_SYS_PASSWORD to the container SYS password}"
SYSCONN="sys/${SYSPWD}@${SVC} as sysdba"
WORK="$(mktemp -d)"
INV="$WORK/inventory.sql"
ONLY=("$@")

export MSYS_NO_PATHCONV=1          # keep Git Bash from rewriting container paths

PASSED=0
FAILED=0

say()     { printf '%s\n' "$*"; }
section() { say ""; say "=== $* ==="; }
ok()      { PASSED=$((PASSED + 1)); say "PASS  $*"; }
ko()      { FAILED=$((FAILED + 1)); say "FAIL  $*"; }
check()   { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1   got [$2] expected [$3]"; fi; }
wanted()  { [ ${#ONLY[@]} -eq 0 ] && return 0; local s; for s in "${ONLY[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }

# --- SQL*Plus in the container ------------------------------------------------
sync_tree() {
  docker exec "$CT" bash -c 'rm -rf /tmp/v4 && mkdir -p /tmp/v4' >/dev/null
  (cd "$V4" && tar cf - op config tests) | docker exec -i "$CT" bash -c 'cd /tmp/v4 && tar xf -'
}
sysfile() { docker exec -w /tmp/v4 "$CT" sqlplus -L -S "$SYSCONN" "$@"; }
# Setup SQL. Each statement on its own line: SQL*Plus ends a statement only at
# a ';' that ENDS a line. A failure is shown and counted, never swallowed.
sysrun()  { local out
            out=$(printf 'SET FEEDBACK OFF\nWHENEVER SQLERROR EXIT FAILURE\n%s\nEXIT\n' "$1" \
                    | docker exec -i -w /tmp/v4 "$CT" sqlplus -L -S "$SYSCONN" 2>&1) \
              || ko "setup SQL failed: $(printf '%s' "$out" | grep -m1 -E 'ORA-|SP2-')"; }
val()     { printf 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF LINESIZE 400\n%s;\nEXIT\n' "$1" \
              | docker exec -i -w /tmp/v4 "$CT" sqlplus -L -S "$SYSCONN" | tr -d '[:space:]'; }
# docker is a Windows program: hand it a Windows path, not a Git Bash one.
put_inventory() { docker cp "$(cygpath -w "$1")" "$CT:/tmp/v4/inv.sql" >/dev/null; }

# run MODE "ID x5" "DESC x5" "ATTR x5" APPROVE - switch order ENT PTF CPTY UNCL ACCT.
# Output goes to $WORK/last.log; the exit code is the orchestrator's.
RC=0
run() {
  local mode=$1 i d a
  read -r -a i <<< "$2"; read -r -a d <<< "$3"; read -r -a a <<< "$4"
  docker exec -w /tmp/v4/op "$CT" bash -c "mkdir -p logs && sqlplus -L /nolog @sql/00_run_op_anonymization.sql \
     '$SVC' '$SYSPWD' op USERS USERS $mode ${i[*]} ${d[*]} ${a[*]} 1 n $5 /tmp/v4/inv.sql" > "$WORK/last.log" 2>&1
  RC=$?
}
run_all_on() { run EXECUTE "y y y y y" "y y y y y" "y y y y y" y; }
verify()     { docker exec -w /tmp/v4/op "$CT" sqlplus -L -S "op/op@$SVC" @verify/verify_op_coverage.sql \
                 > "$WORK/verify.log" 2>&1
               RC=$?; }
# Counts the PASS/FAIL lines an assertion script prints. Read through a process
# substitution, not a pipe, so the counters are updated in THIS shell.
asserts()    { local line
               while IFS= read -r line; do
                  case "$line" in PASS*) PASSED=$((PASSED + 1)) ;; FAIL*) FAILED=$((FAILED + 1)) ;; esac
                  say "$line"
               done < <(sysfile "$@" | grep -E '^(PASS|FAIL)'); }
fresh()      { sysfile @tests/regression/fixture_schema.sql >/dev/null && sysfile @tests/regression/fixture_data.sql >/dev/null; }
# Raw data again, the metadata kept: what a re-import of the same client does.
reload_raw() {
  sysrun "BEGIN
            FOR t IN (SELECT table_name FROM dba_tables WHERE owner = 'OP' AND table_name <> 'ANON_FIXTURE_MARKER') LOOP
               EXECUTE IMMEDIATE 'DELETE FROM op.' || t.table_name;
            END LOOP;
            COMMIT;
          END;
          /"
  sysfile @tests/regression/fixture_data.sql >/dev/null
}

# --- Setup --------------------------------------------------------------------
section "setup"
docker exec "$CT" true 2>/dev/null || { say "container $CT is not running - see README.md"; exit 1; }
powershell.exe -NoProfile -Command "& '$(cygpath -w "$V4/op/run_op_anonymization.bat")' /inventory '$(cygpath -w "$INV")'" >/dev/null \
  || { say "could not build the inventory with run_op_anonymization.bat /inventory"; exit 1; }
check "the batch file builds the inventory from the shipped CSVs" "$(grep -c '^INSERT INTO anon_meta.anon_inventory' "$INV")" "576"
sync_tree
put_inventory "$INV"

# --- S0 ---------------------------------------------------------------------------
if wanted S0; then
  section "S0 design checks - sections 7 and 7A (SELECT only)"
  asserts @tests/regression/design_checks.sql
fi

# --- S1 ---------------------------------------------------------------------------
if wanted S1; then
  section "S1 core fixture: dry run, then every switch on"
  fresh
  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y; check "dry run completes" "$RC" "0"
  check "dry run changed nothing" "$(val "SELECT COUNT(*) FROM op.tiers WHERE code = 'ENTN'")" "1"
  check "dry run persisted no mapping and froze no classification" \
        "$(val "SELECT (SELECT COUNT(*) FROM anon_meta.code_map) + (SELECT COUNT(*) FROM anon_meta.identity_inventory) FROM dual")" "0"
  check "dry run estimated against its plan (tiers.code: 15 rows)" \
        "$(grep -c 'tiers.code[[:space:]]*DRYRUN[[:space:]]*15 rows would change' "$WORK/last.log")" "1"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  verify;     check "verification: PASS" "$RC" "0"
  asserts @tests/regression/assert_core.sql
fi

# --- S2 ---------------------------------------------------------------------------
if wanted S2; then
  section "S2 second run on the same data changes nothing"
  wanted S1 || { fresh; run_all_on; }
  sysrun "CREATE TABLE anon_meta.s2_before AS SELECT category, old_code, new_code FROM anon_meta.code_map;"
  run_all_on; check "second EXECUTE completes" "$RC" "0"
  check "no translation changed or was added" \
        "$(val "SELECT COUNT(*) FROM (SELECT category, old_code, new_code FROM anon_meta.code_map
                MINUS SELECT * FROM anon_meta.s2_before) ")" "0"
  check "no data row rewritten" \
        "$(val "SELECT NVL(SUM(rows_affected), 0) FROM anon_meta.anon_step_log WHERE run_id = (SELECT MAX(run_id)
                FROM anon_meta.anon_run) AND phase IN ('CODE', 'NULL_OUT', 'DESCRIPTION', 'SELF_CODE')")" "0"
  check "every identity found already recorded" "$(grep -c 'found this run [.]* 0[[:space:]]*already recorded 25' "$WORK/last.log")" "1"
  verify; check "verification: PASS" "$RC" "0"
  sysrun "DROP TABLE anon_meta.s2_before PURGE;"
fi

# --- S3 ---------------------------------------------------------------------------
if wanted S3; then
  section "S3 structure-only account nodes need approval"
  fresh
  run DRYRUN "y y y y y" "y y y y y" "y y y y y" n; check "dry run refuses: scope review" "$RC" "1"
  run EXECUTE "y y y y y" "y y y y y" "y y y y y" n; check "EXECUTE refuses before any update" "$RC" "1"
  check "the refusal names the scope decision" "$(grep -c 'APPROVE_STRUCTURE_ONLY_ACCOUNTS=y' "$WORK/last.log")" "1"
  check "nothing renamed, nothing persisted" \
        "$(val "SELECT (SELECT COUNT(*) FROM op.tiers WHERE code = 'ENTN') || '/' || (SELECT COUNT(*) FROM anon_meta.code_map)
                || '/' || (SELECT COUNT(*) FROM anon_meta.identity_inventory) FROM dual")" "1/0/0"
  # Left unset, they are allowed: the default is y.
  sysrun "BEGIN op.anon_engine.configure(p_mode => 'DRYRUN'); op.anon_engine.start_run; op.anon_engine.finish_run('COMPLETED'); END;
          /"
  check "left unset, structure-only accounts are allowed (default y)" \
        "$(val "SELECT CASE WHEN INSTR(config_json, 'approve_structure_only_accounts\":\"Y') > 0 THEN 'Y' ELSE 'N' END
                FROM anon_meta.anon_run WHERE run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)")" "Y"
fi

# --- S4 ---------------------------------------------------------------------------
if wanted S4; then
  section "S4 values whose domain cannot be established are left for review"
  fresh; sysfile @tests/regression/fixture_review.sql >/dev/null
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "two review items logged: the two MIXED columns" \
        "$(val "SELECT LISTAGG(object_name, ',') WITHIN GROUP (ORDER BY object_name) FROM anon_meta.anon_step_log
                WHERE status = 'REVIEW' AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)")" \
        "histo_operation.clearing_member[partyANDaccount],ventiler_compte.valeur_1[partyANDaccount]"
  verify; check "verification: REVIEW REQUIRED" "$RC" "3"
  check "party-and-account text unchanged in MIXED columns" \
        "$(val "SELECT (SELECT COUNT(*) FROM op.ventiler_compte WHERE valeur_1 = 'SHRD') + (SELECT COUNT(*) FROM op.histo_operation WHERE clearing_member = 'SHRD') FROM dual")" "2"
  # Part 2, items 4 and 5: no longer for review.
  check "nodes on another screen keep their code, and are not left for review" \
        "$(val "SELECT COUNT(*) FROM op.structure WHERE ecran = 'w_autre' AND code IN ('OSCN', 'EOSC')")" "2"
  check "a parent that is a party node AND an account node: the one in the child's own tree" \
        "$(val "SELECT COUNT(*) FROM op.structure s JOIN anon_meta.code_map c ON c.new_code = s.pere
                WHERE s.structure = 'Compte' AND c.category = 'BANK_ACCOUNT' AND c.old_code = 'SHRD'
                AND s.code = (SELECT new_code FROM anon_meta.code_map WHERE old_code = 'AMBC')")" "1"
  check "a party seen only on another screen is X_ NO_PARTY_SCREEN" \
        "$(val "SELECT category || '/' || x_reason FROM anon_meta.identity_inventory WHERE domain = 'PARTY' AND old_code = 'OSCN'")" \
        "UNCLASSIFIED_PARTY/NO_PARTY_SCREEN"
fi

# --- S5 ---------------------------------------------------------------------------
if wanted S5; then
  section "S5 the eight switch combinations, every category"
  for combo in "n n n" "n n y" "n y n" "n y y" "y n n" "y n y" "y y n" "y y y"; do
    read -r i d a <<< "$combo"
    fresh
    run EXECUTE "$i $i $i $i $i" "$d $d $d $d $d" "$a $a $a $a $a" y; check "[$i/$d/$a] EXECUTE completes" "$RC" "0"
    verify; check "[$i/$d/$a] verification: $([ "$combo" = 'y y y' ] && echo PASS || echo INCOMPLETE)" "$RC" \
                  "$([ "$combo" = 'y y y' ] && echo 0 || echo 4)"
    asserts @tests/regression/assert_switches.sql "$i" "$d" "$a"
  done
fi

# --- S6 ---------------------------------------------------------------------------
if wanted S6; then
  section "S6 new inputs extend an existing map; nothing is renumbered"
  fresh; run_all_on
  sysrun "CREATE TABLE anon_meta.s6_before AS SELECT category, old_code, new_code FROM anon_meta.code_map;
          INSERT INTO op.compte_banque (code, description) VALUES ('NEWACC', 'New account');
          INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('NEWPTY', 'N', 'New party');
          INSERT INTO op.structure (code, structure, ecran) VALUES ('NEWPTY', 'Compte', 'w_tiers');
          INSERT INTO op.compte_regle (id, entite, compte) VALUES (9, 'NEWPTY', 'NEWACC');
          COMMIT;"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "existing translations unchanged" \
        "$(val "SELECT COUNT(*) FROM anon_meta.s6_before b WHERE NOT EXISTS (SELECT 1 FROM anon_meta.code_map c
                WHERE c.category = b.category AND c.old_code = b.old_code AND c.new_code = b.new_code)")" "0"
  check "new account appended after the existing ones" \
        "$(val "SELECT new_code FROM anon_meta.code_map WHERE category = 'BANK_ACCOUNT' AND old_code = 'NEWACC'")" "CB_0000008"
  # The counterparties already mapped: CPTC, CPTN and NSTN (archived, item 7).
  check "new party classified and appended" \
        "$(val "SELECT new_code FROM anon_meta.code_map WHERE old_code = 'NEWPTY'")" "T_0000004"
  check "its reference renamed" "$(val "SELECT entite || '/' || compte FROM op.compte_regle WHERE id = 9")" "T_0000004/CB_0000008"
  verify; check "verification: PASS" "$RC" "0"
  sysrun "DROP TABLE anon_meta.s6_before PURGE;"
fi

# --- S7 ---------------------------------------------------------------------------
if wanted S7; then
  section "S7 raw data re-imported, maps kept, one category switched off"
  fresh; run_all_on
  sysrun "CREATE TABLE anon_meta.s7_before AS SELECT category, old_code, new_code FROM anon_meta.code_map;"
  reload_raw
  run EXECUTE "n y y y y" "n y y y y" "n y y y y" y; check "EXECUTE completes" "$RC" "0"
  check "entity identifiers kept" "$(val "SELECT COUNT(*) FROM op.tiers WHERE code IN ('ENTN', 'EOVL', 'EDUP', 'SHRD', 'Z')")" "5"
  check "entity labels kept" "$(val "SELECT description FROM op.tiers WHERE code = 'ENTN'")" "EntityNLtd"
  check "the other categories reuse their earlier translations" \
        "$(val "SELECT COUNT(*) FROM op.tiers t JOIN anon_meta.s7_before b ON b.new_code = t.code AND b.category <> 'ENTITY'")" "10"
  check "entity translations preserved, not used" "$(val "SELECT COUNT(*) FROM anon_meta.code_map WHERE category = 'ENTITY'")" "5"
  check "EPF no longer lists the kept entities" \
        "$(val "SELECT COUNT(*) FROM atrace.ref_tables_modif r JOIN anon_meta.code_map c ON c.new_code = r.new_value AND c.category = 'ENTITY'")" "0"
  verify; check "verification: INCOMPLETE" "$RC" "4"
  sysrun "DROP TABLE anon_meta.s7_before PURGE;"
fi

# --- S8 ---------------------------------------------------------------------------
if wanted S8; then
  section "S8 X_ party whose master data is repaired later keeps its X_"
  # NSTO: flag O and no structure node - X_ (a portfolio needs its w_tiers
  # node). Its node is added later: today it would be a portfolio.
  fresh; run_all_on
  x_before="$(val "SELECT new_code FROM anon_meta.code_map WHERE category = 'UNCLASSIFIED_PARTY' AND old_code = 'NSTO'")"
  reload_raw
  sysrun "INSERT INTO op.structure (code, structure, ecran) VALUES ('NSTO', 'Entite', 'w_tiers');
          COMMIT;"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "recorded category kept" "$(val "SELECT category FROM anon_meta.identity_inventory WHERE domain = 'PARTY' AND old_code = 'NSTO'")" "UNCLASSIFIED_PARTY"
  check "master and new node carry the same X_" \
        "$(val "SELECT (SELECT COUNT(*) FROM op.tiers WHERE code = '$x_before') + (SELECT COUNT(*) FROM op.structure WHERE code = '$x_before') FROM dual")" "2"
  check "no second translation for it" "$(val "SELECT COUNT(*) FROM anon_meta.code_map WHERE old_code = 'NSTO'")" "1"
  check "the drift is reported" "$(grep -c 'would be classified differently today' "$WORK/last.log")" "1"
  verify; check "verification: REVIEW REQUIRED (drift)" "$RC" "3"
fi

# --- S9 ---------------------------------------------------------------------------
if wanted S9; then
  section "S9 data already anonymized, mapping lost"
  fresh
  sysrun "UPDATE op.tiers SET code = 'E_0000001' WHERE code = 'ENTN';
          COMMIT;"
  run_all_on; check "EXECUTE refuses before any update" "$RC" "1"
  check "the refusal says why" "$(grep -c 'already anonymized without' "$WORK/last.log")" "1"
  check "nothing renamed" "$(val "SELECT COUNT(*) FROM op.tiers WHERE code LIKE '%\_0%' ESCAPE '\'")" "1"
fi

# --- S10 --------------------------------------------------------------------------
if wanted S10; then
  section "S10 data anonymized by the previous version - provenance not trusted"
  fresh
  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y      # creates anon_meta
  sysrun "INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('ENTITY', 'ENTN', 'E_0000099');
          INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('BANK_ACCOUNT', 'SHRD', 'CB_0000099');
          UPDATE op.tiers SET code = 'CB_0000099' WHERE code = 'SHRD';
          COMMIT;"
  run_all_on; check "EXECUTE refuses: a party master holds an account replacement" "$RC" "1"
  check "the refusal says why" "$(grep -c 'not their own domain' "$WORK/last.log")" "1"
fi

# --- S11 --------------------------------------------------------------------------
if wanted S11; then
  section "S11 maps left by the previous version, on raw data"
  fresh
  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y
  sysrun "INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('ENTITY', 'CPTC', 'E_0000050');
          INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('COUNTERPARTY', 'CPTC', 'T_0000050');
          INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('COUNTERPARTY', 'NMCP', 'T_0000070');
          COMMIT;"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "two earlier translations: the one matching the category is reused" \
        "$(val "SELECT new_value FROM atrace.ref_tables_modif WHERE table_name = 'tiers' AND old_value = 'CPTC'")" "T_0000050"
  check "the other one is superseded, never used" "$(val "SELECT COUNT(*) FROM op.tiers WHERE code = 'E_0000050'")" "0"
  check "a single earlier translation is kept even if the category changed" \
        "$(val "SELECT COUNT(*) FROM op.structure WHERE code = 'T_0000070'")" "1"
  check "new translations continue after the existing numbers" \
        "$(val "SELECT new_code FROM anon_meta.code_map WHERE category = 'COUNTERPARTY' AND old_code = 'CPTN'")" "T_0000071"
  verify; check "verification: REVIEW REQUIRED (recorded category differs)" "$RC" "3"
fi

# --- S12 --------------------------------------------------------------------------
if wanted S12; then
  section "S12 incompatible earlier party maps stop the run"
  fresh
  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y
  sysrun "INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('ENTITY', 'NMCP', 'E_0000060');
          INSERT INTO anon_meta.code_map (category, old_code, new_code) VALUES ('COUNTERPARTY', 'NMCP', 'T_0000060');
          COMMIT;"
  run_all_on; check "EXECUTE refuses before any update" "$RC" "1"
  check "the refusal says why" "$(grep -c 'none matches their category' "$WORK/last.log")" "1"
fi

# --- S13 --------------------------------------------------------------------------
if wanted S13; then
  section "S13 the previous version's metadata schema is migrated in place"
  fresh; sysfile @tests/regression/legacy_metadata.sql >/dev/null
  run_all_on; check "EXECUTE completes on migrated metadata" "$RC" "0"
  check "code_map gained run_id and id_applied" \
        "$(val "SELECT COUNT(*) FROM dba_tab_columns WHERE owner = 'ANON_META' AND table_name = 'CODE_MAP' AND column_name IN ('RUN_ID', 'ID_APPLIED')")" "2"
  check "the untyped code_map_any is gone" "$(val "SELECT COUNT(*) FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'CODE_MAP_ANY'")" "0"
  check "anon_step_log gained x_rows" \
        "$(val "SELECT COUNT(*) FROM dba_tab_columns WHERE owner = 'ANON_META' AND table_name = 'ANON_STEP_LOG' AND column_name = 'X_ROWS'")" "1"
  check "the inventory accepts the new categories" \
        "$(val "SELECT COUNT(*) FROM anon_meta.anon_inventory WHERE category IN ('PARTY', 'MIXED', 'NODE_ROLE')")" "394"
  check "anon_inventory gained the column options" \
        "$(val "SELECT COUNT(*) FROM dba_tab_columns WHERE owner = 'ANON_META' AND table_name = 'ANON_INVENTORY'
                AND column_name IN ('HARVEST', 'ROW_SCOPE', 'GROUP_BY', 'FOLDER_TREES')")" "4"
  check "the earlier run record is kept" "$(val "SELECT COUNT(*) FROM anon_meta.anon_run WHERE config_json LIKE '%min_code_length%'")" "1"
  verify; check "verification: PASS" "$RC" "0"
fi

# --- S14 --------------------------------------------------------------------------
if wanted S14; then
  section "S14 the inventory is validated, every listed column processed"
  inv_with() { cp "$INV" "$WORK/inv_extra.sql"; sed -i '/^COMMIT;/d;/^SET DEFINE ON/d' "$WORK/inv_extra.sql"
               printf '%s\nCOMMIT;\nSET DEFINE ON\n' "$1" >> "$WORK/inv_extra.sql"; put_inventory "$WORK/inv_extra.sql"; }
  row() { printf "INSERT INTO anon_meta.anon_inventory (table_name,column_name,rule,category,source,notes,seq) VALUES ('%s','%s','%s','%s','CUSTOM',NULL,%s);" "$@"; }

  fresh; inv_with "$(row ANON_FIXTURE_EXTRA ONE_CHAR CODE ANY 9001)"
  run_all_on; check "ANY is refused" "$RC" "1"
  check "  ... with the rows named" "$(grep -c 'ANY is no longer accepted' "$WORK/last.log")" "1"

  fresh; inv_with "$(row ANON_FIXTURE_EXTRA ONE_CHAR CODE ENTITY 9001)"
  run_all_on; check "a single party category on CODE is refused" "$RC" "1"

  # One statement per line: SQL*Plus ends a statement only at a ';' that ends
  # a line - two on one line fail to load, which would look like a refusal.
  fresh; inv_with "DELETE FROM anon_meta.anon_inventory WHERE table_name = 'TIERS' AND column_name = 'CODE';
$(row TIERS CODE CODE BANK_ACCOUNT 9001)"
  run_all_on; check "tiers.code as BANK_ACCOUNT is refused" "$RC" "1"
  check "  ... with the reason" "$(grep -c 'tiers.code is the party master' "$WORK/last.log")" "1"

  fresh; inv_with "$(row ANON_FIXTURE_EXTRA ONE_CHAR CODE PARTY 9001)"
  run_all_on; check "a replacement that cannot fit stops preflight" "$RC" "1"
  check "  ... reported, not skipped" "$(grep -c 'TOO NARROW  anon_fixture_extra.one_char' "$WORK/last.log")" "1"

  fresh; inv_with "$(row ANON_FIXTURE_EXTRA LOCKED_NUM NULL_OUT NONE 9001)"
  run_all_on; check "a NOT NULL number with no masking value stops preflight" "$RC" "1"

  fresh; inv_with "$(row ANON_FIXTURE_EXTRA ONE_CHAR NULL_OUT NONE 9001)"
  run_all_on; check "a one-character free-text column is processed" "$RC" "0"
  check "  ... and emptied, not skipped as a checkbox" "$(val "SELECT NVL(one_char, '<empty>') FROM op.anon_fixture_extra")" "<empty>"
  verify; check "  ... and verified" "$RC" "0"

  # Column options in the notes ([no-harvest], [only-where], [group], [folders]).
  rown() { printf "INSERT INTO anon_meta.anon_inventory (table_name,column_name,rule,category,source,notes,seq) VALUES ('%s','%s','%s','%s','CUSTOM','%s',%s);" "$@"; }
  replace() { printf "DELETE FROM anon_meta.anon_inventory WHERE table_name = '%s' AND column_name = '%s';\n" "$1" "$2"; rown "$@"; }

  fresh; inv_with "$(replace COMPTE_REGLE ENTITE CODE PARTY '[no-harvst] a typo' 9001)"
  run_all_on; check "a misspelt column option is refused" "$RC" "1"
  check "  ... and named" "$(grep -c 'unknown option \[no-harvst\]' "$WORK/last.log")" "1"

  fresh; inv_with "$(replace COMPTE_REGLE ENTITE CODE PARTY '[group: id]' 9001)"
  run_all_on; check "[group: ...] on a column that is not MIXED is refused" "$RC" "1"
  check "  ... with the reason" "$(grep -c '\[group: ...\] is for CODE,MIXED columns' "$WORK/last.log")" "1"

  fresh; inv_with "$(replace COMPTE_REGLE COMPTE CODE BANK_ACCOUNT '[only-where: id in no_such_table.code where type = X]' 9001)"
  run_all_on; check "an [only-where: ...] that cannot be applied stops preflight" "$RC" "1"
  check "  ... reported, nothing changed" \
        "$(grep -c 'NO SCOPE    compte_regle.compte' "$WORK/last.log")/$(val "SELECT COUNT(*) FROM op.tiers WHERE code = 'ENTN'")" "1/1"

  put_inventory "$INV"
fi

# --- S15 --------------------------------------------------------------------------
if wanted S15; then
  section "S15 a switch that is neither y nor n stops the run"
  fresh
  run EXECUTE "y maybe y y y" "y y y y y" "y y y y y" y; check "refused" "$RC" "1"
  check "  ... naming the switch" "$(grep -c 'ANONYMIZE_PORTFOLIO must be y or n' "$WORK/last.log")" "1"
  check "nothing renamed" "$(val "SELECT COUNT(*) FROM op.tiers WHERE code = 'ENTN'")" "1"
fi

# --- S16 --------------------------------------------------------------------------
if wanted S16; then
  section "S16 a dangling reference: captured by itself in a party column, confirmed in a MIXED one"
  fresh
  sysrun "INSERT INTO op.histo_operation (id, entite, contrepartie, clearing_member) VALUES (16, 'ENTN', 'GONE', 'GONEM');
          COMMIT;"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "a party column's code with no master is captured: X_, missing master, reference only" \
        "$(val "SELECT category || '/' || x_reason || '/' || membership FROM anon_meta.identity_inventory WHERE domain = 'PARTY' AND old_code = 'GONE'")" \
        "UNCLASSIFIED_PARTY/MISSING_MASTER/REFERENCE_ONLY"
  check "  ... and its reference renamed" \
        "$(val "SELECT COUNT(*) FROM op.histo_operation h JOIN anon_meta.code_map c ON c.new_code = h.contrepartie AND c.old_code = 'GONE' WHERE h.id = 16")" "1"
  # A MIXED column says nothing of an unknown value's kind: not captured.
  check "in a MIXED column it stays as it is" "$(val "SELECT clearing_member FROM op.histo_operation WHERE id = 16")" "GONEM"
  verify; check "verification: PASS" "$RC" "0"
  check "  ... with a warning: the MIXED value, and the core fixture's EUR" \
        "$(val "SELECT bad_rows FROM anon_meta.verify_result WHERE status = 'WARN' AND check_name LIKE 'values that are no%'")" "2"
  sysrun "INSERT INTO anon_meta.confirmed_identity (domain, old_code, note) VALUES ('PARTY', 'GONEM', 'regression');
          COMMIT;"
  run_all_on; check "confirmed: EXECUTE completes" "$RC" "0"
  check "confirmed: X_, missing master, reference only" \
        "$(val "SELECT category || '/' || x_reason || '/' || membership FROM anon_meta.identity_inventory WHERE domain = 'PARTY' AND old_code = 'GONEM'")" \
        "UNCLASSIFIED_PARTY/MISSING_MASTER/REFERENCE_ONLY"
  check "  ... and renamed in the MIXED column" \
        "$(val "SELECT COUNT(*) FROM op.histo_operation h JOIN anon_meta.code_map c ON c.new_code = h.clearing_member AND c.old_code = 'GONEM' WHERE h.id = 16")" "1"
  verify; check "verification: PASS" "$RC" "0"
fi

# --- S17 --------------------------------------------------------------------------
if wanted S17; then
  section "S17 resume after a run that stopped partway"
  fresh; run_all_on
  # Put some originals back, as if the run had stopped before reaching them:
  # a reference, an account node and a party master.
  sysrun "UPDATE op.histo_operation SET entite = 'ENTN' WHERE id = 1;
          UPDATE op.structure SET code = 'SHRD' WHERE ecran = 'w_compte_banque'
             AND code = (SELECT new_code FROM anon_meta.code_map WHERE category = 'BANK_ACCOUNT' AND old_code = 'SHRD');
          UPDATE op.tiers SET code = 'CPTC' WHERE code = (SELECT new_code FROM anon_meta.code_map WHERE category = 'COUNTERPARTY' AND old_code = 'CPTC');
          COMMIT;"
  run_all_on; check "the resumed run completes" "$RC" "0"
  check "no identity was classified again" "$(grep -c 'found this run [.]* 0[[:space:]]' "$WORK/last.log")" "1"
  check "the restored originals got the same translations" \
        "$(val "SELECT (SELECT COUNT(*) FROM op.histo_operation h JOIN anon_meta.code_map c ON c.new_code = h.entite
                         WHERE h.id = 1 AND c.old_code = 'ENTN' AND c.category = 'ENTITY')
                    + (SELECT COUNT(*) FROM op.structure s JOIN anon_meta.code_map c ON c.new_code = s.code
                         WHERE s.ecran = 'w_compte_banque' AND c.old_code = 'SHRD' AND c.category = 'BANK_ACCOUNT')
                    + (SELECT COUNT(*) FROM op.tiers t JOIN anon_meta.code_map c ON c.new_code = t.code
                         WHERE c.old_code = 'CPTC' AND c.category = 'COUNTERPARTY') FROM dual")" "3"
  verify; check "verification: PASS" "$RC" "0"
fi

# --- S18 --------------------------------------------------------------------------
if wanted S18; then
  section "S18 an account node is any node on w_compte_banque, whatever its classification"
  fresh
  sysrun "INSERT INTO op.compte_banque (code, flag_gere, description) VALUES ('BKNC', 'O', 'Account, node not Compte');
          INSERT INTO op.structure (code, structure, ecran, pere, description) VALUES ('BKNC', 'Banque', 'w_compte_banque', 'ENTN', 'Bank node');
          INSERT INTO op.structure (code, structure, ecran, pere, description) VALUES ('BKNS', NULL, 'w_compte_banque', 'BKNC', 'No class, no master');
          COMMIT;"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "both nodes are bank-account identities, not other-screen nodes" \
        "$(val "SELECT LISTAGG(old_code || '/' || membership, ',') WITHIN GROUP (ORDER BY old_code)
                FROM anon_meta.identity_inventory WHERE domain = 'ACCOUNT' AND old_code IN ('BKNC', 'BKNS')")" \
        "BKNC/BOTH,BKNS/STRUCTURE_ONLY"
  check "the node and its master hold the same CB_" \
        "$(val "SELECT (SELECT COUNT(*) FROM op.structure s JOIN anon_meta.code_map c ON c.new_code = s.code
                         WHERE s.ecran = 'w_compte_banque' AND c.category = 'BANK_ACCOUNT' AND c.old_code = 'BKNC')
                    + (SELECT COUNT(*) FROM op.compte_banque b JOIN anon_meta.code_map c ON c.new_code = b.code
                         WHERE c.category = 'BANK_ACCOUNT' AND c.old_code = 'BKNC') FROM dual")" "2"
  check "the node with no classification and no master got its own CB_" \
        "$(val "SELECT COUNT(*) FROM op.structure s JOIN anon_meta.code_map c ON c.new_code = s.code
                WHERE c.category = 'BANK_ACCOUNT' AND c.old_code = 'BKNS'")" "1"
  check "its parent, an account node, got the account translation" \
        "$(val "SELECT COUNT(*) FROM op.structure s JOIN anon_meta.code_map c ON c.new_code = s.pere
                WHERE c.category = 'BANK_ACCOUNT' AND c.old_code = 'BKNC'")" "1"
  check "their labels masked" "$(val "SELECT COUNT(*) FROM op.structure WHERE description IN ('Bank node', 'No class, no master')")" "0"
  check "nothing left for review" "$(val "SELECT COUNT(*) FROM anon_meta.anon_step_log WHERE status = 'REVIEW'
        AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)")" "0"
  verify; check "verification: PASS" "$RC" "0"
fi

# --- S19 --------------------------------------------------------------------------
if wanted S19; then
  section "S19 unclassified parties are reported by reason and by table"
  fresh; sysfile @tests/regression/fixture_review.sql >/dev/null     # adds a NO_PARTY_SCREEN party
  x_codes='NMEN|NMCP|NSTN|NSTO|NFLG|IFLG|NCLN|OSCN'
  # Missing master: NMEN and NMCP (w_tiers nodes), and X (only in a party column).
  # No structure: NSTO only - NSTN, flag N, is an archived counterparty (item 7).
  by_reason() { grep -cE '^ +(missing master +3 +0 +2 +0 +1|no structure +1 +1 +0 +0 +0|no party screen +1 +1 +0 +1 +0|unknown flag +2 +2 +2 +0 +0|unknown classification +1 +1 +1 +0 +0) *$' "$WORK/last.log"; }
  # The SQL the dry run printed under "-- <reason>", up to its ';'.
  printed_query() { awk -v lbl="$1" '$0 ~ "^ +-- " lbl " *$" {on = 1; next} on {print; if ($0 ~ /; *$/) exit}' "$WORK/last.log" | sed 's/; *$//'; }

  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y; check "dry run completes" "$RC" "0"
  check "dry run: X_ parties counted by reason and where found" "$(by_reason)" "5"
  check "  ... each reason in words" "$(grep -c 'Why they are X_:' "$WORK/last.log")" "1"
  check "  ... what would classify them" "$(grep -c 'Before the real run, fix the data or leave them X_:' "$WORK/last.log")" "1"
  check "  ... and one query per reason" "$(grep -c "p.x_reason = '" "$WORK/last.log")" "5"
  for pair in "missing master:3" "no structure:1" "no party screen:1" "unknown flag:2" "unknown classification:1"; do
    check "  ... the printed '${pair%%:*}' query runs and lists them" \
          "$(val "SELECT COUNT(*) FROM ($(printed_query "${pair%%:*}"))")" "${pair##*:}"
  done
  check "  ... X_ identifiers that would be renamed, by table" \
        "$(grep -cE 'tiers [.]+ 5 rows|structure [.]+ 5 rows|histo_operation [.]+ 2 rows|compte_regle [.]+ 1 row |total [.]+ 13 rows in 4 tables' "$WORK/last.log")" "5"
  check "  ... and no identifier in the run output" "$(grep -cwE "$x_codes" "$WORK/last.log")" "0"

  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "EXECUTE: X_ parties counted by reason, with the reason" \
        "$(( $(by_reason) + $(grep -c 'Why they are X_:' "$WORK/last.log") ))" "6"
  check "  ... no fixes and no queries" \
        "$(( $(grep -c 'Before the real run' "$WORK/last.log") + $(grep -c "p.x_reason = '" "$WORK/last.log") ))" "0"
  check "  ... X_ identifiers renamed by this run, by table" \
        "$(grep -cE 'renamed to X_ by this run, by table|total [.]+ 13 rows in 4 tables' "$WORK/last.log")" "2"
  check "  ... the same counts in the step log" \
        "$(val "SELECT SUM(x_rows) FROM anon_meta.anon_step_log WHERE phase = 'CODE'
                AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)")" "13"
  check "  ... and no identifier in the run output" "$(grep -cwE "$x_codes" "$WORK/last.log")" "0"
  verify; check "verification: REVIEW REQUIRED (the review fixture)" "$RC" "3"
  docker exec -w /tmp/v4/op "$CT" sqlplus -L -S "op/op@$SVC" @verify/generate_report.sql > "$WORK/report.log" 2>&1
  report="$(docker exec -w /tmp/v4/op "$CT" bash -c 'ls -t logs/report_*.html | head -1')"
  rgrep() { docker exec -w /tmp/v4/op "$CT" grep -c "$@" "$report"; }
  check "report: an Unclassified parties section" "$(rgrep 'Unclassified parties (X_)</h2>')" "1"
  check "  ... the reasons in words" "$(rgrep -e 'tell a portfolio from an entity' -e 'not known whether the party is a portfolio')" "2"
  check "  ... the rows renamed, by table" \
        "$(rgrep -e '13 identifier rows renamed to X_' -e '<td class="tbl-name">tiers</td><td class="num">1</td><td class="num">5</td>')" "2"
  check "  ... and no identifier" "$(docker exec -w /tmp/v4/op "$CT" grep -cwE "$x_codes" "$report")" "0"

  fresh
  run EXECUTE "y y y n y" "y y y y y" "y y y y y" y; check "renaming of X_ off: EXECUTE completes" "$RC" "0"
  check "  ... the output says their codes are kept" \
        "$(grep -cE 'ANONYMIZE_UNCLASSIFIED_PARTY=n: their codes are kept|none - ANONYMIZE_UNCLASSIFIED_PARTY=n keeps their codes' "$WORK/last.log")" "2"
fi

# --- S20 --------------------------------------------------------------------------
if wanted S20; then
  section "S20 part 2: codes found only in references, the structure tree by tree, MIXED breakdowns"
  fresh; sysfile @tests/regression/fixture_part2.sql >/dev/null
  laststep() { val "SELECT LISTAGG(status || ':' || rows_affected, ',') WITHIN GROUP (ORDER BY status)
                    FROM anon_meta.anon_step_log WHERE object_name = '$1'
                     AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)"; }

  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y; check "dry run completes" "$RC" "0"
  check "dry run: codes found only in references, by domain" \
        "$(grep -cE 'parties \(X_, missing master\) [.]+ 3 +in 2 columns, 3 rows|bank accounts \(CB_\) [.]+ 2 +in 1 column, 2 rows' "$WORK/last.log")" "2"
  check "  ... and by column" \
        "$(grep -cE 'compte_regle.entite [.]+ party +2 codes +2 rows|compte_regle.compte [.]+ account +2 codes +2 rows|histo_operation.contrepartie [.]+ party +1 code +1 row' "$WORK/last.log")" "3"
  check "dry run: the nodes that keep a client's code by design, counted" \
        "$(grep -cE 'on another screen [.]+ 1$|folder rows of a tree not in \[folders: [.]{3}\] 1$' "$WORK/last.log")" "2"
  # Folders: SHRD and BKONLY in Compta. Children: the BKONLY and ACTIF folders
  # under SHRD in Compta, KIDP under SHRD in Entite, KIDA under SHRD in Compte.
  check "dry run: the folders renamed, and the children that follow their parent" \
        "$(laststep 'structure.code [folders]'),$(laststep 'structure.pere [parent in its tree]')" "DRYRUN:2,DRYRUN:4"
  check "dry run: the values of a MIXED breakdown settled by their group" \
        "$(laststep 'ventiler_compte.valeur_1 [party AND account, by group]')" "DRYRUN:2"
  check "  ... and nothing left for review" \
        "$(val "SELECT COUNT(*) FROM anon_meta.anon_step_log WHERE status = 'REVIEW' AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)")" "0"
  check "  ... and no identifier in the run output" "$(grep -cwE 'GONEP|GONEA|KIDP|KIDA' "$WORK/last.log")" "0"

  run_all_on; check "EXECUTE completes" "$RC" "0"
  verify; check "verification: PASS" "$RC" "0"
  asserts @tests/regression/assert_part2.sql

  run_all_on; check "a second run completes" "$RC" "0"
  check "  ... and rewrites nothing" \
        "$(val "SELECT NVL(SUM(rows_affected), 0) FROM anon_meta.anon_step_log WHERE run_id = (SELECT MAX(run_id)
                FROM anon_meta.anon_run) AND phase IN ('CODE', 'NULL_OUT', 'DESCRIPTION', 'SELF_CODE')")" "0"
  check "  ... and finds no new identity" "$(grep -c 'found this run [.]* 0[[:space:]]' "$WORK/last.log")" "1"
  verify; check "verification: PASS" "$RC" "0"
fi

# --- S21 --------------------------------------------------------------------------
if wanted S21; then
  section "S21 part 2: what is still left for review"
  fresh; sysfile @tests/regression/fixture_part2.sql >/dev/null
  # A breakdown of both kinds, a breakdown of nothing else, and a parent that
  # has no node in its child's tree and is a party AND an account.
  sysrun "INSERT INTO op.ventiler_compte (id, code, valeur_1) VALUES (14, 'CONV_MX', 'CPTC');
          INSERT INTO op.ventiler_compte (id, code, valeur_1) VALUES (15, 'CONV_MX', 'BKONLY');
          INSERT INTO op.ventiler_compte (id, code, valeur_1) VALUES (16, 'CONV_MX', 'SHRD');
          INSERT INTO op.ventiler_compte (id, code, valeur_1) VALUES (17, 'CONV_SH', 'SHRD');
          INSERT INTO op.structure (code, structure, ecran, pere) VALUES ('ORPH', 'Divers', 'w_autre', 'SHRD');
          COMMIT;"
  reviewed() { val "SELECT LISTAGG(object_name || ':' || rows_affected, ',') WITHIN GROUP (ORDER BY object_name)
                    FROM anon_meta.anon_step_log WHERE status = 'REVIEW'
                     AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)"; }
  expected_review='structure.pere[parentnotinitstree,partyANDaccount]:1,ventiler_compte.valeur_1[partyANDaccount]:2'

  run DRYRUN "y y y y y" "y y y y y" "y y y y y" y; check "dry run completes" "$RC" "0"
  check "dry run: two settled by their breakdown, the rest for review" \
        "$(val "SELECT rows_affected FROM anon_meta.anon_step_log WHERE object_name = 'ventiler_compte.valeur_1 [party AND account, by group]'
                AND run_id = (SELECT MAX(run_id) FROM anon_meta.anon_run)")/$(reviewed)" "2/$expected_review"
  run_all_on; check "EXECUTE completes" "$RC" "0"
  check "  ... the same items left for review" "$(reviewed)" "$expected_review"
  check "a breakdown of both kinds, and one of nothing else: left as they are" \
        "$(val "SELECT LISTAGG(id || '=' || valeur_1, ',') WITHIN GROUP (ORDER BY id) FROM op.ventiler_compte WHERE id IN (16, 17)")" \
        "16=SHRD,17=SHRD"
  check "a parent with no node in its child's tree, a party AND an account: left as it is" \
        "$(val "SELECT pere FROM op.structure WHERE code = 'ORPH'")" "SHRD"
  check "the breakdowns of one kind are still settled" \
        "$(val "SELECT COUNT(*) FROM op.ventiler_compte WHERE id IN (11, 13) AND valeur_1 <> 'SHRD'")" "2"
  verify; check "verification: REVIEW REQUIRED" "$RC" "3"
fi

# --- Result ---------------------------------------------------------------------
section "result"
say "passed $PASSED, failed $FAILED"
rm -rf "$WORK"
[ "$FAILED" -eq 0 ]
