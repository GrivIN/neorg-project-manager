# Contributing

Thanks for considering contributing to neorg-project-manager!

## Development Setup

1. Clone the repo into your Neovim config or a separate directory:
   ```sh
   git clone https://github.com/GrivIN/neorg-project-manager.git
   ```

2. Add it to your lazy.nvim config with `dir = "/path/to/neorg-project-manager"`

3. Make sure you have the norg tree-sitter parser installed

## Running Tests

```sh
nvim --headless -u NONE -l tests/run.lua
```

Tests require Neovim >= 0.10 and the norg tree-sitter parser. The test
framework is self-contained (no external dependencies like plenary.nvim).

## Code Style

- Format with [StyLua](https://github.com/JohnnyMorganz/StyLua): `stylua lua/`
- 4 spaces indentation, 120 character line width
- Double quotes for strings
- Docstrings on all public functions (`--- @param`, `--- @return`)

## Pull Requests

1. Create a branch from `main`
2. Make your changes
3. Run the test suite and verify all tests pass
4. Add tests for new functionality
5. Update the README if adding user-facing features
6. Update `doc/neorg-project-manager.txt` for new commands, config options, or API changes
7. Add a changelog entry under `[Unreleased]` in `CHANGELOG.md`

## Architecture

```
lua/neorg-project-manager/
├── config.lua      Shared config storage
├── helpers.lua     Tree-sitter utilities, link patterns, sorting
├── numbering.lua   Number formatting, parsing, renumbering
├── hop.lua         Link resolution (<CR> override)
├── mixed.lua       Mixed-type progress virtual text
├── prereqs.lua     Prerequisite tracking virtual text
├── project.lua     Project root detection, file scanning
├── index.lua       Cross-file index with lazy loading
├── status.lua      Status tree generation (project.norg / index.norg)
├── rename.lua      Project-wide file/dir renaming
├── health.lua      :checkhealth integration
└── init.lua        Entry point, setup, commands, orchestration
```

Key design principle: modules access config through `config.lua` (never
store their own copy), and share tree-sitter utilities through `helpers.lua`.
