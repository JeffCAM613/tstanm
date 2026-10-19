<#
============================================================================
 make_release.ps1 - build the distributable zip
============================================================================
   powershell -ExecutionPolicy Bypass -File tools\make_release.ps1

 Writes ..\Anonymization_v4_<yyyyMMdd>.zip beside the project folder.

 The contents are an EXPLICIT INCLUDE LIST, never a copy-with-exclusions.
 A release that ships a file nobody meant to ship is the failure worth
 designing against, and an allow-list fails closed: a new file is absent
 from the zip until someone adds it here, which is a visible mistake. An
 exclude-list fails open, which is a silent one.

 Deliberately absent, and why:

   config/anonymization.ini   the filled-in file - real SID, possibly real
                              passwords. The template ships instead.
   op/logs/                   run output: instance names, row counts,
                              anything the database wrote to stderr
   unofficial docs/           the rebuild's working notes, including a test
                              log naming a real instance
   epf/                       not ported to v4; nothing to run
   tests/manual/*.txt         terminal transcripts from a real database
   tools/build_docs.js        maintainer tool; its outputs are shipped
   tools/make_release.ps1     this file
============================================================================
#>

[CmdletBinding()]
param(
   [string] $OutDir,
   [string] $Version
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside a param() default,
# so the defaults are settled here instead.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $here '..')
if (-not $OutDir)  { $OutDir  = (Resolve-Path (Join-Path $here '..\..')).Path }
if (-not $Version) { $Version = (Get-Date -Format 'yyyyMMdd') }

# ---------------------------------------------------------------- contents --
# Paths are relative to Anonymization_v4\ and may name a file or a directory.
$include = @(
   'README.md',

   # the two guides, in all three formats
   'docs/OP_User_Guide.md',
   'docs/OP_User_Guide.html',
   'docs/OP_User_Guide.docx',
   'docs/OP_Technical_Guide.md',
   'docs/OP_Technical_Guide.html',
   'docs/OP_Technical_Guide.docx',

   # settings and coverage - the template, never the filled-in file
   'config/anonymization.template.ini',
   'config/inventory_op.csv',
   'config/inventory_op_custom.csv',

   # the run itself
   'op/run_op_anonymization.bat',
   'op/sql/00_run_op_anonymization.sql',
   'op/sql/10_create_metadata_schema.sql',
   'op/sql/21_validate_inventory.sql',
   'op/sql/30_install_engine.sql',
   'op/verify/verify_op_coverage.sql',
   'op/verify/generate_report.sql',

   # optional analysis - see tools/README.md before sharing their output
   'tools/README.md',
   'tools/generate_coverage_doc.sql',
   'tools/analyze_flag_impact.sql',
   'tools/scan_for_leaks.sql',

   # ad-hoc helpers the guides refer to
   'tests/README.md',
   'tests/manual/monitor_op_progress.sql',
   'tests/manual/row_counts.sql',
   'tests/manual/check_tables_exist.sql',
   'tests/manual/check_locks.sql',
   'tests/manual/inspect_code_map.sql',
   'tests/manual/typed_identity_diagnostics.sql'
)

# ------------------------------------------------------------------ staging --
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("anonrel_" + [guid]::NewGuid().ToString('N'))
$top   = Join-Path $stage 'Anonymization_v4'
New-Item -ItemType Directory -Path $top -Force | Out-Null

$missing = @()
foreach ($rel in $include) {
   $src = Join-Path $root ($rel -replace '/', '\')
   if (-not (Test-Path -LiteralPath $src)) { $missing += $rel; continue }
   $dst = Join-Path $top ($rel -replace '/', '\')
   New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
   Copy-Item -LiteralPath $src -Destination $dst -Force
}

if ($missing.Count) {
   Remove-Item -LiteralPath $stage -Recurse -Force
   throw ("Missing from the working tree, so the release would be incomplete:`n  " +
          ($missing -join "`n  "))
}

# op\logs is created by the batch on first run, but shipping it empty makes the
# layout obvious and gives the report somewhere to land.
New-Item -ItemType Directory -Path (Join-Path $top 'op\logs') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $top 'op\logs\.keep') -Encoding utf8 -Value @(
   'Run logs and HTML coverage reports are written here.'
)

# ------------------------------------------------------------------- verify --
# Cheap belt-and-braces: nothing in the staged tree should look like the live
# configuration or a captured run.
$suspect = Get-ChildItem -LiteralPath $top -Recurse -File |
           Where-Object { $_.Name -eq 'anonymization.ini' -or $_.Extension -in '.log', '.txt' } |
           Where-Object { $_.Name -ne '.keep' }
if ($suspect) {
   Remove-Item -LiteralPath $stage -Recurse -Force
   throw ("Refusing to package - these should not be in a release:`n  " +
          (($suspect | ForEach-Object FullName) -join "`n  "))
}

# ---------------------------------------------------------------- packaging --
$zip = Join-Path (Resolve-Path $OutDir) ("Anonymization_v4_$Version.zip")
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Entries are added one at a time with explicit forward slashes. Neither
# CreateFromDirectory nor Compress-Archive can be trusted here: on .NET
# Framework they write entry names with a backslash separator, which the ZIP
# spec does not allow. Windows tools cope; macOS and Linux may not, and a
# release that only unpacks on the machine that built it is not a release.
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
   foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName) {
      $name = $f.FullName.Substring($stage.Length).TrimStart('\') -replace '\\', '/'
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
         $archive, $f.FullName, $name,
         [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
   }
} finally {
   $archive.Dispose()
}

Remove-Item -LiteralPath $stage -Recurse -Force

$size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB)
Write-Output ""
Write-Output ("  {0}" -f $zip)
Write-Output ("  {0} files, {1} KB" -f ($include.Count + 1), $size)
Write-Output ""
