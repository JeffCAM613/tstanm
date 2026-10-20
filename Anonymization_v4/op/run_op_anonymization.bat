@echo off
setlocal enabledelayedexpansion

REM ===========================================================================
REM KTP OP Anonymization (v4) - entry point
REM ===========================================================================
REM   run_op_anonymization.bat                    interactive
REM   run_op_anonymization.bat /dryrun            interactive, rehearse only
REM   run_op_anonymization.bat /auto              no prompts, take config as-is
REM   run_op_anonymization.bat /auto /force       no prompts, no confirmation
REM   run_op_anonymization.bat /inventory <file>  write the inventory INSERT
REM                                               file and stop - no database
REM
REM This script does four things and nothing more: settle the configuration,
REM turn the inventory CSVs into loadable SQL, hand over to sqlplus, and return
REM its exit code. All logic lives in sql\.
REM
REM Every path is derived from %~dp0 (the folder holding THIS file), so the
REM package works wherever it is unpacked. In v3 the batch files resolved paths
REM that did not match where they sat, and neither orchestrator could run.
REM
REM Exit codes
REM   0  completed and verified: PASS
REM   1  the run failed - nothing is assumed about how far it got
REM   2  completed, verification FAILED - client data is still present
REM   3  completed, verification REVIEW REQUIRED - values were deliberately
REM      left unchanged because their role or domain is ambiguous
REM   4  completed, verification INCOMPLETE - a protection was switched off
REM ===========================================================================

set "ROOT=%~dp0"
cd /d "%ROOT%"

set "CONFIG_FILE=%ROOT%..\config\anonymization.ini"
set "INVENTORY_BASE=%ROOT%..\config\inventory_op.csv"
set "SQL_DIR=%ROOT%sql"
set "LOG_DIR=%ROOT%logs"
set "INVENTORY_SQL=%TEMP%\anon_inventory_%RANDOM%.sql"

set "RUN_MODE=EXECUTE"
set "INTERACTIVE=1"
set "FORCE=0"
set "INVENTORY_ONLY="

REM /inventory takes the NEXT argument as its value, which the flag loop below
REM cannot read, so it is recognised here - and only as the first argument.
if /I "%~1"=="/inventory" goto :inventory_only

for %%A in (%*) do (
    if /I "%%~A"=="/dryrun" set "RUN_MODE=DRYRUN"
    if /I "%%~A"=="/auto"   set "INTERACTIVE=0"
    if /I "%%~A"=="/force"  set "FORCE=1"
)

cls
echo.
echo ====================================================================
echo  KTP OP Anonymization (v4)
echo ====================================================================
if "!RUN_MODE!"=="DRYRUN" (
    echo  DRY RUN - the database will not be modified.
) else (
    echo  This makes mass irreversible changes. Use a restored copy only.
)
echo ====================================================================
echo.


REM ===========================================================================
REM  STEP 1 - decide where the configuration comes from
REM ===========================================================================
set "USE_CONFIG=0"

if not exist "%CONFIG_FILE%" goto :no_config_file
if "!INTERACTIVE!"=="0" (
    set "USE_CONFIG=1"
    goto :config_decided
)

echo Found: config\anonymization.ini
call :preview_config
echo.
set "_LOAD="
set /p "_LOAD=Load it? Anything missing is still asked for [Y/n]: "
if not defined _LOAD set "_LOAD=y"
echo.
if defined _LOAD if /I "!_LOAD:~0,1!"=="y" set "USE_CONFIG=1"
goto :config_decided

:no_config_file
if "!INTERACTIVE!"=="0" (
    echo ERROR: /auto needs a configuration file, and none was found:
    echo   %CONFIG_FILE%
    goto :failed
)
echo No configuration file found at config\anonymization.ini.
echo Every value will be asked for below.
echo.

:config_decided
if "!USE_CONFIG!"=="1" (
    REM eol=@ skips the @REM comments; tokens=1,* keeps values containing '='.
    for /f "usebackq eol=@ tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
        set "%%A=%%B"
    )
    echo Loaded config\anonymization.ini - only missing values will be asked for.
    echo.
) else (
    if exist "%CONFIG_FILE%" (
        echo Ignoring config\anonymization.ini - asking for every value.
        echo.
    )
    call :clear_all
)


