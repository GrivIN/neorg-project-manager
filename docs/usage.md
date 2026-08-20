# Usage Guide

## Automatic Behavior

The plugin only modifies your files under specific conditions. This section
documents exactly what happens automatically and what doesn't — so there are
no surprises.

**What it does automatically:**

| Action | When it triggers | Condition |
|--------|-----------------|-----------|
| Renumber headings | On save (`:w`) | Only if file is in a project OR already has numbered headings |
| Renumber headings | Cursor leaves a modified heading line | Same as above |
| Update status files | On save of any content file in project | File must be inside a project root |
| Propagate state changes | On save of a status file with manual edits | Bidirectional propagation to source files |
| Show virtual text `[3/5]` | On file open + after edits (debounced) | `mixed_propagation = true` (default) |
| Show virtual text `[BLOCKED]` / `[READY]` | On file open + after edits (debounced) | `prerequisite_tracking = true` (default) |
| Override `<CR>` on links | Always in norg buffers | Tries number-based hop first, falls back to Neorg's native hop |

**What it does NOT do:**

- **Does NOT modify standalone unnumbered files.** If a `.norg` file has no
  numbered headings and no status file in any ancestor directory, the
  plugin leaves it completely untouched.
- **Does NOT auto-number on first open.** Headings that aren't already
  numbered stay unnumbered until you explicitly run `:NeorgPMRenumber`.
- **Does NOT delete managed headings.** If you remove a file from disk, its
  corresponding heading in the status file stays (becomes stale but isn't
  auto-removed).
- **Does NOT modify manual content.** Only headings with `{* number}` links
  are updated. Everything else is never touched.

**To disable for a specific buffer:**

```lua
vim.b.neorg_pm_disabled = true
```

**To disable auto-renumbering globally:**

```lua
require("neorg-project-manager").setup({
    renumber_on_save = false,
    renumber_on_heading_leave = false,
})
```

## Links

Reference any heading by its number using a single-star link:

```norg
{* 1.1.3.1.2}
```

The number is the full address. Press `<CR>` to jump — works within the file
and across files in the project.

## Prerequisites

Add a `Pre-requisites:` section under a heading with linked items:

```norg
**** ( ) 1.1.3.1. Stage 1
     Pre-requisites:
     - (x) {* 1.1.1} X-Code Setup
     - (x) {* 1.1.2} Build Pipeline
```

The plugin shows virtual text:
- `[BLOCKED: 1/2 prereqs done]` — some prereqs incomplete
- `[READY_FOR_IMPLEMENTATION]` — all prereqs done, item hasn't started

## Auto-update behavior

- **On save**: headings in the current file are renumbered; parent status
  files are surgically updated (states and counts only, manual content preserved)
- **On heading leave**: when you finish editing a heading line and move away,
  renumbering triggers
- **`:NeorgPMStatus`** (`<LocalLeader>ps`): updates the current status file
  buffer (surgical if content exists, full generation if empty)

## Tree fold / toggle

In status files, the tree can get large. Two toggle commands help navigate:

**`<LocalLeader>pt`** — Toggle body folds (show headings only):

```norg
** (-) 1.1. Stage 1 {* 1.1} [2/3]       <- cursor here, press <LocalLeader>pt
   Key architectural decisions:            <- body text gets hidden
   - Microservices for auth
*** (x) 1.1.1. X-Code Setup {* 1.1.1}
   Setup instructions here...              <- also hidden
```

After `pt` — all headings visible, body text hidden:

```norg
** (-) 1.1. Stage 1 {* 1.1} [2/3]
*** (x) 1.1.1. X-Code Setup {* 1.1.1}
```

Press `<LocalLeader>pt` again to reveal all descriptions.

**`<LocalLeader>pT`** — Toggle full fold (collapse everything):

After `pT` — heading + all children + body collapsed to one line:

```
** (-) 1.1. Stage 1 {* 1.1} [2/3]  [+8 lines]
```

Press `<LocalLeader>pT` again to expand everything back.

Folds start fully expanded. You can also use standard Neovim fold commands
(`zM` to close all, `zR` to open all, `zo`/`zc` for individual levels).

## Extract to file

When a heading in a status file has grown large, use `:NeorgPMExtract`
(`<LocalLeader>pe`) to extract it into its own `.norg` file.

