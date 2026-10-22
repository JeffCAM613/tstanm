# ============================================================================
# OP Anonymization - The run
# ============================================================================
# Purpose : Implementation of run_op_anonymization.bat. Reads the command
#           line and config\anonymization.ini, asks for what they leave
#           blank, gets ready by itself (sqlplus, the database as SYS and as
#           OP, the ANON_META schema, the engine, the inventory), then runs
#           the anonymization - or its dry run - in one sqlplus session while
#           a second one watches it, verifies a run, and leaves a folder with
#           the run's report (report.html), its output and its figures.
# Usage   : run_op_anonymization.bat [/dryrun] [/auto] [/force] [/verbose]
#           [/no-open], or /inventory <file>, or /help
# Requires: Windows PowerShell 5.1; sqlplus.exe in PATH or in
#           ORACLE_HOME\bin.
# Exit    : 0 PASS (a dry run: completed), 1 failed or not started, 2 FAIL,
#           3 REVIEW REQUIRED, 4 INCOMPLETE, 5 stopped with Ctrl+C.
#
# Passwords reach sqlplus on its standard input only: never on a command
# line, in a file this tool writes, or in the environment of a process it
# starts.
# ============================================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CliArgs    = @($args)
$script:OpDir      = Split-Path -Parent $PSScriptRoot
$script:RootDir    = Split-Path -Parent $script:OpDir
$script:SqlDir     = Join-Path $script:OpDir 'sql'
$script:RunSqlDir  = Join-Path $script:SqlDir 'run'
$script:VerifySql  = Join-Path $script:OpDir 'verify\verify_op_coverage.sql'
$script:ConfigDir  = Join-Path $script:RootDir 'config'
$script:ConfigFile = Join-Path $script:ConfigDir 'anonymization.ini'
$script:LogRoot    = Join-Path $script:OpDir 'logs'
$script:Width      = 80

# Exit codes, as the user guide lists them.
$script:ExitPass       = 0
$script:ExitError      = 1
$script:ExitVerifyFail = 2
$script:ExitReview     = 3
$script:ExitIncomplete = 4
$script:ExitStopped    = 5

# The launcher as it can be typed from the current directory: its path from
# there when it lies below it, its full path otherwise. Every command the
# screen tells the operator to type begins with it.
$script:Launcher = Join-Path $script:OpDir 'run_op_anonymization.bat'
try {
    $here = (Get-Location).ProviderPath.TrimEnd('\') + '\'
    if ($script:Launcher.StartsWith($here, [StringComparison]::OrdinalIgnoreCase)) {
        $script:Launcher = $script:Launcher.Substring($here.Length)
    }
} catch {
    $script:Launcher = 'run_op_anonymization.bat'
}
if ($script:Launcher.Contains(' ')) { $script:Launcher = '"' + $script:Launcher + '"' }

# Output: colour, --verbose, console.log of the run (lines written before its
# folder exists are kept and written when it is created), and the status line
# rewritten in place on a console (Show-Status).
$script:UseColor    = $true
$script:Verbose     = $false
$script:LogFile     = $null
$script:Buffered    = New-Object 'System.Collections.Generic.List[string]'
$script:StatusLine  = $false
$script:StatusShown = $false
$script:LastConsole = Get-Date
$script:Utf8        = New-Object System.Text.UTF8Encoding($false)

# sqlplus and the processes started from it, ended on every way out.
$script:SqlPlus     = $null
$script:Children    = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$script:ReadyMarker = 'ANON_SESSION_READY'
$script:ConnectTimeoutS = 120
# Errors printed by a CONNECT that succeeded: a password about to expire.
$script:ConnectWarnings = 'ORA-28002|ORA-28011'

# Ctrl+C read as a key (Enable-StopKey), and whether it was pressed.
$script:StopKeys  = $false
$script:StopAsked = $false

# sqlplus reads its input in the console code page. With a UTF-8 console .NET
# would begin each session's input with a byte order mark, which sqlplus
# rejects on the CONNECT line: the encoding is kept, without the mark.
try {
    if ([Console]::InputEncoding.CodePage -eq 65001 -and [Console]::InputEncoding.GetPreamble().Length -gt 0) {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch {
    # No console attached: sessions use the ANSI code page, which has no mark.
}

. (Join-Path $PSScriptRoot 'anon_screen.ps1')
. (Join-Path $PSScriptRoot 'anon_html.ps1')

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

# Appends a line to console.log of the run; lines written before the run
# folder exists are kept until it is created.
function Write-Log {
    param([string]$Text)
    if ($null -ne $script:LogFile) {
        [System.IO.File]::AppendAllText($script:LogFile, $Text + "`r`n", $script:Utf8)
    } else {
        $script:Buffered.Add($Text)
    }
}

# A line on the console (in colour) and in console.log. -Detail: on the
# console only with /verbose; -NoLog: on the console only.
function Write-Out {
    param([string]$Text = '', [string]$Color = '', [switch]$NoLog, [switch]$Detail)
    if ($script:Verbose -or -not $Detail) {
        Clear-Status
        if ($script:UseColor -and $Color -ne '') {
            Write-Host $Text -ForegroundColor $Color
        } else {
            Write-Host $Text
        }
        $script:LastConsole = Get-Date
    }
    if (-not $NoLog) { Write-Log $Text }
}

# The status line: one line rewritten in place on a console, cleared before
# the next line is written (Write-Out); never logged.
function Show-Status {
    param([string]$Text)
    if (-not $script:StatusLine) { return }
    $width = 0
    try { $width = [Console]::WindowWidth - 1 } catch { $width = 0 }
    if ($width -lt 20) { return }
    if ($Text.Length -gt $width) { $Text = $Text.Substring(0, $width - 3) + '...' }
    $previous = [Console]::ForegroundColor
    if ($script:UseColor) { [Console]::ForegroundColor = [ConsoleColor]::DarkGray }
    try {
        [Console]::Write("`r" + $Text.PadRight($width) + "`r")
    } finally {
        [Console]::ForegroundColor = $previous
    }
    $script:StatusShown = $true
}

function Clear-Status {
    if (-not $script:StatusShown) { return }
    $script:StatusShown = $false
    $width = 79
    try { $width = [Console]::WindowWidth - 1 } catch { $width = 79 }
    [Console]::Write("`r" + (' ' * $width) + "`r")
}

# Output of sqlplus, line by line without its trailing blank lines: on the
# console only with /verbose (-Detail) and always in console.log. The lines
# the wrapper reads (ANON_...) are left out of the console.
function Show-Lines {
    param([string[]]$Lines, [switch]$Detail)
    $last = $Lines.Count - 1
    while ($last -ge 0 -and $Lines[$last].Trim() -eq '') { $last-- }
    for ($i = 0; $i -le $last; $i++) {
        $line = $Lines[$i].TrimEnd()
        if ($line -match '^ANON_[A-Z_]+\|') { Write-Log $line; continue }
        $color = ''
        if ($line -match 'ORA-\d{5}|SP2-\d{4}|BLOCKED|INVALID') { $color = 'Red' }
        elseif ($line -match '\bREVIEW\b') { $color = 'Yellow' }
        Write-Out $line $color -Detail:$Detail
    }
}

# Ends the tool: the message (red unless the code is 0), then the exit code.
function Exit-Tool {
    param([int]$Code, [string]$Message = '')
    if ($Message -ne '') {
        if ($Code -eq 0) { Write-Out (' ' + $Message) } else { Write-Out (' ' + $Message) 'Red' }
    }
    Stop-Children
    Disable-StopKey
    exit $Code
}

function Show-Help {
    $text = @'
OP Anonymization

  Replaces the client data of the OP schema, on a restored copy of the
  database, with safe values: the codes of entities, portfolios,
  counterparties and bank accounts get a generated replacement (E_, P_, T_,
  X_, CB_) everywhere they are used, labels and attributes are masked with
  it, and free text is emptied. What is covered is listed in
  config\inventory_op.csv; what is switched on, in config\anonymization.ini.

Usage
  run_op_anonymization.bat
      The run: it checks, shows what it will change, then asks for YES.
  run_op_anonymization.bat /dryrun
      What a run would change. Changes nothing.
  run_op_anonymization.bat /auto
      Asks nothing: everything comes from the configuration file and the
      environment. A run still asks for YES; add /force to skip it.
  run_op_anonymization.bat /inventory <file>
      Writes the inventory as SQL to <file> and stops. Touches no database.

Options
  /verbose    every line of the engine on the screen, as it comes
  /no-open    report.html is not opened in the browser at the end
  /no-color   no colours on the screen
  /help       this text

Passwords
  Asked for, masked, when the configuration file leaves them blank. Without
  questions (/auto) they come from the environment - ANON_SYS_PASSWORD and
  ANON_OP_PASSWORD - or from the configuration file. They reach sqlplus on
  its input only.

Every run, dry runs included, leaves a folder in op\logs:
  report.html    the result, the figures, the checks; opened at the end
  report.txt     what the engine printed
  verify.txt     what the verification printed (a run)
  console.log    every line of the screen, and the engine's
  results.txt    the figures report.html is built from (counts only)
  manifest.txt   the run in key=value lines
  inventory.sql  the inventory as it was loaded

Ctrl+C asks the run to stop after the table or column it is working on; it
enables the triggers of OP again and ends. A new run resumes from there with
the same translations. Closing the window instead is not safe.

Exit codes
  0  PASS - the run was verified complete; a dry run that completed
  1  failed, or not started (refused by its checks, or not confirmed)
  2  FAIL - client data is still present
  3  REVIEW REQUIRED - values were left as they are, their role ambiguous
  4  INCOMPLETE - a protection was switched off
  5  stopped with Ctrl+C
'@
    Write-Host $text.Replace('run_op_anonymization.bat', $script:Launcher)
}

# ----------------------------------------------------------------------------
# Command line and configuration
# ----------------------------------------------------------------------------

function Read-Arguments {
    param([object[]]$List)
    $result = @{ DryRun = $false; Auto = $false; Force = $false; Verbose = $false; NoOpen = $false; Help = $false;
                 NoColor = $false; Inventory = $null }
    $i = 0
    while ($i -lt $List.Count) {
        $arg = ([string]$List[$i]).Trim()
        $name = $arg.ToLowerInvariant() -replace '^(/|--?)', ''
        if ($name -eq 'dryrun' -or $name -eq 'dry-run') { $result.DryRun = $true }
        elseif ($name -eq 'auto') { $result.Auto = $true }
        elseif ($name -eq 'force') { $result.Force = $true }
        elseif ($name -eq 'verbose') { $result.Verbose = $true }
        elseif ($name -eq 'no-open' -or $name -eq 'noopen') { $result.NoOpen = $true }
        elseif ($name -eq 'no-color' -or $name -eq 'nocolor') { $result.NoColor = $true }
        elseif ($name -eq 'help' -or $name -eq 'h' -or $name -eq '?') { $result.Help = $true }
        elseif ($name -eq 'inventory') {
            $i++
            if ($i -ge $List.Count -or ([string]$List[$i]).Trim() -eq '') {
                Exit-Tool $script:ExitError ('/inventory needs the file to write, for example: ' + $script:Launcher +
                                              ' /inventory "%TEMP%\inventory.sql"')
            }
            $result.Inventory = [string]$List[$i]
        } else {
            Exit-Tool $script:ExitError ('Unknown option ' + $arg + '. ' + $script:Launcher + ' /help lists the options.')
        }
        $i++
    }
    return $result
}

# config\anonymization.ini: NAME=VALUE lines; lines starting with @REM, REM,
# # or ; are comments. $null when there is no such file.
function Read-ConfigFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $values = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith('@') -or $text.StartsWith('#') -or $text.StartsWith(';') -or
            $text -match '^(?i)rem(\s|$)') { continue }
        $eq = $text.IndexOf('=')
        if ($eq -lt 1) { continue }
        $values[$text.Substring(0, $eq).Trim().ToUpperInvariant()] = $text.Substring($eq + 1).Trim()
    }
    return $values
}

