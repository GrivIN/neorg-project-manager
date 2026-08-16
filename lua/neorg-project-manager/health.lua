--- Health check for neorg-project-manager.
--- Run with :checkhealth neorg-project-manager
---
--- @module neorg-project-manager.health

local M = {}

function M.check()
    vim.health.start("neorg-project-manager")

    -- Check Neovim version
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.error("Neovim >= 0.10 required", { "Update Neovim to 0.10 or later" })
    end

    -- Check norg tree-sitter parser
    local ok, _ = pcall(vim.treesitter.language.add, "norg")
    if ok then
        vim.health.ok("norg tree-sitter parser available")
    else
        vim.health.error("norg tree-sitter parser not found", {
            "Install via :TSInstall norg or ensure luarocks parser is on runtimepath",
            "See Neorg setup guide for parser installation",
        })
    end

    -- Check if config is loaded
    local cfg = require("neorg-project-manager.config")
    if cfg.values and next(cfg.values) then
        vim.health.ok("Plugin configured (setup() called)")
    else
        vim.health.warn("Plugin not yet configured", {
            "Call require('neorg-project-manager').setup({}) in your config",
        })
    end

    -- Check project root detection (for current file)
    local filepath = vim.api.nvim_buf_get_name(0)
    if filepath ~= "" then
        local project = require("neorg-project-manager.project")
        local root = project.find_root(filepath)
        if root then
            vim.health.ok("Project root detected: " .. root)
        else
            vim.health.info("No project root found for current file (single-file mode)")
        end
    end

    -- Check keybinds
    local default_keybinds = cfg.values.default_keybinds
    if default_keybinds == false then
        vim.health.info("Default keybinds disabled (default_keybinds = false)")
    else
        local prefix = (cfg.values.keybind_prefix or "p")
        vim.health.ok("Keybinds active: <LocalLeader>" .. prefix .. "r/R/s/S")
    end

    -- Check for Neorg todo-introspector conflict
    local has_introspector = pcall(function()
        local neorg = require("neorg")
        if neorg and neorg.modules and neorg.modules.loaded_modules then
            return neorg.modules.loaded_modules["core.todo-introspector"] ~= nil
        end
    end)
    if has_introspector then
        vim.health.warn("Neorg core.todo-introspector is active — its virtual text may overlap with neorg-project-manager", {
            'Disable it in your Neorg config: remove ["core.todo-introspector"] from load table',
            "Or use core.defaults without it",
        })
    end

    -- Validate numbering_styles
    local valid_styles = { numeric = true, alpha_upper = true, alpha_lower = true, roman_upper = true, roman_lower = true }
    local styles = cfg.values.numbering_styles or {}
    for i, style in ipairs(styles) do
        if not valid_styles[style] then
            vim.health.warn(string.format("numbering_styles[%d] = '%s' is not a recognized style", i, style), {
                "Valid styles: numeric, alpha_upper, alpha_lower, roman_upper, roman_lower",
            })
        end
    end
end

return M