The heading line stays in place (its `{* number}` link navigates to the new
file), and all content below it moves to the new file with heading levels
shifted to start at `*`.

**Usage:**
1. Open a status file
2. Place cursor on the heading you want to extract
3. Run `:NeorgPMExtract` or press `<LocalLeader>pe`
4. Confirm

**When to use it:**
- A section has grown too complex — give it its own file
- You want cross-file navigation
- You need deeper nesting (a file gets 6 more heading levels on top of its prefix)

## Heading breadcrumb

Shows your current position in the project hierarchy as a breadcrumb path.

**Statusline (default):** Add to your lualine config:

```lua
sections = {
    lualine_c = {
        { require("neorg-project-manager.breadcrumb").get,
          cond = function() return vim.bo.filetype == "norg" end },
    },
}
```

**Winbar:** Shows at the top of the window:

```lua
opts = { breadcrumb_display = "winbar" }
```

**Virtual text:** Shows at end of the current heading line:

```lua
opts = { breadcrumb_display = "virtual" }
```

**File-only mode** (shorter breadcrumb):

```lua
opts = { breadcrumb_project_path = false }
```

## Item picker

Browse project items with status filtering:

- `:NeorgPMPick` (`<LocalLeader>pp`) — browse all items
- `:NeorgPMPick pending` — browse only in-progress items
- `:NeorgPMPickByState` (`<LocalLeader>pP`) — choose a state to filter by, then browse
- `:NeorgPMPickByOwner` (`<LocalLeader>po`) — choose an owner to filter by, then browse

Uses `vim.ui.select` — automatically works with telescope (via dressing.nvim),
fzf-lua, or any other UI override.

## Project initialization

`:NeorgPMInit` (`<LocalLeader>pi`) creates a new project in the current
directory. Prompts for project name and starting WBS number, then creates a
numbered root status file (e.g., `1. My Project.norg`).

If a project already exists in the directory, opens its status file instead.

## Outcome tracking

The plugin detects `Outcome:` or `Outcomes:` sections under headings and
tracks deliverable completion:

```norg
*** (x) 42.1.1.4. Validation {* 42.1.1.4}
    Outcomes:
    - (x) API contract document published
    - (x) Load test report (>1000 req/s sustained)
    - ( ) Security audit sign-off
```

Virtual text shows: `[2/3 outcomes]`

If the heading is marked `(x)` done but some outcomes are not complete,
a warning appears: `[OUTCOMES INCOMPLETE]`

Configure via:
```lua
opts = {
    outcome_tracking = true,              -- enable/disable
    outcome_pattern = "Outcomes?:",       -- matches both singular and plural
    outcome_incomplete_warning = true,    -- warn on done heading + incomplete outcomes
}
```

## Metadata fields (Owner, Effort)

The plugin extracts `Owner:` and `Effort:` fields from heading descriptions.
These are available for filtering in the picker:

```norg
** (-) 42.2. [feature] Chat {* 42.2}
   Owner: @backend-team, @frontend-team
   Effort: XL (6-8 sprints across 2 stages)
```

- `:NeorgPMPickByOwner` (`<LocalLeader>po`) — filter items by owner
- Effort sizes (XS, S, M, L, XL, XXL) are parsed for aggregation

Optionally show field badges as virtual text:
```lua
opts = { field_display = "virtual" }  -- "none" (default) or "virtual"
```

## Commands

| Command | Keybind | Description |
|---------|---------|-------------|
| `:NeorgPMRenumber` | `<LocalLeader>pr` | Renumber headings + update links in the current file |
| `:NeorgPMRenumberProject` | `<LocalLeader>pR` | Renumber all project files/dirs + all links |
| `:NeorgPMStatus` | `<LocalLeader>ps` | Update status in current status file |
| `:NeorgPMStatusAll` | `<LocalLeader>pS` | Regenerate ALL status files across the project |
| `:NeorgPMToggle` | `<LocalLeader>pt` | Toggle body folds (hide descriptions, keep headings visible) |
| `:NeorgPMToggleAll` | `<LocalLeader>pT` | Toggle full fold (collapse heading with all children) |
| `:NeorgPMExtract` | `<LocalLeader>pe` | Extract heading content into its own file |
| `:NeorgPMPick` | `<LocalLeader>pp` | Browse project items (optional state filter argument) |
| `:NeorgPMPickByState` | `<LocalLeader>pP` | Browse items filtered by a chosen status |
| `:NeorgPMPickByOwner` | `<LocalLeader>po` | Browse items filtered by owner |
| `:NeorgPMInit` | `<LocalLeader>pi` | Initialize a new project with a numbered root status file |
| (automatic) | `<CR>` | Follow `{* number}` link (cross-file), falls back to Neorg hop |