# A setting counts as not given when it is missing, blank, or still a
# <PLACEHOLDER> of the template.
function Test-Given {
    param([hashtable]$Settings, [string]$Key)
    if (-not $Settings.ContainsKey($Key)) { return $false }
    $value = [string]$Settings[$Key]
    return ($value.Trim() -ne '' -and $value.IndexOf('<') -lt 0)
}

# y or n for a yes/no value (also yes, true, 1, o, oui / no, false, 0, non);
# $null for anything else.
function ConvertTo-YesNo {
    param([string]$Value)
    $v = $Value.Trim().ToUpperInvariant()
    if (@('Y', 'YES', 'TRUE', '1', 'O', 'OUI') -contains $v) { return 'y' }
    if (@('N', 'NO', 'FALSE', '0', 'NON') -contains $v) { return 'n' }
    return $null
}

# The names of the 15 switches, in the order the engine takes them: the
# renaming of each category, then its labels, then its attributes.
function Get-SwitchKeys {
    $keys = @()
    foreach ($c in $script:Categories) { $keys += ('ANONYMIZE_' + $c) }
    foreach ($c in $script:Categories) { $keys += ('ANONYMIZE_' + $c + '_DESCRIPTION') }
    foreach ($c in $script:Categories) { $keys += ('ANONYMIZE_' + $c + '_ATTRIBUTES') }
    return $keys
}

# The version of the engine this wrapper installs.
function Get-ToolVersion {
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $script:SqlDir '30_install_engine.sql'))) {
        if ($line -match "c_version\s+CONSTANT\s+VARCHAR2\(\d+\)\s*:=\s*'([^']+)'") { return $Matches[1] }
    }
    return ''
}

# ----------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------

# One line typed by the operator. On a console the keys are read one by one,
# so that Ctrl+C - read as a key while sessions run - cancels the question
# ($null) rather than the tool; -Mask shows * for each character. When the
# input is a file or a pipe, its next line ($null at its end).
function Read-ConsoleLine {
    param([switch]$Mask)
    if ([Console]::IsInputRedirected) {
        # Nothing is echoed: the prompt's line is ended here.
        $line = [Console]::In.ReadLine()
        Write-Host ''
        return $line
    }
    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            [Console]::WriteLine()
            return $buffer.ToString()
        }
        if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
            [Console]::WriteLine()
            $script:StopAsked = $true
            return $null
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                $buffer.Length = $buffer.Length - 1
                [Console]::Write("`b `b")
            }
            continue
        }
        if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
            $null = $buffer.Append($key.KeyChar)
            if ($Mask) { [Console]::Write('*') } else { [Console]::Write($key.KeyChar) }
        }
    }
}

# A divider before a question, so that each one stands apart.
function Write-Ask {
    param([string]$Title)
    $text = ' -- ' + $Title + ' '
    Write-Out ''
    Write-Out ($text + ('-' * [Math]::Max(3, $script:Width - $text.Length))) 'DarkCyan'
}

# Writes a prompt, marked ">" and in colour, and reads the answer.
function Read-Prompt {
    param([string]$Label, [switch]$Mask)
    Clear-Status
    $text = ' > ' + $Label + ': '
    if ($script:UseColor) { Write-Host $text -NoNewline -ForegroundColor Cyan } else { Write-Host $text -NoNewline }
    return (Read-ConsoleLine -Mask:$Mask)
}

# The operator stopped at a question (Ctrl+C, or an input with no more
# lines): nothing has changed yet.
function Stop-AtQuestion {
    param([string]$What)
    Exit-Tool $script:ExitStopped ('Stopped at the question "' + $What + '". Nothing was changed.')
}

# A value: asked until one is given; Enter takes the default.
function Read-Answer {
    param([string]$Prompt, [string]$Default = '', [string]$Pattern = '', [string]$Hint = 'a value is required')
    $label = $Prompt
    if ($Default -ne '') { $label = $label + ' [' + $Default + ']' }
    while ($true) {
        $answer = Read-Prompt $label
        if ($null -eq $answer) { Stop-AtQuestion $Prompt }
        if ($answer.Trim() -eq '') { $answer = $Default }
        $answer = $answer.Trim()
        if ($answer -ne '' -and ($Pattern -eq '' -or $answer -match $Pattern)) {
            Write-Log (' > ' + $label + ': ' + $answer)
            return $answer
        }
        Write-Out ('   ' + $Hint) 'Yellow' -NoLog
    }
}

function Read-YesNoAnswer {
    param([string]$Prompt, [string]$Default = 'y')
    while ($true) {
        $answer = Read-Prompt ($Prompt + ' [' + $Default + ']')
        if ($null -eq $answer) { Stop-AtQuestion $Prompt }
        if ($answer.Trim() -eq '') { $answer = $Default }
        $value = ConvertTo-YesNo $answer
        if ($null -ne $value) {
            Write-Log (' > ' + $Prompt + ' [' + $Default + ']: ' + $value)
            return $value
        }
        Write-Out '   y or n' 'Yellow' -NoLog
    }
}

