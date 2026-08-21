# Architecture & Internals

## Module Map

```
lua/neorg-project-manager/
├── init.lua        Entry point, setup, commands, orchestration
├── config.lua      Shared config storage (get/set)
├── helpers.lua     Tree-sitter utilities, link patterns, sorting, scandir
├── numbering.lua   Number formatting, parsing, stable renumbering
├── hop.lua         Link resolution (<CR> override)
├── sections.lua    Generic section detection engine (list + value fields)
├── prereqs.lua     Prerequisite tracking virtual text (uses sections.lua)
├── outcomes.lua    Outcome/deliverable tracking virtual text (uses sections.lua)
├── fields.lua      Owner/Effort extraction, aggregation (uses sections.lua)
├── mixed.lua       Mixed-type progress virtual text
├── project.lua     Project root detection, file scanning
├── index.lua       Cross-file index with lazy loading + caching
├── status.lua      Status tree generation and surgical updates
├── rename.lua      Project-wide file/dir renaming
├── fold.lua        Fold expression + toggle for status files
├── extract.lua     Extract heading into its own .norg file
├── promote.lua     Promote list items to subsections (:NeorgPMPromote)
├── breadcrumb.lua  Heading path display (statusline/winbar/virtual text)
├── picker.lua      Browse/filter project items by status/owner
├── bidir.lua       Bidirectional status propagation
├── scaffold.lua    Project initialization (:NeorgPMInit)
└── health.lua      :checkhealth integration
```

Key design principle: modules access config through `config.lua` (never
store their own copy), and share tree-sitter utilities through `helpers.lua`.

## Project Structure

| File / Dir | Purpose |
|-----------|---------|
| `<number>. <title>.norg` (root) | Root status file — project marker + overview |
| `<number>. <title>.norg` (in subdir) | Per-directory status summary (direct children) |
| `<number>. <title>.norg` (content) | Content file (headings get prefix-aware numbers) |
| `<number>. <title>/` | Numbered directory (groups related files) |

### Status file detection

A "status file" is detected by `project.find_status_file(dir)`:
- At the project root: the `.norg` file whose prefix has depth 1 (e.g., `42. ACME App.norg`)
- In subdirectories: the `.norg` file whose prefix matches the directory's prefix

There is no hardcoded `project.norg` or `index.norg` filename — detection
is purely by numbered prefix convention.

### How numbers work

The number in a filename is the file's **prefix**. Headings inside the file
continue from that prefix:

```
File: "1.1.3.1. Stage 1.norg"  (prefix = 1.1.3.1)

* (-) 1.1.3.1.1. Design        <- prefix + .1
* (x) 1.1.3.1.2. Back end      <- prefix + .2
** (x) 1.1.3.1.2.1. Endpoint   <- prefix + .2.1
```

Numbers with `numbering_styles` are indexed by **total depth** (prefix depth +
heading level), ensuring consistent formatting regardless of file nesting.

### Stable numbering

The `renumber(buf)` function uses a two-pass stable algorithm:

1. **Pass 1 (collect):** Walks all headings, validates existing numbers
   (correct depth + parent prefix match), builds per-parent sets of used
   counter values, and detects duplicates.

2. **Pass 2 (assign):** For each unnumbered/invalid heading, finds the
   next free counter value after its predecessor sibling under the same
   parent. Fills gaps when available (e.g., between 1.1 and 1.3 → assigns
   1.2). Falls back to max+1 when no gap exists.

**Guarantees:**
- Existing valid numbers are never modified
- Running renumber twice is idempotent
- Gaps in numbering are allowed and preserved (a deleted heading's number
  is never auto-reclaimed)
- Cross-file `{* number}` links remain valid after renumber

### Depth limits

Norg supports 6 heading levels (`*` through `******`). Multi-file projects
combine prefix depth + heading levels for unlimited total depth:

```
Single file: max 6 levels
Multi-file: prefix depth 4 + 6 heading levels = depth 10
```

If you need a 7th `*` level, split into a companion file.

## State Aggregation

### Rules

Parent states are computed from children — never set manually:

| Children | Parent becomes | Notes |
|----------|----------------|-------|
| All done | `(x)` | |
| Some done or pending | `(-)` | |
| None done | `( )` | |
| All on-hold | `(=)` | |
| All cancelled | `(_)` | Cancelled excluded from active pool |
| All ambiguous | `(?)` | |

### Cancelled exclusion