REM ===========================================================================
REM  STEP 2 - connection
REM ===========================================================================
if "!INTERACTIVE!"=="1" (
    echo --------------------------------------------------------------------
    echo  Database connection
    echo --------------------------------------------------------------------
)
call :need ORACLE_SID       "Oracle SID"
if errorlevel 1 goto :failed
call :need SYS_PASSWORD     "SYS password"
if errorlevel 1 goto :failed
call :need OP_PASSWORD      "OP password"
if errorlevel 1 goto :failed
call :need TABLESPACE_DATA  "Tablespace for metadata tables"
if errorlevel 1 goto :failed
call :need TABLESPACE_INDEX "Tablespace for metadata indexes"
if errorlevel 1 goto :failed
if "!INTERACTIVE!"=="1" echo.


REM ===========================================================================
REM  STEP 3 - rename identifiers
REM ===========================================================================
if "!INTERACTIVE!"=="1" (
    echo --------------------------------------------------------------------
    echo  Rename identifiers
    echo --------------------------------------------------------------------
    echo  Every identifier is classified ONCE, from the data, into one of five
    echo  categories. These switches decide whether its code - and every
    echo  reference to it - is replaced. They never move an identifier into
    echo  another category. Descriptions and attributes have their own
    echo  switches below and do not depend on these.
    echo.
    echo  Free text and PII is ALWAYS erased and is not affected by any answer
    echo  below - the NULL_OUT rows of inventory_op.csv.
    echo.
)
REM No '>' or '^' in these prompt strings: inside double quotes cmd treats '^'
REM as a literal character rather than an escape, so it would print verbatim.
call :need_yn ANONYMIZE_ENTITY             "Rename entity codes,             prefix E_"  y
call :need_yn ANONYMIZE_PORTFOLIO          "Rename portfolio codes,          prefix P_"  y
call :need_yn ANONYMIZE_COUNTERPARTY       "Rename counterparty codes,       prefix T_"  y
call :need_yn ANONYMIZE_UNCLASSIFIED_PARTY "Rename unclassified party codes, prefix X_"  y
call :need_yn ANONYMIZE_BANK_ACCOUNT       "Rename bank account codes,       prefix CB_" y
if "!INTERACTIVE!"=="1" echo.


REM ===========================================================================
REM  STEP 4 - description labels
REM ===========================================================================
if "!INTERACTIVE!"=="1" (
    echo --------------------------------------------------------------------
    echo  Description labels          [was EntD / FoldD / TierD / CpteD]
    echo --------------------------------------------------------------------
    echo  Overwrites the label with the identifier's safe replacement, so
    echo  screens stay readable: a counterparty shows as T_0000412 rather than
    echo  blank. Works even when its code is NOT renamed - the label then gets
    echo  the replacement, never the original code.
    echo.
)
call :flag_cols ANONYMIZE_ENTITY_DESCRIPTION             DESCRIPTION ENTITY             "Entity"
call :flag_cols ANONYMIZE_PORTFOLIO_DESCRIPTION          DESCRIPTION PORTFOLIO          "Portfolio"
call :flag_cols ANONYMIZE_COUNTERPARTY_DESCRIPTION       DESCRIPTION COUNTERPARTY       "Counterparty"
call :flag_cols ANONYMIZE_UNCLASSIFIED_PARTY_DESCRIPTION DESCRIPTION UNCLASSIFIED_PARTY "Unclassified party"
call :flag_cols ANONYMIZE_BANK_ACCOUNT_DESCRIPTION       DESCRIPTION BANK_ACCOUNT       "Bank account"