function ConvertFrom-Secure {
    param([System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function ConvertTo-Secure {
    param([string]$Text)
    $secure = New-Object System.Security.SecureString
    foreach ($c in $Text.ToCharArray()) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    return $secure
}

# A password, masked. Kept as a SecureString until it is written on the input
# of a sqlplus session.
function Read-Password {
    param([string]$Prompt)
    while ($true) {
        $answer = Read-Prompt $Prompt -Mask
        if ($null -eq $answer) { Stop-AtQuestion $Prompt }
        if ($answer -ne '') {
            Write-Log (' > ' + $Prompt + ': ********')
            return (ConvertTo-Secure $answer)
        }
        Write-Out '   a value is required' 'Yellow' -NoLog
    }
}

# ----------------------------------------------------------------------------
# The inventory
# ----------------------------------------------------------------------------

# The rows of an inventory CSV: table,column,rule,category,source,notes. Lines
# starting with # and blank lines are skipped, and the header line. The notes
# are the rest of the line, commas included. A line that is not a valid row
# stops the run, with its file and line number.
function Read-InventoryCsv {
    param([string]$Path, [string]$Source)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $n++
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith('#')) { continue }
        $field = $text.Split([char[]]@(','), 6)
        if ($field[0].Trim().ToLowerInvariant() -eq 'table_name') { continue }
        $bad = ''
        if ($field.Count -lt 4) {
            $bad = 'expected table,column,rule,category,source,notes'
        } elseif ($field[0].Trim() -notmatch '^[A-Za-z][A-Za-z0-9_$#]*$' -or $field[1].Trim() -notmatch '^[A-Za-z][A-Za-z0-9_$#]*$') {
            $bad = 'a table or column name has characters a name cannot have'
        } elseif ($field[2].Trim() -notmatch '^[A-Za-z_]+$' -or $field[3].Trim() -notmatch '^[A-Za-z_]+$') {
            $bad = 'the rule or the category is not a single word'
        }
        if ($bad -ne '') {
            Exit-Tool $script:ExitError ((Split-Path -Leaf $Path) + ', line ' + $n + ': ' + $bad + '. Correct the line, or comment it out with #.')
        }
        $notes = ''
        if ($field.Count -ge 6) { $notes = $field[5].Trim() }
        $rows.Add([pscustomobject]@{ Table = $field[0].Trim(); Column = $field[1].Trim(); Rule = $field[2].Trim();
                                     Category = $field[3].Trim(); Notes = $notes; Source = $Source })
    }
    return ,$rows.ToArray()
}

# The inventory as SQL: one INSERT per row, numbered in file order. A site row
# (CUSTOM) replaces the shipped row of the same column: the custom file comes
# second, and its DELETE goes first. Quotes in the notes are doubled.
function New-InventorySql {
    param([object[]]$BaseRows, [object[]]$CustomRows)
    $sql = New-Object 'System.Collections.Generic.List[string]'
    $sql.Add('SET DEFINE OFF')
    $sql.Add('SET FEEDBACK OFF')
    $seq = 0
    foreach ($r in @($BaseRows) + @($CustomRows)) {
        $seq++
        $table = $r.Table.Replace("'", '')
        $column = $r.Column.Replace("'", '')
        if ($r.Source -eq 'CUSTOM') {
            $sql.Add("DELETE FROM anon_meta.anon_inventory WHERE table_name=UPPER('" + $table + "') AND column_name=UPPER('" + $column + "');")
        }
        $sql.Add("INSERT INTO anon_meta.anon_inventory (table_name,column_name,rule,category,source,notes,seq) VALUES (UPPER('" +
                 $table + "'),UPPER('" + $column + "'),UPPER('" + $r.Rule + "'),UPPER('" + $r.Category + "'),'" + $r.Source +
                 "','" + $r.Notes.Replace("'", "''") + "'," + $seq + ');')
    }
    $sql.Add('COMMIT;')
    $sql.Add('SET DEFINE ON')
    return ,$sql.ToArray()
}

# The site inventory file named by CUSTOM_INVENTORY, in config\.
function Get-CustomInventoryPath {
    param([hashtable]$Settings)
    $name = 'inventory_op_custom.csv'
    if (Test-Given $Settings 'CUSTOM_INVENTORY') { $name = [string]$Settings['CUSTOM_INVENTORY'] }
    return (Join-Path $script:ConfigDir $name)
}

# /inventory <file>: the inventory as SQL, written to a file; no database.
function Invoke-InventoryOnly {
    param([string]$Target)
    $settings = Read-ConfigFile $script:ConfigFile
    if ($null -eq $settings) { $settings = @{} }
    $base = Join-Path $script:ConfigDir 'inventory_op.csv'
    if (-not (Test-Path -LiteralPath $base)) { Exit-Tool $script:ExitError ('The inventory was not found: ' + $base) }
    $custom = Get-CustomInventoryPath $settings
    $customRows = @()
    if (Test-Path -LiteralPath $custom) { $customRows = Read-InventoryCsv $custom 'CUSTOM' }
    $sql = New-InventorySql (Read-InventoryCsv $base 'BASE') $customRows
    $full = [System.IO.Path]::GetFullPath($Target)
    [System.IO.File]::WriteAllLines($full, $sql, $script:Utf8)
    Write-Out (' Inventory written to ' + $full)
    exit $script:ExitPass
}

# The columns a label or attribute switch covers, for its question: its own
# rows, the PARTY rows for a party category, and the structure rows.
function Get-SwitchColumns {
    param([object[]]$Rows, [string]$Rule, [string]$Category)
    $list = @()
    foreach ($r in $Rows) {
        if ($r.Rule.ToUpperInvariant() -ne $Rule) { continue }
        $cat = $r.Category.ToUpperInvariant()
        $tag = ''
        if ($r.Source -eq 'CUSTOM') { $tag = ' [site]' }
        if ($cat -eq $Category) { $list += ($r.Table.ToLower() + '.' + $r.Column.ToLower() + $tag) }
        elseif ($cat -eq 'PARTY' -and $Category -ne 'BANK_ACCOUNT') { $list += ($r.Table.ToLower() + '.' + $r.Column.ToLower() + $tag + ' (every party)') }
        elseif ($cat -eq 'NODE_ROLE') { $list += ($r.Table.ToLower() + '.' + $r.Column.ToLower() + $tag + ' (its structure nodes)') }
    }
    return ,$list
}

# ----------------------------------------------------------------------------
# sqlplus sessions
# ----------------------------------------------------------------------------

function Find-SqlPlus {
    $command = Get-Command 'sqlplus.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Path }
    $oracleHome = [Environment]::GetEnvironmentVariable('ORACLE_HOME')
    if (-not [string]::IsNullOrEmpty($oracleHome)) {
        $candidate = Join-Path $oracleHome 'bin\sqlplus.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function New-Login {
    param([string]$User, [System.Security.SecureString]$Secret, [string]$Tns, [switch]$Sysdba)
    return [pscustomobject]@{ User = $User; Secret = $Secret; Tns = $Tns; Sysdba = [bool]$Sysdba }
}

# The CONNECT line written on the input of a session. The password is quoted,
# so that one with @ or / is not read as part of the connect string.
function Get-ConnectLine {
    param($Login)
    $line = 'CONNECT ' + $Login.User + '/"' + (ConvertFrom-Secure $Login.Secret) + '"@' + $Login.Tns
    if ($Login.Sysdba) { $line = $line + ' AS SYSDBA' }
    return $line
}

function Start-SqlProcess {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:SqlPlus
    $info.Arguments = '-S -L /nolog'
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $script:OpDir
    # The passwords given in the environment for /auto are not passed on.
    foreach ($name in @('ANON_SYS_PASSWORD', 'ANON_OP_PASSWORD')) { $info.EnvironmentVariables.Remove($name) }
    $process = [System.Diagnostics.Process]::Start($info)
    $script:Children.Add($process)
    return $process
}

# Ends every sqlplus session still running, so that none outlives the tool.
function Stop-Children {
    foreach ($child in $script:Children) {
        try {
            if (-not $child.HasExited) { $child.Kill() }
        } catch {
            Write-Log (' A sqlplus session could not be ended (PID ' + $child.Id + '): ' + $_.Exception.Message)
        }
    }
}

# A script of this tool, as sqlplus runs it: @"<path>" and its arguments.
function Get-ScriptLine {
    param([string]$Path, [string[]]$Arguments = @())
    $line = '@"' + $Path + '"'
    foreach ($a in $Arguments) { $line = $line + ' ' + $a }
    return $line
}

# A sqlplus session connected as $Login. Only the CONNECT line goes first,
# with a marker after it: sqlplus prints the marker once the CONNECT has
# finished, whether it succeeded or not. Returns Ok, Error (the ORA- or SP2-
# line of a CONNECT that failed), and the session: Process, Pending (the line
# being read), Errors (its standard error), Output (every line it printed).
function Open-Session {
    param($Login, [string]$Name)
    $process = Start-SqlProcess
    $session = [pscustomobject]@{ Name = $Name; Login = $Login; Process = $process; Pending = $null;
                                  Errors = $process.StandardError.ReadToEndAsync(); Ended = $false; Ok = $false; Error = '';
                                  Output = (New-Object 'System.Collections.Generic.List[string]') }
    $process.StandardInput.WriteLine((Get-ConnectLine $Login))
    $process.StandardInput.WriteLine('PROMPT ' + $script:ReadyMarker)
    $process.StandardInput.Flush()
    $deadline = (Get-Date).AddSeconds($script:ConnectTimeoutS)
    while ($true) {
        if ($null -eq $session.Pending) { $session.Pending = $process.StandardOutput.ReadLineAsync() }
        if ($session.Pending.Wait(250)) {
            $line = $session.Pending.Result
            $session.Pending = $null
            if ($null -eq $line) {
                $session.Ended = $true
                if ($session.Error -eq '') { $session.Error = 'sqlplus ended before it connected.' }
                return $session
            }
            if ($line -eq $script:ReadyMarker) {
                if ($session.Error -eq '') { $session.Ok = $true } else { Close-Session $session -Kill }
                return $session
            }
            $session.Output.Add($line)
            if ($session.Error -eq '' -and $line -match '(ORA-\d{5}|SP2-\d{4}).*' -and $line -notmatch $script:ConnectWarnings) {
                $session.Error = $Matches[0].Trim()
            }
            continue
        }
        if ($script:StopKeys) { Test-StopKey }
        if ((Get-Date) -ge $deadline) {
            $session.Error = 'no answer from ' + $Login.Tns + ' within ' + $script:ConnectTimeoutS + ' s'
            Close-Session $session -Kill
            return $session
        }
    }
}

function Close-Session {
    param($Session, [switch]$Kill)
    if ($null -eq $Session) { return }
    try {
        if (-not $Session.Process.HasExited) {
            if ($Kill) {
                $Session.Process.Kill()
            } else {
                $Session.Process.StandardInput.WriteLine('EXIT')
                $Session.Process.StandardInput.Close()
                if (-not $Session.Process.WaitForExit(15000)) { $Session.Process.Kill() }
            }
        }
    } catch {
        Write-Log (' The ' + $Session.Name + ' session could not be closed cleanly: ' + $_.Exception.Message)
    }
}

# Sends commands to an open session and returns the lines it printed up to
# an end marker. $OnWait runs about every two seconds meanwhile (the live
# view), and Ctrl+C is read meanwhile; without $OnWait (the monitor's own
# commands) the keys are left for the wait that called it. A session that
# ends before the marker (its connection lost, sqlplus ended) sets Ended.
# $TimeoutS: 0 waits as long as the command takes.
function Invoke-SessionCommand {
    param($Session, [string[]]$Commands, [scriptblock]$OnWait = $null, [int]$TimeoutS = 0)
    if ($Session.Ended -or $Session.Process.HasExited) {
        $Session.Ended = $true
        return ,@()
    }
    $marker = 'ANON_END_' + [Guid]::NewGuid().ToString('N')
    $in = $Session.Process.StandardInput
    foreach ($c in $Commands) { $in.WriteLine($c) }
    $in.WriteLine('PROMPT ' + $marker)
    $in.Flush()
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $next = (Get-Date).AddSeconds(2)
    $deadline = [datetime]::MaxValue
    if ($TimeoutS -gt 0) { $deadline = (Get-Date).AddSeconds($TimeoutS) }
    while ($true) {
        if ($null -eq $Session.Pending) { $Session.Pending = $Session.Process.StandardOutput.ReadLineAsync() }
        if ($Session.Pending.Wait(250)) {
            $line = $Session.Pending.Result
            $Session.Pending = $null
            if ($null -eq $line) {
                $Session.Ended = $true
                break
            }
            if ($line -eq $marker) { break }
            $lines.Add($line)
            $Session.Output.Add($line)
        }
        if ($script:StopKeys -and $null -ne $OnWait) { Test-StopKey }
        if ($null -ne $OnWait -and (Get-Date) -ge $next) {
            & $OnWait
            $next = (Get-Date).AddSeconds(2)
        }
        if ((Get-Date) -ge $deadline) {
            throw (New-Object System.TimeoutException(('The ' + $Session.Name + ' session did not answer within ' + $TimeoutS + ' s.')))
        }
    }
    return ,$lines.ToArray()
}

# One script in a session of its own: connect, run, EXIT. Returns ExitCode
# (1 when the session could not connect) and Lines. $OnWait as for
# Invoke-SessionCommand.
function Invoke-SqlScript {
    param($Login, [string]$Name, [string[]]$Commands, [scriptblock]$OnWait = $null)
    $session = Open-Session $Login $Name
    if (-not $session.Ok) {
        return [pscustomobject]@{ ExitCode = $script:ExitError; Lines = @($session.Output); Error = $session.Error }
    }
    $process = $session.Process
    foreach ($c in $Commands) { $process.StandardInput.WriteLine($c) }
    $process.StandardInput.WriteLine('EXIT')
    $process.StandardInput.Close()
    $next = (Get-Date).AddSeconds(2)
    while ($true) {
        if ($null -eq $session.Pending) { $session.Pending = $process.StandardOutput.ReadLineAsync() }
        if ($session.Pending.Wait(250)) {
            $line = $session.Pending.Result
            $session.Pending = $null
            if ($null -eq $line) { break }
            $session.Output.Add($line)
        }
        if ($script:StopKeys) { Test-StopKey }
        if ($null -ne $OnWait -and (Get-Date) -ge $next) {
            & $OnWait
            $next = (Get-Date).AddSeconds(2)
        }
    }
    $process.WaitForExit()
    $errors = $session.Errors.Result
    $lines = @($session.Output)
    if (-not [string]::IsNullOrEmpty($errors)) { $lines += @($errors -split "`r?`n") }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = $lines; Error = '' }
}

# Connects as $Login and says what to: ANON_SESSION of run/session.sql.
function Test-Login {
    param($Login)
    $result = Invoke-SqlScript $Login ('test ' + $Login.User) @((Get-ScriptLine (Join-Path $script:RunSqlDir 'session.sql')))
    foreach ($line in $result.Lines) {
        if ($line -match '^ANON_SESSION\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$') {
            return [pscustomobject]@{ Ok = $true; Database = $Matches[2]; Container = $Matches[3]; Version = $Matches[4];
                                      Clock = $Matches[5]; Error = '' }
        }
    }
    $err = $result.Error
    if ($err -eq '') {
        foreach ($line in $result.Lines) { if ($line -match '(ORA-\d{5}|SP2-\d{4}).*') { $err = $Matches[0].Trim(); break } }
    }
    if ($err -eq '') { $err = 'the connection test printed nothing it could read' }
    return [pscustomobject]@{ Ok = $false; Database = ''; Container = ''; Version = ''; Clock = ''; Error = $err }
}

# ----------------------------------------------------------------------------
# Ctrl+C
# ----------------------------------------------------------------------------

# Ctrl+C becomes a key the tool reads, so that it cannot end the tool while a
# session works - and so that it never leaves OP's triggers disabled. Only
# when the console input is a keyboard.
function Enable-StopKey {
    if ([Console]::IsInputRedirected) { return }
    try {
        [Console]::TreatControlCAsInput = $true
        $script:StopKeys = $true
    } catch {
        $script:StopKeys = $false
    }
}

function Disable-StopKey {
    if (-not $script:StopKeys) { return }
    try { [Console]::TreatControlCAsInput = $false } catch { Write-Log (' ' + $_.Exception.Message) }
    $script:StopKeys = $false
}

# Reads the keys pressed while a session works: Ctrl+C asks for a stop, once.
function Test-StopKey {
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                if ($script:StopAsked) {
                    Write-Out ' Stop already asked for: the run stops after the table or column it works on.' 'Yellow'
                } else {
                    $script:StopAsked = $true
                    Request-Stop
                }
            }
        }
    } catch {
        $script:StopKeys = $false
    }
}