Cancelled `(_)` children are removed from the active pool entirely.
Progress counts `[done/total]` reflect only active items.

Example: 2 done + 1 cancelled → `(x) [2/2]`, not `(-) [2/3]`.

### Ambiguous propagation

If any active child has `(?)` as its primary state or as a qualifier,
the parent receives `?` as a qualifier — e.g., `(?|-)` (pending with
ambiguity). If ALL active children are ambiguous, the parent becomes
`(?)` directly (no qualifier needed).

### Important (local-only)

`(!)` marks individual items for attention but does not propagate upward.
For aggregation purposes, important items count as "undone".

## Compound Status Markers

Norg supports multiple extensions separated by `|` (pipe). The plugin
uses this to combine a primary state with qualifiers.

### Valid combinations

- `(?|-)` — in progress + uncertain
- `(=|?)` — on hold + uncertain
- `(!|-)` — in progress + urgent (local, doesn't propagate)
- `(x|?)` — done + uncertain (rare)

Only `?` (ambiguous) and `!` (important) are valid qualifiers. Two primary
states together (e.g., `(=|-)`) are not valid compounds — they would be
treated as just the first primary found, with the second silently discarded.

### Role-based parsing

The plugin determines primary vs qualifier by **semantic role**, not
position in the marker:

- **Primary states:** undone, pending, done, on_hold, cancelled
- **Qualifiers:** ambiguous (`?`), important (`!`)

When reading `(?|-)`, the plugin identifies `-` as the primary (pending)
and `?` as the qualifier (ambiguous). Both `(?|-)` and `(-|?)` are treated
identically — though only `(?|-)` parses correctly.

### Parser constraint

The norg tree-sitter scanner treats `-`, `_`, and `!` as attached modifier
characters (strikethrough, underline, spoiler). These characters **cannot
appear first** in a compound marker — the scanner refuses to emit the `|`
delimiter after them.

The plugin handles this automatically when rendering:

| Combination | Renders as | Why |
|---|---|---|
| pending + ambiguous | `(?|-)` | `-` unsafe first → qualifier goes first |
| cancelled + ambiguous | `(?|_)` | `_` unsafe first → qualifier goes first |
| on_hold + ambiguous | `(=|?)` | `=` safe first → normal order |
| done + ambiguous | `(x|?)` | `x` safe first → normal order |
| pending + important | `(!|-)` | `-` unsafe first → qualifier goes first (but `!` is also unsafe — fallback: drops qualifier, renders `-`) |

If no safe ordering exists (e.g., both primary and all qualifiers are unsafe),
the plugin falls back to rendering the primary state alone (drops qualifiers).

### Aggregation with compound states

`aggregate_state()` accepts both plain state strings and `{state, qualifiers}`
tables. It returns 4 values: `primary, done, total, qualifiers`.

Qualifiers propagate independently from the primary state:
- Child has `(?|-)` → parent gets `ambiguous` in its qualifier list
- Child has `(?)` as primary → same effect
- The propagated qualifier combines with the parent's computed primary

## Bidirectional Propagation

### Flow

1. User edits a managed heading's todo state in a status file
2. On `BufWritePre`: snapshot of all managed heading states is captured
3. File is written to disk
4. On `BufWritePost` (buffer-local, runs first):
   - Compare post-save states against snapshot
   - Any changes = user manually edited → propagate to source files
   - Re-run surgical update to refresh progress counts
5. On `BufWritePost` (global, `cross_file`):
   - `auto_update_parent_index` skips status files (circular prevention)

### Primary detection in reversed markers

The bidir module uses role-based detection: for `(?|-)`, it identifies `-`
as the primary (not `?`). This ensures correct change detection even with
reversed compound markers.

## Managed vs Manual Content

In status files:

- **Managed heading** = has a `{* number}` link → plugin updates its todo state
  and progress count automatically
- **Manual content** = no such link → never touched by the plugin

```norg
** (-) 1.1. Stage 1 {* 1.1} [2/3]    <- MANAGED (auto-updated)
** Architecture Notes                  <- MANUAL (never touched)
```

## Index and Caching

The index module (`index.lua`) provides lazy-loaded, mtime-cached heading
resolution:

1. Files are parsed on first access (not eagerly on plugin load)
2. Parsed results are cached with the file's mtime
3. On save, the cache for that file is invalidated
4. Project entry scan is cached for 5 seconds

This means opening a large project doesn't cause a startup delay — files
are only parsed when their headings are actually referenced.