Default keybinds use `<LocalLeader>` + the `keybind_prefix` (default `"p"`).
Disable with `default_keybinds = false` and map your own.

## Health Check

Run `:checkhealth neorg-project-manager` to verify:
- Neovim version >= 0.10
- norg tree-sitter parser availability
- Plugin configuration status
- Project root detection for the current file

## Configuration

All options with their defaults:

```lua
require("neorg-project-manager").setup({
    -- Feature toggles
    auto_numbering = true,
    mixed_propagation = true,
    prerequisite_tracking = true,
    cross_file = true,

    -- Triggers
    renumber_on_save = true,
    renumber_on_heading_leave = true,

    -- Anchor root headings
    anchor_root_headings = true,

    -- Numbering format
    numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
    number_separator = ".",
    number_title_separator = ". ",

    -- Custom format function (overrides styles if set)
    -- number_format = function(counters, level, prefix) return "1.1.3" end,

    -- Prerequisite detection pattern
    prereq_pattern = "Pre%-requisites:",

    -- Project settings
    project_root = nil,   -- nil = auto-detect
    file_prefix = nil,    -- nil = auto-detect from filename

    -- Virtual text appearance
    blocked_highlight = "DiagnosticWarn",
    ready_highlight = "DiagnosticOk",
    mixed_progress_highlight = "Normal",
    blocked_format = function(done, total)
        return string.format("[BLOCKED: %d/%d prereqs done]", done, total)
    end,
    ready_text = "[READY_FOR_IMPLEMENTATION]",
    mixed_format = function(done, total)
        return string.format("[%d/%d]", done, total)
    end,

    -- Rename settings
    rename_confirm_threshold = 5,

    -- Breadcrumb
    breadcrumb_display = "statusline",  -- "statusline", "winbar", "virtual", "none"
    breadcrumb_separator = " > ",
    breadcrumb_project_path = true,
    breadcrumb_format = nil,

    -- Keybinds
    default_keybinds = true,
    keybind_prefix = "p",
})
```

### Highlight groups

| Group | Default | Used for |
|-------|---------|----------|
| `NeorgPMBlocked` | `DiagnosticWarn` | `[BLOCKED: X/Y]` virtual text |
| `NeorgPMReady` | `DiagnosticOk` | `[READY_FOR_IMPLEMENTATION]` virtual text |
| `NeorgPMProgress` | `Comment` | `[3/5]` progress virtual text |

### Events

| Event Pattern | When |
|---------------|------|
| `NeorgPMAttach` | Plugin attaches to a norg buffer |
| `NeorgPMRenumber` | After renumbering completes |

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "NeorgPMRenumber",
    callback = function() print("Renumbered!") end,
})
```

### Numbering style examples

```lua
-- Default: all numeric → 1.1.3.1.2.1

-- Mixed: letters for deep levels
numbering_styles = { "numeric", "numeric", "numeric", "alpha_upper", "alpha_lower", "roman_lower" }
-- → 1.1.3.A.b.iv

-- Different separator between number and title
number_title_separator = ": "
-- → 1.1.3: My Title
```

## Tips

- Run `:NeorgPMRenumber` (`<LocalLeader>pr`) after adding or reordering headings
- Use `{* number}` links in prerequisites to track cross-file dependencies
- Keep status files open as dashboards — states update when you save content files
- The plugin works fine with a single file (no project structure needed)
- Mix manual notes freely with managed headings in status files
- Remove the `{* N}` link from a heading to "unmanage" it permanently
- Use `:NeorgPMPick` (`<LocalLeader>pp`) to browse items by status
- Use `:NeorgPMInit` (`<LocalLeader>pi`) to create a new project
