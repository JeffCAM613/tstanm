@echo off
rem ===========================================================================
rem OP Anonymization - Launcher
rem ===========================================================================
rem Purpose : Starts the run (lib\anon.ps1) in Windows PowerShell 5.1 with the
rem           given options, and returns its exit code.
rem Usage   : run_op_anonymization.bat [/dryrun] [/auto] [/force] [/verbose]
rem           [/no-open], or /inventory <file>, or /help
rem Exit    : 0 PASS (a dry run: completed), 1 failed or not started,
rem           2 FAIL, 3 REVIEW REQUIRED, 4 INCOMPLETE, 5 stopped with Ctrl+C.
rem ===========================================================================
setlocal
set "ANON_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%ANON_PS%" set "ANON_PS=powershell.exe"
"%ANON_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\anon.ps1" %*
exit /b %ERRORLEVEL%