REM ===========================================================================
REM  STEP 5 - sensitive attributes and addresses
REM ===========================================================================
if "!INTERACTIVE!"=="1" (
    echo --------------------------------------------------------------------
    echo  Attributes and addresses    [was Ent1-5 / Fold1-5 / Tier1-5 / Cpte1-5]
    echo --------------------------------------------------------------------
    echo  Overwrites each populated column with the identifier's safe
    echo  replacement. An empty column stays empty. Same privacy effect as
    echo  emptying it, but the column stays populated so NOT NULL and format
    echo  checks still pass.
    echo.
    echo  Columns tagged [site] come from config\inventory_op_custom.csv.
    echo  Comment a line out there to drop one column without disabling the
    echo  whole category.
    echo.
)
call :flag_cols ANONYMIZE_ENTITY_ATTRIBUTES             SELF_CODE ENTITY             "Entity"
call :flag_cols ANONYMIZE_PORTFOLIO_ATTRIBUTES          SELF_CODE PORTFOLIO          "Portfolio"
call :flag_cols ANONYMIZE_COUNTERPARTY_ATTRIBUTES       SELF_CODE COUNTERPARTY       "Counterparty"
call :flag_cols ANONYMIZE_UNCLASSIFIED_PARTY_ATTRIBUTES SELF_CODE UNCLASSIFIED_PARTY "Unclassified party"
call :flag_cols ANONYMIZE_BANK_ACCOUNT_ATTRIBUTES       SELF_CODE BANK_ACCOUNT       "Bank account"


REM ===========================================================================
REM  STEP 6 - scope decision for this client
REM ===========================================================================
if "!INTERACTIVE!"=="1" (
    echo --------------------------------------------------------------------
    echo  Scope decision for this client
    echo --------------------------------------------------------------------
    echo  A bank account is found in compte_banque and as a structure node on
    echo  the w_compte_banque screen. Nodes with no compte_banque row are anonymized
    echo  as bank accounts only once you confirm that they ARE bank accounts for
    echo  this client. If unsure answer n: a run that finds any stops before
    echo  changing anything, and a dry run shows how many there are.
    echo.
)
call :need_yn APPROVE_STRUCTURE_ONLY_ACCOUNTS "Structure-only account nodes are bank accounts here" n
if "!INTERACTIVE!"=="1" echo.


REM ===========================================================================
REM  STEP 7 - run behaviour (all have defaults)
REM ===========================================================================
if "!INTERACTIVE!"=="1" (
    echo --------------------------------------------------------------------
    echo  Run behaviour - press Enter to accept the shown default
    echo --------------------------------------------------------------------
)
call :need_default PARALLEL_DEGREE        "Parallel degree for bulk updates, 1 disables" 4
call :need_default CUSTOM_INVENTORY       "Site-specific inventory file"                 inventory_op_custom.csv
call :need_default FAIL_ON_MISSING_OBJECT "Abort if an inventory object is missing, y/n" n
if "!INTERACTIVE!"=="1" echo.


REM ===========================================================================
REM  STEP 8 - summary: the resolved settings, before anything runs
REM ===========================================================================
echo ====================================================================
echo  Summary
echo ====================================================================
echo  Database ........ !ORACLE_SID!
echo  Tablespaces ..... !TABLESPACE_DATA! (data)  !TABLESPACE_INDEX! (index)
echo.
echo  Category                 Rename IDs   Descriptions   Attributes
echo  Entity (E_)              !ANONYMIZE_ENTITY!            !ANONYMIZE_ENTITY_DESCRIPTION!              !ANONYMIZE_ENTITY_ATTRIBUTES!
echo  Portfolio (P_)           !ANONYMIZE_PORTFOLIO!            !ANONYMIZE_PORTFOLIO_DESCRIPTION!              !ANONYMIZE_PORTFOLIO_ATTRIBUTES!
echo  Counterparty (T_)        !ANONYMIZE_COUNTERPARTY!            !ANONYMIZE_COUNTERPARTY_DESCRIPTION!              !ANONYMIZE_COUNTERPARTY_ATTRIBUTES!
echo  Unclassified party (X_)  !ANONYMIZE_UNCLASSIFIED_PARTY!            !ANONYMIZE_UNCLASSIFIED_PARTY_DESCRIPTION!              !ANONYMIZE_UNCLASSIFIED_PARTY_ATTRIBUTES!
echo  Bank account (CB_)       !ANONYMIZE_BANK_ACCOUNT!            !ANONYMIZE_BANK_ACCOUNT_DESCRIPTION!              !ANONYMIZE_BANK_ACCOUNT_ATTRIBUTES!
echo  Free text (NULL_OUT)     always
echo.
echo  Structure-only accounts approved .. !APPROVE_STRUCTURE_ONLY_ACCOUNTS!
echo  Parallel ........ !PARALLEL_DEGREE!
echo  Custom file ..... !CUSTOM_INVENTORY!
echo  Fail on missing . !FAIL_ON_MISSING_OBJECT!
echo ====================================================================
echo.