# ----------------------------------------------------------------------------
# The run
# ----------------------------------------------------------------------------

function Get-RunLabel {
    param([long]$RunId)
    return 'R-' + $RunId.ToString('000000')
}

# op\logs\<date>_<time>_R-<run>: the run's folder. console.log begins with
# every line written so far.
function New-RunFolder {
    param([long]$RunId)
    $folder = Join-Path $script:LogRoot ((Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + (Get-RunLabel $RunId))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $script:LogFile = Join-Path $folder 'console.log'
    [System.IO.File]::WriteAllLines($script:LogFile, $script:Buffered.ToArray(), $script:Utf8)
    $script:Buffered.Clear()
    return $folder
}

# The folder as the screen shows it: from the current directory when it lies
# below it.
function Format-Folder {
    param([string]$Folder)
    try {
        $here = (Get-Location).ProviderPath.TrimEnd('\') + '\'
        if ($Folder.StartsWith($here, [StringComparison]::OrdinalIgnoreCase)) { return $Folder.Substring($here.Length) }
    } catch {
        return $Folder
    }
    return $Folder
}

function Write-RunFile {
    param([string]$Folder, [string]$Name, [string[]]$Lines)
    if ($null -eq $Folder) { return }
    [System.IO.File]::WriteAllLines((Join-Path $Folder $Name), [string[]]@($Lines), $script:Utf8)
}

# The ANON_RESULT line of a script's output: Status, Code, Message.
function Get-ScriptResult {
    param([string[]]$Lines)
    foreach ($line in $Lines) {
        if ($line -match '^ANON_RESULT\|([A-Z]+)\|?([^|]*)\|?(.*)$') {
            return [pscustomobject]@{ Status = $Matches[1]; Code = $Matches[2]; Message = $Matches[3] }
        }
    }
    # No result line: the script did not run to its end (an error before it,
    # or the session ended).
    $message = ''
    foreach ($line in $Lines) { if ($line -match '(ORA-\d{5}|SP2-\d{4}).*') { $message = $Matches[0].Trim(); break } }
    if ($message -eq '') { $message = 'the session printed no result' }
    return [pscustomobject]@{ Status = 'FAILED'; Code = ''; Message = $message }
}

# Asks the run to stop (stop.sql in the monitor session). The engine reads the
# request between two tables or columns. Before the work begins, the run is
# stopped by the wrapper itself once the step under way ends.
function Request-Stop {
    $state = $script:Run
    if ($null -ne $state -and $state.Verifying) {
        Write-Out ' Ctrl+C: the run is complete; its verification is read-only and ends by itself in a moment.' 'Yellow'
        return
    }
    if ($null -eq $state -or $state.RunId -eq 0 -or -not $state.Working) {
        Write-Out ' Ctrl+C: stopping once the step under way ends. Nothing has been changed yet.' 'Yellow'
        return
    }
    Write-Out ' Ctrl+C: the run stops after the table or column it works on, then enables the triggers of OP again.' 'Yellow'
    if ($null -eq $state.Monitor) {
        Write-Out (' The monitor session is not available: run op\sql\run\stop.sql ' + $state.RunId + ' as OP to stop it.') 'Yellow'
        return
    }
    try {
        $lines = Invoke-SessionCommand $state.Monitor @((Get-ScriptLine (Join-Path $script:RunSqlDir 'stop.sql') @([string]$state.RunId))) -TimeoutS 60
        $line = @($lines | Where-Object { $_ -like 'ANON_STOP|*' } | Select-Object -First 1)
        if ($line.Count -eq 0 -or $line[0] -notlike 'ANON_STOP|REQUESTED*') {
            Write-Out (' The stop could not be asked for: ' + ($lines -join ' ')) 'Yellow'
        }
    } catch {
        Write-Out (' The stop could not be asked for: ' + $_.Exception.Message) 'Yellow'
    }
}

# One look at the run (poll.sql in the monitor session): the steps logged
# since the last look, where the run is now. A monitor that does not answer is
# given up: the live view stops, the run goes on.
function Update-LiveView {
    param([string]$Mode = 'RUN')
    $state = $script:Run
    if ($null -eq $state -or $null -eq $state.Monitor -or -not $state.Live) {
        Show-FlowStatus $null
        return
    }
    $poll = [pscustomobject]@{ Progress = $null; LongOp = $null; Verify = @{} }
    # poll.sql returns 500 rows of the log at most: read on until it is
    # caught up.
    $batch = 500
    while ($batch -ge 500) {
        $command = Get-ScriptLine (Join-Path $script:RunSqlDir 'poll.sql') @([string]$state.RunId, [string]$state.LastStep, $Mode)
        try {
            $lines = Invoke-SessionCommand $state.Monitor @($command) -TimeoutS 60
        } catch {
            $state.Live = $false
            Write-Out (' The live view stops: ' + $_.Exception.Message + ' The run goes on.') 'Yellow'
            return
        }
        if ($state.Monitor.Ended) {
            $state.Live = $false
            Write-Out ' The live view stops: its session ended. The run goes on.' 'Yellow'
            return
        }
        $batch = Read-PollLines $lines $poll
    }
    Show-FlowStatus $poll
}

# The lines of one poll: the steps go to the screen's accounts as they come;
# where the run is, into $Poll. Returns how many steps it read.
function Read-PollLines {
    param([string[]]$Lines, $Poll)
    $state = $script:Run
    $steps = 0
    foreach ($line in $Lines) {
        if ($line.StartsWith('ANON_STEP|')) {
            $f = $line.Split([char[]]@('|'), 10)
            if ($f.Count -lt 10) { continue }
            $steps++
            $state.LastStep = [long]$f[1]
            $step = [pscustomobject]@{ Id = [long]$f[1]; Phase = $f[2]; Status = $f[3]; Rows = (ConvertTo-Number $f[4]);
                                       X = (ConvertTo-Number $f[5]); Ms = (ConvertTo-Number $f[6]); Rule = $f[7];
                                       Object = $f[8]; Message = $f[9] }
            Add-FlowStep $step
        } elseif ($line.StartsWith('ANON_PROGRESS|')) {
            $f = $line.Split([char[]]@('|'), 11)
            if ($f.Count -lt 11) { continue }
            $Poll.Progress = [pscustomobject]@{ Phase = $f[1]; Stage = $f[2]; Done = (ConvertTo-Number $f[3]);
                                                Total = (ConvertTo-Number $f[4]); WeightDone = (ConvertTo-Number $f[5]);
                                                Weight = (ConvertTo-Number $f[6]); WeightTotal = (ConvertTo-Number $f[7]);
                                                OnObject = (ConvertTo-Number $f[8]); InPhase = (ConvertTo-Number $f[9]);
                                                Object = $f[10] }
        } elseif ($line.StartsWith('ANON_LONGOP|')) {
            $f = $line.Split([char[]]@('|'), 4)
            if ($f.Count -eq 4) { $Poll.LongOp = [pscustomobject]@{ Pct = (ConvertTo-Number $f[1]); Left = (ConvertTo-Number $f[2]); Operation = $f[3] } }
        } elseif ($line.StartsWith('ANON_VERIFY|')) {
            $f = $line.Split('|')
            if ($f.Count -ge 3) { $Poll.Verify[$f[1]] = ConvertTo-Number $f[2] }
        } elseif ($line -match 'ORA-\d{5}|SP2-\d{4}') {
            Write-Log (' monitor: ' + $line)
        }
    }
    return $steps
}

# Runs one script in the worker session, with the live view meanwhile. The
# output goes to report.txt (the engine's lines) and, with /verbose, to the
# screen.
function Invoke-Worker {
    param([string[]]$Commands)
    $state = $script:Run
    $onWait = { Update-LiveView }
    $lines = Invoke-SessionCommand $state.Worker $Commands $onWait
    $state.Report.AddRange([string[]]@($lines | Where-Object { $_ -notmatch '^ANON_[A-Z_]+\|' }))
    Show-Lines $lines -Detail
    return ,$lines
}

# manifest.txt: the run in key=value lines, for whoever reviews it.
function Write-Manifest {
    param($State, [string]$Status, [string]$Verdict, [int]$ExitCode)
    $m = New-Object 'System.Collections.Generic.List[string]'
    $m.Add('run=' + (Get-RunLabel $State.RunId))
    $m.Add('mode=' + $State.Mode)
    $m.Add('written_at=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $m.Add('tool_version=' + $State.Version)
    $m.Add('database=' + $State.Database)
    $m.Add('connect=' + $State.Tns)
    foreach ($key in (Get-SwitchKeys)) { $m.Add($key.ToLowerInvariant() + '=' + $State.Settings[$key]) }
    foreach ($key in @('APPROVE_STRUCTURE_ONLY_ACCOUNTS', 'PARALLEL_DEGREE', 'FAIL_ON_MISSING_OBJECT', 'CUSTOM_INVENTORY')) {
        $m.Add($key.ToLowerInvariant() + '=' + $State.Settings[$key])
    }
    $m.Add('inventory_items=' + $State.Inventory.Items)
    $m.Add('inventory_shipped=' + $State.Inventory.Shipped)
    $m.Add('inventory_site=' + $State.Inventory.Site)
    $m.Add('inventory_here=' + $State.Inventory.Here)
    foreach ($s in $State.Durations) { $m.Add('step.' + $s.Key + '=' + $s.Status + '|' + [int][Math]::Round($s.Seconds)) }
    foreach ($c in $State.Checks) { $m.Add('check.' + $c.Code.ToLowerInvariant() + '=' + $c.Status + '|' + $c.State) }
    $m.Add('stop_requested=' + $(if ($script:StopAsked) { 'Y' } else { 'N' }))
    $m.Add('status=' + $Status)
    $m.Add('verdict=' + $Verdict)
    $m.Add('exit_code=' + $ExitCode)
    Write-RunFile $State.Folder 'manifest.txt' $m.ToArray()
}

# Settles every setting: the configuration file, the environment (passwords),
# then the questions for what is still missing. Without questions (/auto) a
# missing value that has no default ends the tool.
function Get-Settings {
    param($Cli, [hashtable]$File)
    $s = @{}
    if ($null -ne $File) { foreach ($k in $File.Keys) { $s[$k] = $File[$k] } }
    $interactive = -not $Cli.Auto

    foreach ($pair in @(@('SYS_PASSWORD', 'ANON_SYS_PASSWORD'), @('OP_PASSWORD', 'ANON_OP_PASSWORD'))) {
        $value = [Environment]::GetEnvironmentVariable($pair[1])
        if (-not [string]::IsNullOrEmpty($value)) { $s[$pair[0]] = $value }
    }

    # Missing without questions: what cannot be defaulted stops the run.
    $required = @(@('ORACLE_SID', 'the database (its alias in tnsnames.ora, or host:port/service)'),
                  @('SYS_PASSWORD', 'the SYS password (or ANON_SYS_PASSWORD in the environment)'),
                  @('OP_PASSWORD', 'the OP password (or ANON_OP_PASSWORD in the environment)'),
                  @('TABLESPACE_DATA', 'the tablespace of the ANON_META tables'))
    if (-not $interactive) {
        foreach ($r in $required) {
            if (-not (Test-Given $s $r[0])) {
                Exit-Tool $script:ExitError ($r[0] + ' is not set: ' + $r[1] + '. /auto asks nothing: set it in config\anonymization.ini.')
            }
        }
    }

    if (-not (Test-Given $s 'ORACLE_SID')) {
        Write-Ask 'Database'
        $s['ORACLE_SID'] = Read-Answer 'Database (its alias in tnsnames.ora, or host:port/service)'
    }
    if (-not (Test-Given $s 'SYS_PASSWORD') -or -not (Test-Given $s 'OP_PASSWORD')) {
        Write-Ask 'Passwords'
        Write-Out '   Sent to sqlplus on its input: never on a command line, never written down.'
        if (-not (Test-Given $s 'SYS_PASSWORD')) { $s['_SYS_SECRET'] = Read-Password 'SYS password' }
        if (-not (Test-Given $s 'OP_PASSWORD')) { $s['_OP_SECRET'] = Read-Password 'OP password' }
    }
    if (-not (Test-Given $s 'TABLESPACE_DATA')) {
        Write-Ask 'Tablespaces of ANON_META'
        Write-Out '   ANON_META holds the translations, the inventory and the run log: a few MB.'
        $s['TABLESPACE_DATA'] = Read-Answer 'Tablespace of its tables' '' '^[A-Za-z][A-Za-z0-9_$#]*$' 'a tablespace name'
    }
    if (-not (Test-Given $s 'TABLESPACE_INDEX')) {
        if ($interactive) {
            $s['TABLESPACE_INDEX'] = Read-Answer 'Tablespace of its indexes' $s['TABLESPACE_DATA'] '^[A-Za-z][A-Za-z0-9_$#]*$' 'a tablespace name'
        } else {
            $s['TABLESPACE_INDEX'] = $s['TABLESPACE_DATA']
        }
    }
    foreach ($key in @('TABLESPACE_DATA', 'TABLESPACE_INDEX')) {
        if ([string]$s[$key] -notmatch '^[A-Za-z][A-Za-z0-9_$#]*$') {
            Exit-Tool $script:ExitError ($key + ' must be a tablespace name, not "' + $s[$key] + '".')
        }
    }

    # The switches: the configuration file's, asked when blank (with the
    # columns each one covers), y without questions.
    $rows = $null
    foreach ($key in (Get-SwitchKeys)) {
        if (Test-Given $s $key) {
            $value = ConvertTo-YesNo ([string]$s[$key])
            if ($null -eq $value) {
                Exit-Tool $script:ExitError ($key + ' must be y or n, not "' + $s[$key] + '" (config\anonymization.ini). Nothing was changed.')
            }
            $s[$key] = $value
            continue
        }
        if (-not $interactive) { $s[$key] = 'y'; continue }
        if ($null -eq $rows) {
            $rows = Read-InventoryCsv (Join-Path $script:ConfigDir 'inventory_op.csv') 'BASE'
            $custom = Get-CustomInventoryPath $s
            if (Test-Path -LiteralPath $custom) { $rows = $rows + (Read-InventoryCsv $custom 'CUSTOM') }
            Write-Ask 'What is anonymized'
            Write-Out '   config\anonymization.ini leaves these switches blank. Free text is always emptied.'
        }
        $category = $key -replace '^ANONYMIZE_', '' -replace '_(DESCRIPTION|ATTRIBUTES)$', ''
        $name = $script:CategoryNames[$category]
        if ($key -match '_DESCRIPTION$' -or $key -match '_ATTRIBUTES$') {
            $rule = 'SELF_CODE'
            $what = 'attributes'
            if ($key -match '_DESCRIPTION$') { $rule = 'DESCRIPTION'; $what = 'labels' }
            $columns = Get-SwitchColumns $rows $rule $category
            Write-Out ('   ' + $name + ', ' + $what + ' - the columns it covers:')
            if ($columns.Count -eq 0) { Write-Out '       none in the inventory: nothing would change' 'DarkGray' }
            foreach ($c in $columns) { Write-Out ('       ' + $c) 'DarkGray' }
            $s[$key] = Read-YesNoAnswer ('Mask ' + $name.ToLowerInvariant() + ' ' + $what)
        } else {
            $s[$key] = Read-YesNoAnswer ('Rename ' + $name.ToLowerInvariant() + ' codes')
        }
    }

    # Settings with a default, never asked.
    $defaults = @{ 'APPROVE_STRUCTURE_ONLY_ACCOUNTS' = 'y'; 'PARALLEL_DEGREE' = '4'; 'FAIL_ON_MISSING_OBJECT' = 'n';
                   'CUSTOM_INVENTORY' = 'inventory_op_custom.csv' }
    foreach ($key in $defaults.Keys) {
        if (-not (Test-Given $s $key)) { $s[$key] = $defaults[$key] }
    }
    foreach ($key in @('APPROVE_STRUCTURE_ONLY_ACCOUNTS', 'FAIL_ON_MISSING_OBJECT')) {
        $value = ConvertTo-YesNo ([string]$s[$key])
        if ($null -eq $value) { Exit-Tool $script:ExitError ($key + ' must be y or n, not "' + $s[$key] + '".') }
        $s[$key] = $value
    }
    $parallel = 0
    if (-not [int]::TryParse([string]$s['PARALLEL_DEGREE'], [ref]$parallel) -or $parallel -lt 1 -or $parallel -gt 32) {
        Exit-Tool $script:ExitError ('PARALLEL_DEGREE must be a whole number from 1 to 32, not "' + $s['PARALLEL_DEGREE'] + '".')
    }
    if ([string]$s['CUSTOM_INVENTORY'] -match '[\\/:]') {
        Exit-Tool $script:ExitError ('CUSTOM_INVENTORY names a file in config\, not a path: "' + $s['CUSTOM_INVENTORY'] + '".')
    }
    return $s
}

# Connects as SYS and as OP, before anything else: a wrong alias or password
# is a line here, not an error later. A password refused at a question is
# asked again (three times at most).
function Connect-Database {
    param([hashtable]$Settings, [bool]$Interactive)
    $tns = [string]$Settings['ORACLE_SID']
    $logins = @{}
    foreach ($who in @('SYS', 'OP')) {
        $secret = $null
        if ($Settings.ContainsKey('_' + $who + '_SECRET')) { $secret = $Settings['_' + $who + '_SECRET'] }
        else { $secret = ConvertTo-Secure ([string]$Settings[$who + '_PASSWORD']) }
        $attempt = 0
        while ($true) {
            $attempt++
            $login = New-Login $who.ToLowerInvariant() $secret $tns -Sysdba:($who -eq 'SYS')
            Show-Status ('   Database           connecting as ' + $who + ' to ' + $tns)
            $test = Test-Login $login
            if ($test.Ok) {
                $logins[$who] = [pscustomobject]@{ Login = $login; Test = $test }
                break
            }
            $refused = $test.Error -match 'ORA-01017|ORA-01005'
            Write-Out ('   ' + 'Database'.PadRight(19) + 'the connection as ' + $who + ' to ' + $tns + ' failed: ' + $test.Error) 'Red'
            if ($refused -and $Interactive -and $attempt -lt 3) {
                $secret = Read-Password ($who + ' password (again)')
                continue
            }
            $hint = 'Check the database alias (ORACLE_SID in config\anonymization.ini) and that the database is open.'
            if ($refused) { $hint = 'Check the ' + $who + ' password.' }
            Exit-Tool $script:ExitError ($hint + ' Nothing was changed.')
        }
    }
    return $logins
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

function Invoke-Main {
    $cli = Read-Arguments $script:CliArgs
    if ($cli.NoColor) { $script:UseColor = $false }
    if ($cli.Help) { Show-Help; exit $script:ExitPass }
    if ($null -ne $cli.Inventory) { Invoke-InventoryOnly $cli.Inventory }
    $script:Verbose = $cli.Verbose
    $script:StatusLine = -not [Console]::IsOutputRedirected
    $version = Get-ToolVersion
    $mode = 'run'
    if ($cli.DryRun) { $mode = 'dry run' }

    $left = ' OP Anonymization ' + $version
    Write-Out ''
    Write-Out ($left + $mode.PadLeft([Math]::Max(1, $script:Width - $left.Length))) 'White'
    Write-Out (' ' + ('-' * ($script:Width - 1)))
    Write-Out ''
    Write-Out ' Getting ready' 'White'
    $readyStarted = Get-Date

    $script:SqlPlus = Find-SqlPlus
    if ($null -eq $script:SqlPlus) {
        Write-Out ('   ' + 'sqlplus'.PadRight(19) + 'not found') 'Red'
        Exit-Tool $script:ExitError ('sqlplus.exe is neither in PATH nor in ORACLE_HOME\bin. Install the Oracle client, or add its bin folder to PATH.')
    }
    Write-Kv 'sqlplus' $script:SqlPlus

    $file = Read-ConfigFile $script:ConfigFile
    $configText = 'config\anonymization.ini'
    if ($null -eq $file) {
        if ($cli.Auto) { Exit-Tool $script:ExitError ('/auto needs config\anonymization.ini, and there is none: ' + $script:ConfigFile) }
        $configText = 'none (config\anonymization.ini): every value is asked for'
    }
    $fromEnv = @(@('ANON_SYS_PASSWORD', 'ANON_OP_PASSWORD') | Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) })
    if ($fromEnv.Count -gt 0) { $configText = $configText + '; passwords from the environment' }
    Write-Kv 'Configuration' $configText
    $settings = Get-Settings $cli $file

    Enable-StopKey
    try {
        Invoke-Run $cli $settings $version $readyStarted
    } finally {
        Clear-Status
        Stop-Children
        Disable-StopKey
    }
}

# Runs the anonymization, or its dry run, from getting ready to its report.
function Invoke-Run {
    param($Cli, [hashtable]$Settings, [string]$Version, [datetime]$ReadyStarted)
    $dry = [bool]$Cli.DryRun
    $tns = [string]$Settings['ORACLE_SID']
    $logins = Connect-Database $Settings (-not $Cli.Auto)
    $sysTest = $logins['SYS'].Test
    $oracle = $sysTest.Version -replace '^(\d+\.\d+).*$', '$1'
    Write-Kv 'Database' ($tns + ': connected as SYS and as OP (Oracle ' + $oracle + ')')

    $script:Run = New-RunState $Settings $Version $dry $tns $sysTest.Database
    $state = $script:Run

    # ANON_META, created or brought up to date (as SYS).
    $started = Get-Date
    $prepare = Invoke-SqlScript $logins['SYS'].Login 'SYS' @('WHENEVER SQLERROR EXIT FAILURE',
        (Get-ScriptLine (Join-Path $script:SqlDir '10_create_metadata_schema.sql') @($Settings['TABLESPACE_DATA'], $Settings['TABLESPACE_INDEX'])),
        'EXIT SUCCESS') { Show-Status ('   Metadata           ANON_META ' + (Format-Clock ((Get-Date) - $started).TotalSeconds)) }
    $state.Prepare = $prepare.Lines
    $state.Report.AddRange([string[]]$prepare.Lines)
    Show-Lines $prepare.Lines -Detail
    if ($prepare.ExitCode -ne 0) {
        Write-Out ('   ' + 'Metadata'.PadRight(19) + 'ANON_META could not be prepared:') 'Red'
        foreach ($line in @($prepare.Lines | Where-Object { $_ -match 'ORA-\d{5}|SP2-\d{4}' } | Select-Object -First 5)) { Write-Out ('     ' + $line) 'Red' }
        Exit-Tool $script:ExitError 'Nothing in OP was changed.'
    }
    $what = 'up to date'
    if (@($prepare.Lines | Where-Object { $_ -match '^\s+created user anon_meta' }).Count -gt 0) { $what = 'created now' }
    elseif (@($prepare.Lines | Where-Object { $_ -match '^\s+(migrated|created anon_meta|dropped)' }).Count -gt 0) { $what = 'upgraded' }
    Write-Kv 'Metadata' ('ANON_META on tablespace ' + $Settings['TABLESPACE_DATA'] + ': ' + $what + ' (' + (Format-Clock ((Get-Date) - $started).TotalSeconds) + ')')
    if ($script:StopAsked) { Exit-Tool $script:ExitStopped 'Stopped before the run began. Nothing in OP was changed.' }

    # The worker session (as OP): the engine, the inventory, then the run.
    $started = Get-Date
    $worker = Open-Session $logins['OP'].Login 'worker'
    if (-not $worker.Ok) { Exit-Tool $script:ExitError ('The worker session did not connect as OP: ' + $worker.Error) }
    $state.Worker = $worker
    $lines = Invoke-SessionCommand $worker @((Get-ScriptLine (Join-Path $script:SqlDir '30_install_engine.sql')),
                                             (Get-ScriptLine (Join-Path $script:RunSqlDir 'engine.sql'))) {
        Show-Status ('   Engine             installing ' + (Format-Clock ((Get-Date) - $started).TotalSeconds)) }
    $state.Report.AddRange([string[]]@($lines | Where-Object { $_ -notmatch '^ANON_' }))
    Show-Lines $lines -Detail
    $engine = @($lines | Where-Object { $_ -match '^ANON_ENGINE\|VALID\|VALID\|.+$' } | Select-Object -First 1)
    if ($engine.Count -eq 0) {
        Write-Out ('   ' + 'Engine'.PadRight(19) + 'it did not compile:') 'Red'
        foreach ($line in @($lines | Where-Object { $_ -match 'PLS-|ORA-|SP2-|LINE/COL|^\d+/\d+' } | Select-Object -First 8)) { Write-Out ('     ' + $line) 'Red' }
        Exit-Tool $script:ExitError 'Nothing in OP was changed.'
    }
    Write-Kv 'Engine' ('version ' + $engine[0].Split('|')[3] + ' (installed, ' + (Format-Clock ((Get-Date) - $started).TotalSeconds) + ')')
    if ($script:StopAsked) { Exit-Tool $script:ExitStopped 'Stopped before the run began. Nothing in OP was changed.' }

    # The inventory: the CSVs as INSERT statements on the worker's input, in
    # parts, then validated.
    $started = Get-Date
    $baseRows = Read-InventoryCsv (Join-Path $script:ConfigDir 'inventory_op.csv') 'BASE'
    $customPath = Get-CustomInventoryPath $Settings
    $customRows = @()
    if (Test-Path -LiteralPath $customPath) { $customRows = Read-InventoryCsv $customPath 'CUSTOM' }
    $state.InventorySql = New-InventorySql $baseRows $customRows
    $loadErrors = @()
    $sql = @($state.InventorySql)
    for ($i = 0; $i -lt $sql.Count; $i += 100) {
        $part = $sql[$i..([Math]::Min($i + 99, $sql.Count - 1))]
        $out = Invoke-SessionCommand $worker (@('WHENEVER SQLERROR CONTINUE') + $part)
        $loadErrors += @($out | Where-Object { $_ -match 'ORA-\d{5}|SP2-\d{4}' })
    }
    $lines = Invoke-SessionCommand $worker @((Get-ScriptLine (Join-Path $script:SqlDir '21_validate_inventory.sql')),
                                             (Get-ScriptLine (Join-Path $script:RunSqlDir 'inventory.sql')))
    $state.Report.AddRange([string[]]@($lines | Where-Object { $_ -notmatch '^ANON_' }))
    Show-Lines $lines -Detail
    $inv = @($lines | Where-Object { $_ -like 'ANON_INVENTORY|*' } | Select-Object -First 1)
    $invalid = @($lines | Where-Object { $_ -match '^\s+INVALID|ORA-\d{5}' })
    if ($loadErrors.Count -gt 0 -or $invalid.Count -gt 0 -or $inv.Count -eq 0) {
        # Each INVALID line of 21_validate_inventory.sql is followed by the
        # reason, indented.
        Write-Out ('   ' + 'Inventory'.PadRight(19) + 'it cannot be used as written:') 'Red'
        $shown = @($loadErrors)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s+INVALID') {
                $shown += $lines[$i].Trim()
                if ($i + 1 -lt $lines.Count) { $shown += ('  ' + $lines[$i + 1].Trim()) }
            } elseif ($lines[$i] -match 'ORA-\d{5}') {
                $shown += $lines[$i].Trim()
            }
        }
        foreach ($line in @($shown | Select-Object -First 16)) { Write-Out ('     ' + $line) 'Red' }
        Exit-Tool $script:ExitError 'Correct the inventory (config\inventory_op_custom.csv for a site row). Nothing in OP was changed.'
    }
    $f = $inv[0].Split('|')
    $state.Inventory = [pscustomobject]@{ Items = [int]$f[1]; Shipped = [int]$f[2]; Site = [int]$f[3]; Here = [int]$f[4];
                                          NotHere = [int]$f[5]; TablesNotHere = [int]$f[6]; ColumnsNotHere = [int]$f[7] }
    $text = (Format-Count $state.Inventory.Items) + ' items (' + (Format-Count $state.Inventory.Shipped) + ' shipped, ' +
            $state.Inventory.Site + ' of this site): ' + (Format-Count $state.Inventory.Here) + ' in this database'
    if ($state.Inventory.NotHere -gt 0) {
        Write-Kv 'Inventory' ($text + ',')
        Write-Out ((' ' * 22) + (Format-Count $state.Inventory.NotHere) + ' not here (they are skipped)')
    } else {
        Write-Kv 'Inventory' $text
    }
    if ($script:StopAsked) { Exit-Tool $script:ExitStopped 'Stopped before the run began. Nothing in OP was changed.' }

    Show-Switches $Settings
    $state.Durations.Add([pscustomobject]@{ Key = 'READY'; Text = 'Getting ready'; Status = 'DONE';
                                             Seconds = ((Get-Date) - $ReadyStarted).TotalSeconds })

    # The run begins: its id, its folder, the monitor session.
    Write-Out ''
    if ($dry) { Write-Out ' Dry run: what a run would change. Nothing is changed.' }
    else { Write-Out (' Run: anonymization of OP on ' + $tns + '.') }
    $runMode = 'EXECUTE'
    if ($dry) { $runMode = 'DRYRUN' }
    $startArgs = @($runMode) + @((Get-SwitchKeys) | ForEach-Object { $Settings[$_] }) +
                 @($Settings['PARALLEL_DEGREE'], $Settings['FAIL_ON_MISSING_OBJECT'], $Settings['APPROVE_STRUCTURE_ONLY_ACCOUNTS'])
    $lines = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'start.sql') $startArgs))
    $result = Get-ScriptResult $lines
    $runLine = @($lines | Where-Object { $_ -like 'ANON_RUN|*' } | Select-Object -First 1)
    if ($result.Status -ne 'OK' -or $runLine.Count -eq 0) {
        Exit-Tool $script:ExitError ('The run could not be opened: ' + $result.Message + ' Nothing in OP was changed.')
    }
    $state.RunId = [long]($runLine[0].Split('|')[1])
    $state.Folder = New-RunFolder $state.RunId
    Write-RunFile $state.Folder 'inventory.sql' $state.InventorySql
    Write-Out (' Run ' + (Get-RunLabel $state.RunId) + '   ' + (Format-Folder $state.Folder))

    $monitor = Open-Session $logins['OP'].Login 'monitor'
    if ($monitor.Ok) {
        $state.Monitor = $monitor
    } else {
        $state.Live = $false
        Write-Out (' The live view is not available (' + $monitor.Error + '): the steps are shown as they end.') 'Yellow'
    }

    $status = 'FAILED'
    $verifyCode = $null
    $verifyLines = @()
    try {
        $status = Invoke-RunSteps $state $Cli
        if ($status -eq 'COMPLETED' -and -not $dry) {
            $verify = Invoke-Verification $state $logins['OP'].Login
            $verifyCode = $verify.ExitCode
            $verifyLines = $verify.Lines
        }
    } catch {
        Write-Out (' ' + $_.Exception.Message) 'Red'
        Write-Log ($_.ScriptStackTrace)
        $status = 'FAILED'
        if ($null -ne $state.Worker -and $state.Worker.Ended) { $status = Repair-Run $state 'FAILED' }
    }

    # The figures of the run, read from what it recorded: in the monitor
    # session, or in a session of their own when the monitor is not there.
    $results = @()
    $resultsScript = Get-ScriptLine (Join-Path $script:RunSqlDir 'results.sql') @([string]$state.RunId)
    try {
        if ($null -ne $state.Monitor -and -not $state.Monitor.Ended) {
            $results = Invoke-SessionCommand $state.Monitor @($resultsScript) -TimeoutS 900
        } else {
            $results = (Invoke-SqlScript $logins['OP'].Login 'results' @($resultsScript)).Lines
        }
    } catch {
        Write-Out (' The figures of the run could not be read: ' + $_.Exception.Message) 'Yellow'
    }
    $state.Results = ConvertFrom-Results $results
    Close-Session $state.Monitor
    Close-Session $state.Worker

    Write-RunFile $state.Folder 'results.txt' @($results | Where-Object { $_ -like 'ANON_R_*' })
    Write-RunFile $state.Folder 'report.txt' $state.Report.ToArray()
    if ($verifyLines.Count -gt 0) { Write-RunFile $state.Folder 'verify.txt' $verifyLines }

    $end = Get-RunEnd $state $status $verifyCode
    Write-Manifest $state $status $end.Verdict $end.ExitCode
    Show-RunEnd $state $status $end
    Show-HtmlReport $state $Cli
    Write-Out ('  Files    ' + (Format-Folder $state.Folder) + '   (' + ((@('report.txt') + @(if ($verifyLines.Count -gt 0) { 'verify.txt' }) + @('console.log')) -join ', ') + ')') 'DarkGray'
    Write-Out ('  Exit code ' + $end.ExitCode + ': ' + $end.Words + '.') $end.Color
    Stop-Children
    Disable-StopKey
    exit $end.ExitCode
}

