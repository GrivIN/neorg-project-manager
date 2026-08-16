# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Auto-numbering of headings (configurable styles: numeric, alpha, roman)
- Cross-file navigation via `{* number}` links
- Prerequisite tracking with `[BLOCKED]` / `[READY_FOR_IMPLEMENTATION]` virtual text
- Mixed-type progress indicators `[done/total]` (headings + list items)
- Project status tree generation in `project.norg` / `index.norg`
- Surgical status updates (preserves manual content in status files)
- Project-wide file/directory renaming with confirmation
- Configurable numbering format (`numbering_styles`, `number_format`, separators)
- File prefix extraction from filenames for cross-file numbering
- Lazy-loaded project-wide index with mtime-based caching
- Natural sort for correct ordering with 10+ items at any level
- Buffer-local keybinds (`<LocalLeader>pr/pR/ps/pS`)
- which-key.nvim integration (optional)
- Health check (`:checkhealth neorg-project-manager`)
- Custom highlight groups (`NeorgPMBlocked`, `NeorgPMReady`, `NeorgPMProgress`)
- User autocmd events (`NeorgPMAttach`, `NeorgPMRenumber`)
- Per-buffer disable via `vim.b.neorg_pm_disabled`
- Smart auto-renumber (only if file is in a project or already numbered)