REM The switches used to be nested: ANONYMIZE_<CATEGORY>=n also switched off
REM that category's descriptions and attributes, and this script forced them
REM to n. They are now independent, so a configuration written for the old
REM behaviour can mask more than its author expected. Say so before running.
for %%C in (ENTITY PORTFOLIO COUNTERPARTY UNCLASSIFIED_PARTY BANK_ACCOUNT) do (
    set "_w="
    if /I "!ANONYMIZE_%%C!"=="n" if /I "!ANONYMIZE_%%C_DESCRIPTION!"=="y" set "_w=1"
    if /I "!ANONYMIZE_%%C!"=="n" if /I "!ANONYMIZE_%%C_ATTRIBUTES!"=="y" set "_w=1"
    if defined _w (
        echo  NOTE  ANONYMIZE_%%C=n now switches off ONLY the renaming of identifiers.
        echo        Its descriptions and attributes are still masked, because their
        echo        own switches are y. Older versions skipped all three. To leave the
        echo        category untouched, set all three of its switches to n.
        echo.
    )
)

set "INVENTORY_CUSTOM=%ROOT%..\config\!CUSTOM_INVENTORY!"


REM ===========================================================================
REM  STEP 9 - turn the inventory CSVs into INSERT statements
REM
REM  The CSVs are here, on the client, not necessarily on the database server,
REM  so they cannot be read by an external table.
REM ===========================================================================
:build_inventory
if not exist "%INVENTORY_BASE%" (
    echo ERROR: inventory not found:
    echo   %INVENTORY_BASE%
    goto :failed
)

echo Building the inventory...
> "%INVENTORY_SQL%" echo SET DEFINE OFF
>> "%INVENTORY_SQL%" echo SET FEEDBACK OFF

set /a SEQ=0
call :parse_csv "%INVENTORY_BASE%" BASE
if exist "!INVENTORY_CUSTOM!" (
    call :parse_csv "!INVENTORY_CUSTOM!" CUSTOM
) else (
    echo   no site-specific inventory ^(!CUSTOM_INVENTORY!^) - skipping
)

>> "%INVENTORY_SQL%" echo COMMIT;
>> "%INVENTORY_SQL%" echo SET DEFINE ON

echo   !SEQ! inventory items prepared
echo.

if !SEQ! EQU 0 (
    echo ERROR: the inventory produced no items. Every line was a comment,
    echo        or the CSV format is wrong. Nothing to do.
    goto :failed
)

if defined INVENTORY_ONLY (
    echo Inventory written to:
    echo   !INVENTORY_SQL!
    exit /b 0
)


REM ===========================================================================
REM  STEP 10 - confirm and run
REM ===========================================================================
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

if "!RUN_MODE!"=="EXECUTE" if "!FORCE!"=="0" (
    echo This will irreversibly modify schema OP on !ORACLE_SID!.
    set "CONFIRM="
    set /p "CONFIRM=Type YES to proceed: "
    if /I not "!CONFIRM!"=="YES" (
        echo Cancelled - nothing was changed.
        goto :cleanup_ok
    )
    echo.
)