# The steps of the run after it was opened: checks and plan, then the count
# of a dry run, or the confirmation, the translations and the work of a run.
# Returns the status the run ended with.
function Invoke-RunSteps {
    param($State, $Cli)
    $dry = $State.DryRun
    if ($dry) {
        Start-Flow @([pscustomobject]@{ Key = 'CHECK'; Text = 'Checking and planning (read-only)'; Header = $false },
                     [pscustomobject]@{ Key = 'COUNT'; Text = 'Counting what a run would change'; Header = $true })
    } else {
        Start-Flow @([pscustomobject]@{ Key = 'CHECK'; Text = 'Checking and planning (read-only)'; Header = $false },
                     [pscustomobject]@{ Key = 'RECORD'; Text = 'Recording the translations'; Header = $false },
                     [pscustomobject]@{ Key = 'APPLY'; Text = 'Anonymizing'; Header = $true },
                     [pscustomobject]@{ Key = 'VERIFY'; Text = 'Verifying (read-only)'; Header = $false })
    }

    # 1. Checks and plan.
    Start-FlowStep 'CHECK'
    $lines = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'plan.sql')))
    Update-LiveView
    $result = Get-ScriptResult $lines
    $State.Checks = ConvertFrom-CheckLines $lines
    $State.Plan = ConvertFrom-PlanLines $lines
    if ($result.Status -eq 'FAILED') {
        Complete-FlowStep 'FAILED'
        Write-FlowError $result.Message
        if ($State.Worker.Ended) { return (Repair-Run $State 'FAILED') }
        return 'FAILED'
    }
    Complete-FlowStep 'done'
    if ($null -ne $State.Plan.Identities) {
        $i = $State.Plan.Identities
        Write-Out ('         ' + (Format-Count ($i.Parties + $i.Accounts)) + ' identities: ' + (Format-Count $i.Parties) +
                   ' parties, ' + (Format-Count $i.Accounts) + ' bank accounts')
    }
    Show-Checks $State.Checks $dry
    if ($result.Status -eq 'REFUSED') {
        $State.Refusal = $result
        return 'REFUSED'
    }
    if ($script:StopAsked) { return (Stop-Run) }

    if ($dry) {
        # 2. What a run would change.
        Start-FlowStep 'COUNT'
        if ($script:StopKeys) { Write-FlowNote 'Ctrl+C stops the count after the table or column it works on.' 'DarkGray' }
        $State.Working = $true
        $lines = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'count.sql')))
        $State.Working = $false
        Update-LiveView
        $result = Get-ScriptResult $lines
        Complete-Kinds $result.Status
        Complete-FlowStep (Get-StepWord $result.Status)
        if ($result.Status -eq 'FAILED') { Write-FlowError $result.Message }
        if ($State.Worker.Ended -and $result.Status -eq 'FAILED') { return (Repair-Run $State 'FAILED') }
        return $result.Status
    }

    # The confirmation: after the checks, with what the run will do.
    Show-ReadyBanner $State
    if (-not $Cli.Force) {
        $answer = Read-Prompt 'Type YES to start'
        if ($null -eq $answer -or $answer.Trim().ToUpperInvariant() -ne 'YES') {
            Write-Log (' > Type YES to start: ' + [string]$answer)
            $null = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'finish.sql') @('CANCELLED')))
            return 'CANCELLED'
        }
        Write-Log ' > Type YES to start: YES'
        Write-Out ''
    }

    # 2. The translations, recorded before anything in OP changes.
    Start-FlowStep 'RECORD'
    $lines = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'record.sql')))
    Update-LiveView
    $result = Get-ScriptResult $lines
    if ($result.Status -ne 'OK') {
        Complete-FlowStep (Get-StepWord $result.Status)
        if ($result.Status -eq 'FAILED') { Write-FlowError $result.Message }
        if ($State.Worker.Ended) { return (Repair-Run $State 'FAILED') }
        return $result.Status
    }
    $new = 0
    foreach ($s in $State.Steps) { if ($s.Phase -eq 'MAPPING' -and $s.Status -eq 'OK') { $new += $s.Rows } }
    Complete-FlowStep 'done'
    Write-Out ('         ' + (Format-Count $new) + ' new translations recorded')
    if ($script:StopAsked) { return (Stop-Run) }

    # 3. The work.
    Start-FlowStep 'APPLY'
    if ($script:StopKeys) { Write-FlowNote 'Ctrl+C stops safely after the table or column it works on. Do not close this window.' 'DarkGray' }
    $State.Working = $true
    $lines = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'apply.sql')))
    $State.Working = $false
    Update-LiveView
    $result = Get-ScriptResult $lines
    Complete-Kinds $result.Status
    if ($State.Worker.Ended -and $result.Status -eq 'FAILED') {
        Complete-FlowStep 'FAILED'
        return (Repair-Run $State 'FAILED')
    }
    Complete-FlowStep (Get-StepWord $result.Status)
    if ($result.Status -eq 'FAILED') { Write-FlowError $result.Message }
    return $result.Status
}

