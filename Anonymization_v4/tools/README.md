# tools

Optional scripts. **None of them are needed to run the anonymization** — a run touches only
`op/`, `config/` and `op/sql/`.

They fall into two groups.

## Shipped with a release

Read-only, safe to run against an anonymized copy, and referenced from the guides.

| Script | Answers | Cost |
|---|---|---|
| `generate_coverage_doc.sql` | *What does the inventory cover, and which of it exists on this instance?* Writes `op/logs/coverage.md`. Needs the inventory loaded, which any run — including a dry run — does. | Seconds |
| `analyze_flag_impact.sql` | *If I turn a category off, which columns stop being anonymized? Does a column hold the other domain?* Measures it per column, against the identities of the latest plan (a dry run is enough). Writes `op/logs/flag_impact.md`. | Minutes |
| `scan_for_leaks.sql` | *Is the inventory itself complete?* Ignores the inventory and scans every character column in OP, whatever its width, for surviving original identifiers. | **Roughly a full run** — it reads the whole schema |

`analyze_flag_impact.sql` and `scan_for_leaks.sql` keep their results in tables they create in
`anon_meta`, so the account running them needs to be able to create tables there: run them as SYS
if OP cannot.

### Two things to know before sharing their output

**`scan_for_leaks.sql` prints real client values.** Each hit carries a `sample_value` so you can
judge whether it is a genuine leak or a coincidental collision with a currency or status code — which
means its output is exactly the thing that must not leave the site. Counts and column names are safe
to pass on; the sample column is not.

**`analyze_flag_impact.sql` prints per-column row counts**, which reveal business volumes. Its output
is git-ignored for that reason.

Both are review tools rather than operator tools. `verify_op_coverage.sql` proves the inventory was
applied correctly; `scan_for_leaks.sql` asks whether the inventory was right in the first place, which
is a data-classification question for whoever owns the schema.

## Not shipped — for maintaining this package

| Script | Purpose |
|---|---|
| `build_docs.js` | Renders `docs/*.md` to `.html` and `.docx`. Needs Node.js. The outputs are committed, so nobody receiving a release ever needs to run it. |
| `make_release.ps1` | Builds the release zip from an explicit include list: one zip for Windows and Linux, in which `unzip` keeps the shell launcher executable. |

Both are excluded from a release by `make_release.ps1` itself.