sqlplus -L /nolog @"%SQL_DIR%\00_run_op_anonymization.sql" ^
    "!ORACLE_SID!" "!SYS_PASSWORD!" "!OP_PASSWORD!" ^
    "!TABLESPACE_DATA!" "!TABLESPACE_INDEX!" "!RUN_MODE!" ^
    "!ANONYMIZE_ENTITY!" "!ANONYMIZE_PORTFOLIO!" "!ANONYMIZE_COUNTERPARTY!" ^
    "!ANONYMIZE_UNCLASSIFIED_PARTY!" "!ANONYMIZE_BANK_ACCOUNT!" ^
    "!ANONYMIZE_ENTITY_DESCRIPTION!" "!ANONYMIZE_PORTFOLIO_DESCRIPTION!" ^
    "!ANONYMIZE_COUNTERPARTY_DESCRIPTION!" "!ANONYMIZE_UNCLASSIFIED_PARTY_DESCRIPTION!" ^
    "!ANONYMIZE_BANK_ACCOUNT_DESCRIPTION!" ^
    "!ANONYMIZE_ENTITY_ATTRIBUTES!" "!ANONYMIZE_PORTFOLIO_ATTRIBUTES!" ^
    "!ANONYMIZE_COUNTERPARTY_ATTRIBUTES!" "!ANONYMIZE_UNCLASSIFIED_PARTY_ATTRIBUTES!" ^
    "!ANONYMIZE_BANK_ACCOUNT_ATTRIBUTES!" ^
    "!PARALLEL_DEGREE!" "!FAIL_ON_MISSING_OBJECT!" "!APPROVE_STRUCTURE_ONLY_ACCOUNTS!" ^
    "%INVENTORY_SQL%"

set "RC=!ERRORLEVEL!"
if !RC! EQU 0 (
    del "%INVENTORY_SQL%" 2>nul
) else (
    echo.
    echo The generated inventory file has been KEPT for inspection:
    echo   %INVENTORY_SQL%
)

REM ===========================================================================
REM  Verify and report - only after a real run that succeeded
REM ===========================================================================
REM A dry run changes nothing, so there is nothing to verify.
REM
REM The verifier exits non-zero whenever the result is not a clean PASS, which
REM is exactly when the report is most wanted - so its exit code is captured
REM and the report is generated either way. The verification result is what
REM decides the final exit code, not the report.
set "VRC=0"
if !RC! EQU 0 if "!RUN_MODE!"=="EXECUTE" (
    echo.
    echo Verifying coverage...
    sqlplus -L -S op/"!OP_PASSWORD!"@!ORACLE_SID! @"%ROOT%verify\verify_op_coverage.sql"
    set "VRC=!ERRORLEVEL!"

    echo Building report...
    sqlplus -L -S op/"!OP_PASSWORD!"@!ORACLE_SID! @"%ROOT%verify\generate_report.sql"

    REM A verifier that could not run at all is a failure of the run.
    if !VRC! EQU 1 set "VRC=2"
    if !VRC! NEQ 0 set "RC=!VRC!"
)

echo.
echo ====================================================================
if !RC! EQU 3 goto :verdict_review
if !RC! EQU 4 goto :verdict_incomplete
if !RC! NEQ 0 (
    echo  FAILED - exit code !RC!
    echo.
    echo  Nothing is assumed about how far it got. To see:
    echo    SELECT phase, object_name, status, message
    echo      FROM anon_meta.anon_step_log
    echo     WHERE run_id = ^(SELECT MAX^(run_id^) FROM anon_meta.anon_run^)
    echo       AND status = 'ERROR';
    echo.
    echo  If the RUN succeeded and VERIFICATION failed, the report names every
    echo  exposed column:  logs\report_^<timestamp^>.html
    echo.
    echo  The mapping is intact, so re-running resumes rather than restarts.
    echo  Full output: logs\
    echo ====================================================================
    exit /b !RC!
)

if "!RUN_MODE!"=="DRYRUN" (
    echo  DRY RUN COMPLETE - no changes were made.
    echo  Re-run without /dryrun to execute.
) else (
    echo  COMPLETE - verified: PASS
    echo.
    echo  Report:  logs\report_^<timestamp^>.html      ^(open in a browser^)
)
echo  Full output: logs\
echo ====================================================================
exit /b 0

:verdict_review
echo  COMPLETE - verification: REVIEW REQUIRED
echo.
echo  The run finished, but some client identifiers were deliberately left
echo  unchanged because their role or domain could not be established - a
echo  structure node on another screen, a parent that is both a party and an
echo  account, a value that is both in a MIXED column. They are still in
echo  place. The report lists each one:
echo    logs\report_^<timestamp^>.html
echo ====================================================================
exit /b 3