# A stop asked for between two steps, before the work began: the run ends
# STOPPED, nothing in OP changed.
function Stop-Run {
    $null = Invoke-Worker @((Get-ScriptLine (Join-Path $script:RunSqlDir 'finish.sql') @('STOPPED')))
    return 'STOPPED'
}

# The worker session was lost while the run was RUNNING (run/recover.sql in
# the monitor session): while the run's own database session is still there,
# its call goes on and ends the run by itself; otherwise the run is recorded
# FAILED and, when it had disabled the triggers of OP, they are enabled again.
function Repair-Run {
    param($State, [string]$Status)
    $byHand = 'op\sql\run\recover.sql ' + $State.RunId
    if ($null -eq $State.Monitor -or $State.Monitor.Ended -or $State.RunId -eq 0) {
        Write-Out (' The run could not be checked. Once it has ended, run ' + $byHand + ' as OP: it enables the triggers of OP again if needed.') 'Red'
        return $Status
    }
    try {
        $lines = Invoke-SessionCommand $State.Monitor @((Get-ScriptLine (Join-Path $script:RunSqlDir 'recover.sql') @([string]$State.RunId))) -TimeoutS 300
        foreach ($line in $lines) {
            if ($line -match '^ANON_RECOVER\|ACTIVE\|') {
                Write-Wrapped '         ' ('The worker session was lost, but the run still works in the database: it ends by itself and enables the triggers of OP again. anon_meta.anon_run says when; then a new run resumes.') 'Yellow'
            } elseif ($line -match '^ANON_RECOVER\|ENDED\|(\d+)\|(\d+)\|') {
                $what = 'the run is recorded as failed'
                if ([int]$Matches[2] -gt 0) { $what = $what + ', and ' + $Matches[2] + ' triggers of OP were enabled again' }
                Write-Wrapped '         ' ('The worker session was lost: ' + $what + '.') 'Yellow'
            }
        }
    } catch {
        Write-Out (' The run could not be checked: ' + $_.Exception.Message + ' Once it has ended, run ' + $byHand + ' as OP.') 'Red'
    }
    return $Status
}

# 4. The verification of a completed run, in a session of its own, with its
# progress meanwhile.
function Invoke-Verification {
    param($State, $Login)
    Start-FlowStep 'VERIFY'
    $State.Verifying = $true
    $onWait = { Update-LiveView 'VERIFY' }
    $result = Invoke-SqlScript $Login 'verifier' @((Get-ScriptLine $script:VerifySql)) $onWait
    $State.Verifying = $false
    Update-LiveView 'VERIFY'
    if (@(0, 2, 3, 4) -contains $result.ExitCode) {
        Complete-FlowStep 'done'
    } else {
        Complete-FlowStep 'FAILED'
        $line = @($result.Lines | Where-Object { $_ -match 'ORA-\d{5}|SP2-\d{4}' } | Select-Object -First 1)
        if ($line.Count -gt 0) { Write-FlowError ('The verification could not run: ' + $line[0].Trim()) }
    }
    return $result
}

try {
    Invoke-Main
} catch {
    Clear-Status
    Write-Out (' ' + $_.Exception.Message) 'Red'
    Write-Log ($_.ScriptStackTrace)
    Stop-Children
    Disable-StopKey
    exit $script:ExitError
}
