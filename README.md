# neorg-project-manager

A **Work Breakdown Structure (WBS)** engine for
[Neorg](https://github.com/nvim-neorg/neorg).

Organizes software projects the way factories organize production: number
every software item, track what depends on what, and let status flow upward
automatically. You always know the true state of any feature, any stage, any
task — no status meetings required.

## The Idea

Software projects fail at scale not because people can't code, but because
nobody can see the whole picture. Features depend on other features. A screen
needs an API that needs a database migration that needs infrastructure.
Everything connects, but your issue tracker shows a flat list.

This plugin structures your project as a **numbered tree of software items** —
the same way a factory numbers every part in a machine:

```
1.   My Cool Startup App
1.1. Stage 1
1.1.1. X-Code Setup                     <- done
1.1.2. Build Pipeline                    <- done

1.1.3. Authentication Feature
|  1.1.3.1. Stage 1 -- Login            <- in progress
|  |  Login only, pre-created accounts. Prove auth flow works.
|  |  1.1.3.1.1. Design                 <- done
|  |  1.1.3.1.2. Backend                <- done
|  |  1.1.3.1.3. Mobile                 <- in progress
|  |  1.1.3.1.4. QA                     <- blocked (waiting for Mobile)
|  1.1.3.2. Stage 2 -- Registration     <- blocked (waiting for Stage 1)
|     Self-service sign-up, email verification, password reset.

1.1.4. Home Screen Feature
|  1.1.4.1. Stage 1 -- Basic greeting   <- blocked (waiting for Auth Stage 1)
|     "Hello [name]!" after login. Validates end-to-end flow.
|     Pre-requisites:
|     - {* 1.1.3.1} Authentication Stage 1 — Login
|  1.1.4.2. Stage 2 -- Dashboard        <- not started
|     Real data, widgets, personalization.
```

Every software item — a feature, a stage, a backend endpoint, a UI screen —
gets a number, just like every part in a factory gets a part number. The
concepts map directly:

| Factory term | Software equivalent | In this plugin |
|-------------|---------------------|----------------|
| Assembly | Feature (Authentication) | Numbered directory or heading group |
| Sub-assembly | Stage (Stage 1 — Login) | Numbered file or sub-heading |
| Part | Task (Backend, Mobile, QA) | Leaf heading or list item |
| Part number | Software item number | `1.1.3.1.2` |
| Bill of Materials | Dependencies between items | `Pre-requisites:` with `{* number} Description` links |
| "Parts ready, assemble" | All inputs available, start work | `[READY_FOR_IMPLEMENTATION]` |

Dependencies are explicit. Status is computed from the bottom up: if 3 of 5
tasks are done, the parent shows `(-) [3/5]`. When all prerequisites of an
item are satisfied and work hasn't started, it shows
**READY FOR IMPLEMENTATION** — a pull signal that tells your team what to pick
up next, without anyone assigning it.

## Iterative Stages: The Core Workflow

The main benefit of this structure: **one feature, multiple iterations.**

Instead of building a feature "completely" in one pass (which never works),
you break each feature into progressive stages — each delivering a working
increment that you can test, show, and validate:

```
1.1.3. Authentication
├── 1.1.3.1. Stage 1 — Quick PoC
│   Prove the business logic works with basic UI elements.
│   Get stakeholder sign-off before investing in polish.
│   ├── Design (wireframe-level)
│   ├── Backend (core logic only)
│   ├── Mobile (unstyled, functional)
│   └── QA (happy path)
│
├── 1.1.3.2. Stage 2 — UX validation
│   Proper wireframes. Test real user behavior.
│   Catch UX problems before investing in pixel-perfect work.
│   Pre-requisites:
│   - {* 1.1.3.1} Authentication Stage 1 — Quick PoC
│   ├── Design (interactive wireframes)
│   ├── Backend (edge cases, error handling)
│   ├── Mobile (styled, transitions)
│   └── QA (user testing, edge cases)
│
└── 1.1.3.3. Stage 3 — Production quality
    Pixel-perfect designs. Performance. Accessibility.
    Pre-requisites:
    - {* 1.1.3.2} Authentication Stage 2 — UX validation
    ├── Design (final assets, design system)
    ├── Backend (optimization, monitoring)
    ├── Mobile (pixel-perfect, animations)
    └── QA (full regression, accessibility audit)
```

**Why this works better than "build it all at once":**

| Problem with single-pass | How stages solve it |
|--------------------------|---------------------|
| You discover the UX is wrong after building everything | Stage 1 validates logic cheaply; pivot before Stage 2 |
| Pixel-perfect work is wasted if the feature gets cut | Each stage is a valid stopping point — ship Stage 1 if needed |
| QA finds fundamental issues late | Each stage has its own QA — problems surface early |
| "80% done" for 3 months | Each stage is either done or not — no ambiguous progress |
| Dependencies between features are invisible | Stage N of Feature B can depend on Stage M of Feature A |

**In practice, each stage is a complete vertical slice:**

| Stage | Design | Backend | Frontend | QA |
|-------|--------|---------|----------|-----|
| 1. PoC | Sketch on paper | Core endpoint | Unstyled inputs | Does it work? |
| 2. UX | Wireframes | Error handling | Styled, responsive | User testing |
| 3. Polish | Pixel-perfect | Optimized | Animated | Full regression |
| 4. Scale | Design system | Load-tested | A/B variants | Performance audit |

Not every feature needs all stages. A simple CRUD screen might be done in
Stage 1. A complex flow (onboarding, payments) might need all four. The
structure adapts — add stages when you need them.

**The prerequisite chain makes it safe:**

```norg
**** ( ) 1.1.3.2. Stage 2
     Pre-requisites:
     - ( ) {* 1.1.3.1} Authentication Stage 1
```

Stage 2 shows `[BLOCKED]` until Stage 1 is complete. When Stage 1 finishes,
Stage 2 shows `[READY_FOR_IMPLEMENTATION]`. No one starts pixel-perfect
designs before the PoC proves the concept works.

**Cross-feature stage dependencies — the real power:**

Features don't exist in isolation. A Home Screen needs authentication to work.
But it doesn't need *all* of authentication — just enough to log in. This is
where stage-level dependencies unlock parallelism:

```
1.1.3. Authentication
├── 1.1.3.1. Stage 1 — Login only (pre-created accounts)
├── 1.1.3.2. Stage 2 — Registration, password reset
└── 1.1.3.3. Stage 3 — 2FA, session management

1.1.4. Home Screen
├── 1.1.4.1. Stage 1 — Basic "Hello [name]" after login
│   Pre-requisites:
│   - {* 1.1.3.1} Authentication Stage 1 — Login     ← only needs login!
├── 1.1.4.2. Stage 2 — Dashboard with real data
│   Pre-requisites:
│   - {* 1.1.4.1} Home Screen Stage 1 — Basic greeting
│   - {* 1.1.5.1} Data API Stage 1 — Mock responses
└── 1.1.4.3. Stage 3 — Pixel-perfect, personalized

1.1.5. Data API
├── 1.1.5.1. Stage 1 — Hardcoded mock responses
└── 1.1.5.2. Stage 2 — Real database queries
```

Notice what this enables:

| Without stage dependencies | With stage dependencies |
|---------------------------|------------------------|
| "Authentication must be 100% complete before Home Screen starts" | Home Screen Stage 1 only needs Auth Stage 1 (login) |
| Features are serialized — one finishes, next starts | Features run in parallel — each progresses to the stage it needs |
| A delay in one feature blocks everything downstream | A delay in Auth Stage 3 (2FA) doesn't block Home Screen at all |
| Scope creep in one feature cascades everywhere | Each stage is a minimal, decoupled chunk |

**The dependency is on a specific stage, not the whole feature.** This means:

- You can ship Home Screen Stage 1 while Authentication is still working on
  registration (Stage 2)
- The Data API team can deliver mock responses (Stage 1) immediately, unblocking
  the Home Screen team, while the real database work happens in parallel
- If a feature gets descoped to "Stage 1 only," everything that depends on
  Stage 1 still works — nothing breaks

This is how real products ship: in thin vertical slices, where each slice is
independently testable and deployable, and dependencies are on the *minimum
viable version* of what you need — not the complete vision.

**Adapting stages based on feedback:**

Stages aren't set in stone. If UX testing in Stage 2 reveals problems,
insert another wireframe iteration before committing to pixel-perfect work:

```
1.1.3. Authentication
├── 1.1.3.1. Stage 1 — Quick PoC                    (x) done
├── 1.1.3.2. Stage 2 — UX validation                (x) done
├── 1.1.3.3. Stage 2b — Revised wireframes           ← inserted!
│   UX testing showed confusion with the login flow.
│   Simplified to single-screen auth before proceeding.
│   Pre-requisites:
│   - {* 1.1.3.2} Auth Stage 2 — UX validation
├── 1.1.3.4. Stage 3 — Production quality            ( ) not started
│   Pre-requisites:
│   - {* 1.1.3.3} Auth Stage 2b — Revised wireframes
```

Run `:NeorgPMRenumber` (`<LocalLeader>pr`) after inserting — all numbers and links update
automatically. Stage 3's prerequisite now correctly points to the new
Stage 2b, and Stage 3 shows `[BLOCKED]` until the revised wireframes
are approved.

This is how real products evolve: you discover problems mid-build and
insert corrective iterations. The structure adapts — you don't have to
tear apart a Gantt chart or restructure a kanban board. Add a heading,
renumber, done.

## Why This Over Common Tools?

| Approach | What breaks at scale |
|----------|---------------------|
| Flat issue trackers (Jira, GitHub Issues) | 500 tickets in a list. No structure. Can't see the forest for the trees. |
| Kanban boards | Great for flow, but silent on dependencies. You pull a task and discover it's blocked halfway through. |
| Sprint backlogs | Time-boxed but no structural truth. Status is self-reported — easy to game. |
| Gantt charts | Beautiful on day one. Permanently out of date by day two. Maintained in a separate tool nobody opens. |
| Wiki pages | Someone writes a plan, then reality diverges. Manual status updates go stale instantly. |
| SaaS tools (Linear, Notion, Monday) | Lock-in. Offline-hostile. Not in your repo. Yet another tab to keep open. |

**What this plugin gives you instead:**

| Principle | How it works |
|-----------|-------------|
| Structural hierarchy | Headings and files mirror how software is actually built — systems, features, stages, tasks |
| Bottom-up truth | A parent's status is COMPUTED from its children. You can't mark "Engine" done if "Pistons" isn't. No lying about progress. |
| Explicit dependencies | Pre-requisites are declared with links. The plugin tells you what's blocked and what's ready. |
| Pull-based workflow | `[READY_FOR_IMPLEMENTATION]` = all inputs are available. Pick it up. No manager needed to assign it. |
| Self-documenting | The project plan IS the documentation. One source of truth. Not a plan AND a tracker AND a wiki. |
| Lives in your repo | Plain text `.norg` files. Version-controlled. Works offline. Survives any tool's shutdown. |
| Zero maintenance | Numbers auto-update. Status auto-propagates. Status files auto-regenerate on save. |

## The Factory Analogy

If you've seen [Wintergarten's Marble Machine X
series](https://www.youtube.com/wintergatan), this is the same thinking he
applies to building complex machines: break everything into numbered parts,
track dependencies between them, and always know which sub-assembly is holding
up the whole build.

In manufacturing, this methodology is called:

| Term | What it means here |
|------|-------------------|
| **Work Breakdown Structure** | The numbered heading tree (`1.1.3.1.2.`) |
| **Indentured Parts List** | Files named with hierarchical numbers |
| **Bill of Materials (BOM)** | The `Pre-requisites:` section with linked dependencies |
| **Stage-Gate Process** | Design → Backend → Mobile → QA stages within each feature |
| **Kanban pull signal** | `[READY_FOR_IMPLEMENTATION]` — all inputs ready, pull when free |
| **Assembly status tracking** | Todo state propagation from children → parent |

You don't need to know these terms to use the plugin. But if you've worked in
manufacturing, hardware engineering, or systems engineering — this will feel
immediately familiar.

### Mapping to Agile / Jira Terminology

If you come from Jira, Linear, or similar tools, here's how the concepts
translate:

| Jira / Agile Term | This Plugin | Example |
|--------------------|-------------|---------|
| Project | Project root | `project.norg` |
| Epic | Feature (top-level numbered item) | `1.1.3. Authentication` |
| Story | Stage within a feature | `1.1.3.1. Stage 1 — Login` |
| Task | Discipline heading | `1.1.3.1.2. Backend` |
| Subtask | List item under a heading | `- ( ) Rate limiting` |
| Blocker / Dependency | Prerequisite link | `- {* 1.1.3.1} Auth Stage 1` |
| Sprint | Stage number | Stages are natural sprint boundaries |
| Done / In Progress / To Do | Todo states `(x)` `(-)` `( )` | Computed from children, not self-reported |
| Jira Board | `project.norg` | Navigable overview with live status |

The key difference: in Jira, these levels are separate entity types with
different screens, workflows, and permissions. Here, they're all just
headings at different depths — same syntax, same behavior, seamlessly
nested. No screen transitions, no loading spinners, no "configure your
workflow" step. A heading is a heading.

## What Makes This Different

Everything is a plain text file. No databases, no servers, no proprietary
formats. This has real consequences:

| Property | What it means in practice |
|----------|--------------------------|
| **Text-based** | Read, edit, and search with any tool — grep, sed, cat. Not locked behind an API or GUI. |
| **Git-compatible** | Diff your project plan. See who changed what, when. Branch your planning. Merge it. Code review your project structure. |
| **Offline-first** | Works on a plane, in a cabin, on a submarine. No internet required. No sync conflicts. |
| **Portable** | Copy the folder. That's your backup. That's your migration. No export/import dance. |
| **Future-proof** | Text files from 1970 are still readable. Your SaaS tool from 2020 might not exist next year. |
| **Composable** | Pipe your project files through Unix tools. Write scripts that parse them. Build your own reports. |
| **No vendor lock-in** | Don't like this plugin? Your files are still perfectly valid Neorg documents. Nothing is lost. |
| **Co-located with code** | Project plan lives next to the code it describes. Same repo. Same branch. Same PR. |
| **Zero cost** | No per-seat pricing. No "Pro tier for dependencies." No "Enterprise for custom fields." |
| **Scales down** | One file for a weekend project. A directory tree for a team effort. Same plugin, same workflow. |

### For teams

The text-based nature means your project management integrates with your
existing developer workflow:

- **Pull requests** can include project plan changes alongside code changes
- **Code review** catches unrealistic plans ("you marked this done but the PR is still open")
- **Blame** shows who last updated a task's status and when
- **Branches** let you prototype different project structures without committing
- **CI** could parse `.norg` files to generate reports, block merges on stale plans, or notify on READY items

## Use Cases

### Software development (general)

Any project with multiple features, stages, or milestones. The hierarchy maps
naturally to: Product → Epic → Feature → Stage → Task → Subtask.

### SaMD (Software as a Medical Device) / IEC 62304

Regulated software development requires **traceability** between software
items, verification activities, and design inputs. This plugin's structure
maps directly to IEC 62304 concepts:

| IEC 62304 Concept | Plugin Equivalent |
|-------------------|-------------------|
| Software System | Project root (`project.norg`) |
| Software Item | Numbered file or directory (`1.1.3. Authentication/`) |
| Software Unit | Leaf heading within a file (`1.1.3.1.2.1. Login Endpoint`) |
| Decomposition hierarchy | The numbered heading/file tree |
| Traceability | `{* number}` links between items (prerequisites, dependencies) |
| Verification | Todo states (done = verified, prerequisites = design inputs satisfied) |
| SOUP identification | Could be tracked as items with external links |

The text-based, version-controlled nature means you get **audit trails for
free** (git log), and the hierarchical structure satisfies decomposition
requirements without separate traceability matrices.

### Hardware / mechanical engineering

If you're building physical products (PCBs, enclosures, mechanisms), the WBS
maps to your assembly structure. Each file can represent a part or sub-assembly
with its own design/procurement/test stages.

### Research & thesis writing

Academic work has natural hierarchy: Thesis → Chapters → Sections →
Experiments → Tasks. Prerequisites model dependencies between experiments
("can't write Results until Data Collection is done").

### Game development

Games decompose into systems (Physics, AI, Rendering, Audio) with deep
dependency chains. The stage-gate pattern (Design → Prototype → Polish → QA)
fits naturally per feature.

### Event planning / production

Conferences, product launches, film production — anything with many parallel
workstreams that converge on a deadline. Prerequisites track the critical path
without a Gantt chart.

## Related Tools

There are several local-first, git-backed project management tools. They share
a philosophy (no SaaS, offline-capable, developer-native) but solve different
problems:

| Tool | Model | Best for |
|------|-------|----------|
| **neorg-project-manager** | Hierarchical WBS tree | Structural decomposition, dependencies, computed status |
| [Epiq](https://github.com/ljtn/epiq) | Kanban board (event-sourced) | Day-to-day task flow, sprints, team collaboration |
| [git-bug](https://github.com/MichaelMure/git-bug) | Issue tracker in git refs | Bug tracking without a server |
| [dstask](https://github.com/naggie/dstask) | Task list synced via git | Personal GTD-style task management |
| [Taskwarrior](https://taskwarrior.org/) | CLI task database | Personal task management with filters/reports |

### neorg-project-manager vs Epiq (detailed)

Epiq and this plugin share the most overlap in philosophy. Here's how they
compare:

| Dimension | Epiq | neorg-project-manager |
|-----------|------|----------------------|
| **Core metaphor** | Kanban board (columns, swimlanes) | Factory floor (assemblies, parts, part numbers) |
| **Question it answers** | "What am I working on today?" | "How does everything fit together? What's blocking the build?" |
| **Structure** | Flat (boards → swimlanes → issues) | Hierarchical tree (arbitrary depth) |
| **Dependencies** | Not explicit | First-class (prerequisites with status tracking) |
| **Status model** | Manual (drag between columns) | Computed (parent state = aggregation of children) |
| **Data format** | JSON event log | Plain `.norg` text files |
| **Interface** | Standalone TUI/GUI app | Embedded in Neovim buffers |
| **Collaboration** | Built-in multi-user sync (conflict-free) | Git-native (standard merge workflow) |
| **Editing model** | Structured commands (`:new issue`) | Free-form text editing |
| **Documentation** | Issues have descriptions/comments | The plan IS the documentation |
| **MCP/Agent support** | Built-in MCP server | Extensible via User events + Neovim API |

**They're complementary, not competing.** You could use both:
- neorg-project-manager defines the **structure** (what parts exist, how they
  relate, what the critical path is)
- Epiq handles the **flow** (which tickets are in progress today, who's
  assigned, sprint progress)

**Choose Epiq when:**
- You need a kanban board for sprint-level work
- Multiple people need real-time conflict-free sync
- You want a standalone tool that works outside any editor
- Your tasks are relatively flat (not deeply hierarchical)

**Choose neorg-project-manager when:**
- Your project has deep structural hierarchy (systems → features → stages → tasks)
- Dependencies between items are what slows you down
- You need computed status (not self-reported)
- Your project plan doubles as documentation
- You're already working in Neovim/Neorg
- You need regulatory traceability (IEC 62304, etc.)

## Features

- **Auto-numbering** — headings get hierarchical numbers (`1.1.3.1.`) written
  directly into the file, maintained on save
- **Custom root numbering** — type a custom number on a root heading (e.g.,
  `* 42. Project Alpha`) and all children follow from it automatically
- **Cross-file navigation** — press `<CR>` on `{* 1.1.3}` to jump to that
  heading, even if it's in another file
- **Prerequisite tracking** — virtual text shows `[BLOCKED: 1/2 prereqs done]`
  or `[READY_FOR_IMPLEMENTATION]`
- **Progress indicators** — virtual text shows `[3/5]` combining child headings
  and list item completion
- **Computed status** — parent state is always derived from children, never
  set manually. Cancelled items excluded, ambiguous propagates upward.
- **Compound status markers** — combine primary state with qualifiers using
  norg pipe syntax: `(?|-)` = in progress + uncertain, `(=|?)` = on hold + uncertain
- **Project status tree** — status files auto-update with a navigable
  overview of your entire project's state
- **Bidirectional propagation** — manually change a state in a status file
  and it propagates back to the source file
- **Item picker** — `:NeorgPMPick` to browse/filter all project items by status
- **Project init** — `:NeorgPMInit` scaffolds a new project with a numbered root status file
- **File renaming** — `:NeorgPMRenumberProject` renumbers files, directories,
  and all links when you restructure
- **Tree fold/toggle** — collapse or expand a tree element and all its children
  in status files with a single keystroke
- **Extract to file** — move a heading's content into its own `.norg` file,
  keeping the heading as a navigation link
- **Heading breadcrumb** — shows your current position in the project hierarchy
  (statusline, winbar, or virtual text)

## Requirements

- Neovim >= 0.10
- [Neorg](https://github.com/nvim-neorg/neorg) with the `norg` tree-sitter parser
- [lazy.nvim](https://github.com/folke/lazy.nvim) (recommended)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
-- lua/plugins/neorg-project-manager.lua
return {
    "GrivIN/neorg-project-manager",
    ft = "norg",
    opts = {},
}
```

## Quick Start

### Single-file project (simplest)

Open any `.norg` file and start writing headings:

```norg
* Project Alpha
** Stage 1
*** Setup
*** Build Pipeline
** Stage 2
*** Feature A
```

Run `:NeorgPMRenumber` (`<LocalLeader>pr`). Your headings become:

```norg
* 1. Project Alpha
** 1.1. Stage 1
*** 1.1.1. Setup
*** 1.1.2. Build Pipeline
** 1.2. Stage 2
*** 1.2.1. Feature A
```

Add todo states and they propagate normally:

```norg
* (-) 1. Project Alpha
** (-) 1.1. Stage 1
*** (x) 1.1.1. Setup
*** ( ) 1.1.2. Build Pipeline
```

### Custom root numbering

If your company assigns unique project numbers, type the root heading with
that number. The plugin preserves it as an anchor — all children follow:

```norg
* 42. Project Alpha
** Stage 1
*** Setup
*** Build Pipeline
* Project Beta
** Feature X
```

After `:NeorgPMRenumber` (`<LocalLeader>pr`):

```norg
* 42. Project Alpha
** 42.1. Stage 1
*** 42.1.1. Setup
*** 42.1.2. Build Pipeline
* 43. Project Beta
** 43.1. Feature X
```

`42` is preserved (user-typed anchor). `Project Beta` had no number, so it
gets `43` (next consecutive). All children inherit from their parent.

You can have multiple anchored projects in one file with gaps:

```norg
* 42. Project Alpha
** 42.1. Stage 1
* 100. Special Project
** 100.1. Setup
* Project Gamma
** 101.1. Feature
```

Each anchor resets the counter. Un-numbered headings always get `previous + 1`.

This only applies to level-1 headings in files without a prefix (standalone
files, `project.norg`). Files with a prefix (e.g., `1.1.3.1. Stage 1.norg`)
always number their headings relative to the file prefix — no anchoring.

Disable with `anchor_root_headings = false` to get pure positional numbering.

### Multi-file project

Create a project structure:

```
~/Notes/projects/my-cool-startup/
├── project.norg                     <- create this (can be empty)
├── 1.1. Stage 1/
│   ├── 1.1.1. X-Code Setup.norg
│   ├── 1.1.2. Build Pipeline.norg
│   └── 1.1.3. Authentication/
│       ├── 1.1.3.1. Stage 1.norg
│       └── 1.1.3.2. Stage 2.norg
└── 1.2. Stage 2/
    └── ...
```

The file `1.1.3.1. Stage 1.norg` contains headings numbered from its prefix:

```norg
* (-) 1.1.3.1.1. Design
* (x) 1.1.3.1.2. Back end
** (x) 1.1.3.1.2.1. Login Endpoint
* ( ) 1.1.3.1.3. Mobile
```

Open `project.norg` and run `:NeorgPMStatus` (`<LocalLeader>ps`) to generate an overview:

```norg
* (-) my-cool-startup [0/2]
** (-) 1.1. Stage 1 {* 1.1} [2/3]
*** (x) 1.1.1. X-Code Setup {* 1.1.1}
*** (x) 1.1.2. Build Pipeline {* 1.1.2}
*** (-) 1.1.3. Authentication {* 1.1.3} [1/2]
**** (-) 1.1.3.1. Stage 1 {* 1.1.3.1}
**** ( ) 1.1.3.2. Stage 2 {* 1.1.3.2}
** ( ) 1.2. Stage 2 {* 1.2}
```

Press `<CR>` on any `{* number}` link to jump to that file.

### Subtasks within items

Headings define the structural hierarchy. List items underneath define
the actual work within each item:

```norg
***** (-) 1.1.3.1.2. Backend
      Takes username and password, returns secure cookie.
      - (x) Users table migration
      - (x) Login endpoint
      - ( ) Rate limiting
      - ( ) Session token generation
```

The plugin counts both child headings AND list items with todo states.
The heading above shows `[2/4]` — 2 of 4 subtasks done.

This lets you mix structural decomposition (headings for features,
stages, disciplines) with practical task tracking (list items for the
actual work items within each discipline). You don't need to create a
heading for every small task — list items keep things lightweight where
headings would be overkill.

### Combined approach

You can mix manual content with managed headings in `project.norg`:

```norg
* My Cool Startup App
  Our mobile banking app. Key decisions below.

  Goals:
  - Launch by Q2
  - 99.9% uptime

** (-) 1.1. Stage 1 {* 1.1} [2/3]
*** (x) 1.1.1. X-Code Setup {* 1.1.1}
*** (x) 1.1.2. Build Pipeline {* 1.1.2}
*** (-) 1.1.3. Authentication {* 1.1.3} [1/2]

** Architecture Notes
   - Use microservices for auth
   - Single DB for stage 1
```

**The rule:** headings with `{* number}` links are managed by the plugin (states
auto-update). Everything else is yours — never touched.

### Default keybinds (in norg buffers)

| Key | Action |
|-----|--------|
| `<CR>` | Follow `{* number}` link (cross-file), falls back to Neorg hop |
| `<LocalLeader>pr` | Renumber headings in current file |
| `<LocalLeader>pR` | Renumber entire project (files + dirs + links) |
| `<LocalLeader>ps` | Update status in current status file |
| `<LocalLeader>pS` | Update all status files across the project |
| `<LocalLeader>pt` | Toggle body folds — hide descriptions, keep all headings visible |
| `<LocalLeader>pT` | Toggle full fold — collapse heading with all children |
| `<LocalLeader>pe` | Extract heading content into its own file |
| `<LocalLeader>pp` | Browse project items (picker) |
| `<LocalLeader>pP` | Browse items by status filter |
| `<LocalLeader>pi` | Initialize new project |

Disable defaults with `default_keybinds = false`. Change the prefix
with `keybind_prefix = "n"` (becomes `<LocalLeader>nr`, etc.).
Integrates with [which-key.nvim](https://github.com/folke/which-key.nvim)
if installed.

## Documentation

| Document | Contents |
|----------|----------|
| [Usage Guide](docs/usage.md) | Commands, configuration, automatic behavior, tips |
| [Architecture](docs/architecture.md) | Internals, state aggregation, compound markers, project structure |
| `:help neorg-project-manager` | Vim help (commands + keybinds quick reference) |

## Status Model

Status is **computed**, never self-reported. A parent's state is always
derived from its children:

```
3 children: (x) done, (-) in progress, ( ) undone
→ parent becomes (-) [1/3]
```

### Aggregation rules

| Children | Parent |
|----------|--------|
| All done | `(x)` |
| Some done or pending | `(-)` |
| None started | `( )` |
| All on-hold | `(=)` |
| All cancelled | `(_)` |
| All ambiguous | `(?)` |

**Cancelled `(_)` items are excluded** from the active pool. Progress
counts reflect only active items: 2 done + 1 cancelled → `(x) [2/2]`.

**Ambiguous `(?)` propagates upward** as a qualifier. If any child is
uncertain, the parent shows it: `(?|-)` = pending with ambiguity.

**Important `(!)` is local-only** — marks priority but doesn't propagate.

### Compound markers

Combine a primary state with a qualifier using norg's `|` pipe syntax:

| Marker | Meaning |
|--------|---------|
| `(?|-)` | In progress + uncertain |
| `(=|?)` | On hold + uncertain |
| `(=|-)` | On hold + partially in progress |

The plugin determines primary vs qualifier by semantic role (not position).
`(?|-)` and `(-|?)` are equivalent — though only `(?|-)` parses correctly
due to norg scanner constraints. The plugin handles ordering automatically.

See [Architecture docs](docs/architecture.md) for full details.

## Health Check

Run `:checkhealth neorg-project-manager` to verify setup.

## Roadmap

- [ ] Demo GIF / screenshot in README
- [ ] Statusline component — show current heading number / project state
      in lualine or similar
- [ ] Circular prerequisite detection — warn when A depends on B depends on A
- [ ] Windows compatibility testing and CI
- [ ] Semantic version tags / release workflow
- [ ] LuaLS type annotations (`.luarc.json` + `@class` annotations on config)

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