:verdict_incomplete
echo  COMPLETE - verification: INCOMPLETE
echo.
echo  No exposure was found where protection was switched on, but at least
echo  one protection was switched off, so this is not full anonymization.
echo  The report lists what was left and why:
echo    logs\report_^<timestamp^>.html
echo ====================================================================
exit /b 4


REM ===========================================================================
REM  /inventory <file> - write the inventory INSERT file and stop.
REM
REM  Uses CUSTOM_INVENTORY from the configuration file if it sets one. Touches
REM  no database: it is how the regression suite loads the shipped inventory,
REM  and a quick way to check what a CSV edit produces.
REM ===========================================================================
:inventory_only
if "%~2"=="" (
    echo ERROR: /inventory needs the file to write, for example
    echo   run_op_anonymization.bat /inventory "%%TEMP%%\inventory.sql"
    exit /b 1
)
set "INVENTORY_ONLY=1"
set "INVENTORY_SQL=%~f2"
set "CUSTOM_INVENTORY="
if exist "%CONFIG_FILE%" (
    for /f "usebackq eol=@ tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
        if /I "%%A"=="CUSTOM_INVENTORY" set "CUSTOM_INVENTORY=%%B"
    )
)
if not defined CUSTOM_INVENTORY set "CUSTOM_INVENTORY=inventory_op_custom.csv"
set "INVENTORY_CUSTOM=%ROOT%..\config\!CUSTOM_INVENTORY!"
goto :build_inventory


REM ===========================================================================
REM  Subroutines
REM
REM  Two batch rules govern the patterns below:
REM    - set /p leaves the variable UNCHANGED when the user presses Enter, so
REM      every prompt clears the variable first and applies the default after.
REM    - "if defined NAME" takes a variable NAME, which is how a routine can
REM      test a variable whose name arrived as an argument.
REM ===========================================================================

REM --- Show what the config file would supply, before asking to load it.
:preview_config
set /a _set=0
set /a _blank=0
for /f "usebackq eol=@ tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
    if "%%B"=="" (set /a _blank+=1) else (set /a _set+=1)
)
echo   !_set! value^(s^) populated, !_blank! left blank.
exit /b 0


REM --- Forget anything a previous run or the environment left behind, so that
REM     "do not load the config" really does ask for everything.
:clear_all
for %%V in (ORACLE_SID SYS_PASSWORD OP_PASSWORD TABLESPACE_DATA TABLESPACE_INDEX
            ANONYMIZE_ENTITY ANONYMIZE_PORTFOLIO ANONYMIZE_COUNTERPARTY
            ANONYMIZE_UNCLASSIFIED_PARTY ANONYMIZE_BANK_ACCOUNT
            ANONYMIZE_ENTITY_DESCRIPTION ANONYMIZE_PORTFOLIO_DESCRIPTION
            ANONYMIZE_COUNTERPARTY_DESCRIPTION ANONYMIZE_UNCLASSIFIED_PARTY_DESCRIPTION
            ANONYMIZE_BANK_ACCOUNT_DESCRIPTION
            ANONYMIZE_ENTITY_ATTRIBUTES ANONYMIZE_PORTFOLIO_ATTRIBUTES
            ANONYMIZE_COUNTERPARTY_ATTRIBUTES ANONYMIZE_UNCLASSIFIED_PARTY_ATTRIBUTES
            ANONYMIZE_BANK_ACCOUNT_ATTRIBUTES APPROVE_STRUCTURE_ONLY_ACCOUNTS
            PARALLEL_DEGREE CUSTOM_INVENTORY FAIL_ON_MISSING_OBJECT) do set "%%V="
exit /b 0


REM --- A value counts as missing if unset or still a <PLACEHOLDER>.
REM     Sets _missing to 1 or 0.
:is_missing
set "_missing=1"
if not defined %~1 exit /b 0
set "_v=!%~1!"
if "!_v!"=="" exit /b 0
echo !_v! | findstr /C:"<" >nul 2>&1
if !errorlevel! EQU 0 exit /b 0
set "_missing=0"
exit /b 0


REM Separate labels rather than "if COND echo ... & exit /b": in batch the '&'
REM starts a new command that the if does NOT guard, so the exit would fire on
REM every call.
:echo_set
if /I "%~1"=="SYS_PASSWORD" goto :echo_set_masked
if /I "%~1"=="OP_PASSWORD"  goto :echo_set_masked
echo   [config] %~1 = !%~1!
exit /b 0
:echo_set_masked
echo   [config] %~1 = ********
exit /b 0


REM --- Required, no default. Prompts until answered.
REM     Usage: call :need VARNAME "description"
:need
call :is_missing "%~1"
if "!_missing!"=="0" goto :need_show
if "!INTERACTIVE!"=="0" goto :need_cannot_ask
:need_retry
set "%~1="
set /p "%~1=  %~2: "
if not defined %~1 (
    echo         that value is required
    goto :need_retry
)
exit /b 0
:need_show
if "!INTERACTIVE!"=="1" call :echo_set "%~1"
exit /b 0
:need_cannot_ask
echo ERROR: %~2 is not set in the configuration file, and /auto cannot ask for it.
exit /b 1


REM --- Value with a default. Enter accepts it.
REM     Usage: call :need_default VARNAME "description" DEFAULT
:need_default
call :is_missing "%~1"
if "!_missing!"=="0" goto :need_default_show
if "!INTERACTIVE!"=="0" goto :need_default_apply
set "%~1="
set /p "%~1=  %~2 [%~3]: "
if not defined %~1 goto :need_default_apply
exit /b 0
:need_default_apply
set "%~1=%~3"
exit /b 0
:need_default_show
if "!INTERACTIVE!"=="1" call :echo_set "%~1"
exit /b 0


REM --- Yes/no with a default.
REM     Usage: call :need_yn VARNAME "question" DEFAULT
:need_yn
call :is_missing "%~1"
if "!_missing!"=="0" goto :need_yn_show
if "!INTERACTIVE!"=="0" goto :need_yn_apply
set "%~1="
set /p "%~1=  %~2 [%~3]: "
if not defined %~1 goto :need_yn_apply
goto :need_yn_done
:need_yn_apply
set "%~1=%~3"
goto :need_yn_done
:need_yn_show
if "!INTERACTIVE!"=="1" call :echo_set "%~1"
:need_yn_done
REM Normalise so later comparisons and the summary are consistent. A value that
REM is neither yes nor no is passed through unchanged: the engine refuses it
REM rather than treating a typo as "no".
set "_v=!%~1!"
if defined _v set "_v=!_v:~0,1!"
if /I "!_v!"=="y" set "%~1=y"
if /I "!_v!"=="t" set "%~1=y"
if /I "!_v!"=="1" set "%~1=y"
if /I "!_v!"=="o" set "%~1=y"
if /I "!_v!"=="n" set "%~1=n"
if /I "!_v!"=="f" set "%~1=n"
if /I "!_v!"=="0" set "%~1=n"
exit /b 0


REM --- Ask a description/attributes switch, listing the columns it governs.
REM     The list is read from the inventory CSVs at prompt time, so it is always
REM     what will actually happen rather than a description that can drift.
REM
REM     These switches are independent of the category's renaming switch: a
REM     label can be masked while the identifier itself is kept.
REM
REM     Usage: call :flag_cols VARNAME RULE CATEGORY "Label"
:flag_cols
set "_var=%~1"
set "_rule=%~2"
set "_cat=%~3"

call :is_missing "%~1"
if "!_missing!"=="0" goto :flag_cols_show
if "!INTERACTIVE!"=="0" (
    set "%~1=y"
    exit /b 0
)

set "INVENTORY_CUSTOM=%ROOT%..\config\!CUSTOM_INVENTORY!"
if not defined CUSTOM_INVENTORY set "INVENTORY_CUSTOM=%ROOT%..\config\inventory_op_custom.csv"
echo   %~4 - columns affected:
set "_found=0"
call :list_cols "%INVENTORY_BASE%" "!_rule!" "!_cat!" ""
if exist "!INVENTORY_CUSTOM!" call :list_cols "!INVENTORY_CUSTOM!" "!_rule!" "!_cat!" "[site]"
if "!_found!"=="0" echo         none in the inventory - nothing would change

set "%~1="
set /p "%~1=      Anonymize these? [y]: "
if not defined %~1 set "%~1=y"
set "_v=!%~1!"
if defined _v set "_v=!_v:~0,1!"
if /I "!_v!"=="y" (set "%~1=y") else (set "%~1=n")
echo.
exit /b 0

:flag_cols_show
if "!INTERACTIVE!"=="1" call :echo_set "%~1"
exit /b 0


REM --- List inventory columns a category's switch governs: its own rows, the
REM     PARTY rows for a party category, and the structure rows (NODE_ROLE).
REM     Usage: call :list_cols <csv> <RULE> <CATEGORY> <tag>
:list_cols
for /f "usebackq eol=# tokens=1-5* delims=," %%A in ("%~1") do (
    if /I not "%%A"=="table_name" (
        if /I "%%C"=="%~2" (
            if /I "%%D"=="%~3" (
                echo         %%A.%%B %~4
                set "_found=1"
            )
            if /I "%%D"=="PARTY" if /I not "%~3"=="BANK_ACCOUNT" (
                echo         %%A.%%B %~4 - every party category
                set "_found=1"
            )
            if /I "%%D"=="NODE_ROLE" (
                echo         %%A.%%B %~4 - structure nodes of this category
                set "_found=1"
            )
        )
    )
)
exit /b 0


REM --- Parse one inventory CSV into INSERT statements.
REM     eol=# drops the comment lines; blank lines are skipped by for /f.
REM     tokens=1-5* keeps any commas in the notes field inside %%F.
:parse_csv
set "CSV=%~1"
set "SRC=%~2"
echo   reading %~nx1
for /f "usebackq eol=# tokens=1-5* delims=," %%A in ("%CSV%") do (
    set "TBL=%%A"
    set "COL=%%B"
    set "RUL=%%C"
    set "CAT=%%D"
    set "NTS=%%F"
    if /I not "!TBL!"=="table_name" (
        if not "!COL!"=="" if not "!RUL!"=="" if not "!CAT!"=="" (
            REM Strip apostrophes so they cannot break the generated SQL.
            REM
            REM "if defined" is not optional here. cmd does NOT perform substring
            REM replacement on an UNDEFINED variable - it leaks the search=replace
            REM text through instead, so an unguarded  set "NTS=!NTS:'=!"  turns an
            REM empty notes field into the literal  '=  . That produced
            REM   ...,'BASE',''=',1);
            REM for every row without a note: an odd number of quotes, and
            REM ORA-01756 on the very first INSERT.
            REM
            REM Most rows have no note, so this hit ~500 of 579 statements.
            if defined NTS set "NTS=!NTS:'=!"
            if defined TBL set "TBL=!TBL:'=!"
            if defined COL set "COL=!COL:'=!"
            set /a SEQ+=1
            REM A site-specific row OVERRIDES the shipped one for the same
            REM column. anon_inventory has a primary key on (table_name,
            REM column_name), so without this delete the second INSERT raises
            REM ORA-00001 instead of taking effect. The custom file is parsed
            REM second, so its row wins - which is how a wrong category in the
            REM shipped inventory gets corrected without editing it.
            if /I "%SRC%"=="CUSTOM" >> "%INVENTORY_SQL%" echo DELETE FROM anon_meta.anon_inventory WHERE table_name=UPPER^('!TBL!'^) AND column_name=UPPER^('!COL!'^);
            >> "%INVENTORY_SQL%" echo INSERT INTO anon_meta.anon_inventory ^(table_name,column_name,rule,category,source,notes,seq^) VALUES ^(UPPER^('!TBL!'^),UPPER^('!COL!'^),UPPER^('!RUL!'^),UPPER^('!CAT!'^),'%SRC%','!NTS!',!SEQ!^);
        )
    )
)
exit /b 0


:failed
echo.
if not defined INVENTORY_ONLY del "%INVENTORY_SQL%" 2>nul
exit /b 1

:cleanup_ok
del "%INVENTORY_SQL%" 2>nul
exit /b 0
