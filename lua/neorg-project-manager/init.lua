--- neorg-project-manager: A standalone Neovim plugin for project management in Neorg.
---
--- Provides:
---   - Auto-numbering of headings (written into the file, configurable format)
---   - Number-based link resolution ({* 1.1.1} style hop)
---   - Mixed-type todo propagation (virtual text showing heading + list item progress)
---   - Prerequisite tracking (virtual text showing blocked/ready status)
---
--- @module neorg-project-manager

-- Prevent double-loading
if vim.g.loaded_neorg_project_manager then
    return {}
end
vim.g.loaded_neorg_project_manager = true

local M = {}

local cfg = require("neorg-project-manager.config")
local numbering = require("neorg-project-manager.numbering")
local hop = require("neorg-project-manager.hop")
local mixed = require("neorg-project-manager.mixed")
local prereqs = require("neorg-project-manager.prereqs")
local project = require("neorg-project-manager.project")
local idx = require("neorg-project-manager.index")
local status = require("neorg-project-manager.status")
local rename = require("neorg-project-manager.rename")
local fold = require("neorg-project-manager.fold")
local extract = require("neorg-project-manager.extract")

--- Default configuration for the plugin.
--- Users can override any of these in their lazy.nvim `opts` table.
M.defaults = {
    --- Feature toggles: set to false to disable individual features.
    auto_numbering = true,
    mixed_propagation = true,
    prerequisite_tracking = true,

    --- Renumbering triggers: when should headings be automatically renumbered?
    --- In addition to the manual `:NeorgPMRenumber` command.
    renumber_on_save = true,            -- Renumber on BufWritePre
    renumber_on_heading_leave = true,   -- Renumber when cursor leaves a modified heading line

    ---------------------------------------------------------------------------
    --- NUMBERING FORMAT CONFIGURATION
    ---------------------------------------------------------------------------

    --- Style for each heading level (1-6). Each entry determines how the
    --- counter for that level is formatted.
    ---
    --- Built-in styles:
    ---   "numeric"      -> 1, 2, 3, 4, ...
    ---   "alpha_upper"  -> A, B, C, ..., Z, AA, AB, ...
    ---   "alpha_lower"  -> a, b, c, ..., z, aa, ab, ...
    ---   "roman_upper"  -> I, II, III, IV, V, ...
    ---   "roman_lower"  -> i, ii, iii, iv, v, ...
    ---
    --- Example: { "numeric", "numeric", "alpha_upper", "alpha_lower", "roman_lower", "numeric" }
    ---   produces headings like: 1.1.A.b.iv.1
    numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },

    --- Separator between number parts.
    --- With "." : "1.1.3"
    --- With "-" : "1-1-3"
    --- With "/" : "1/1/3"
    number_separator = ".",

    --- Separator between the formatted number and the heading title in the file.
    --- This is used for BOTH writing numbers into headings and parsing them back out.
    --- The plugin splits on the FIRST occurrence of this string to separate number from title.
    ---
    --- Examples:
    ---   ". " -> "1.1.3. My Title"     (default)
    ---   ": " -> "1.1.3: My Title"
    ---   " "  -> "1.1.3 My Title"
    ---   ") " -> "1.1.3) My Title"
    number_title_separator = ". ",

    --- Custom format function (optional, overrides numbering_styles + number_separator).
    --- If provided, this function is called to generate the number string for each heading.
    ---
    --- @type nil|fun(counters: number[], level: number): string
    ---
    --- Parameters:
    ---   counters - Array of 6 integers, where counters[i] is the sequential count
    ---             for heading level i. e.g., {1, 2, 3, 0, 0, 0} means we're at
    ---             the 3rd heading3 under the 2nd heading2 under the 1st heading1.
    ---   level   - The current heading level (1-6).
    ---
    --- Returns:
    ---   The formatted number string WITHOUT the title separator.
    ---   e.g., "1.2.3" or "I.B.iii" or "1-A-1"
    ---
    --- Example:
    ---   number_format = function(counters, level)
    ---       -- Custom: Roman numerals for level 1, letters for level 2, numbers for rest
    ---       local styles = {"roman_upper", "alpha_upper", "numeric", "numeric", "numeric", "numeric"}
    ---       local numbering = require("neorg-project-manager.numbering")
    ---       local parts = {}
    ---       for i = 1, level do
    ---           parts[i] = numbering.format_counter(counters[i], styles[i])
    ---       end
    ---       return table.concat(parts, ".")
    ---   end
    number_format = nil,

    ---------------------------------------------------------------------------
    --- PREREQUISITE TRACKING CONFIGURATION
    ---------------------------------------------------------------------------

    --- Lua pattern to detect prerequisite sections in heading content.
    --- The plugin looks for this pattern in lines directly under a heading.
    --- List items below the matching line are treated as prerequisite references.
    prereq_pattern = "Pre%-requisites:",

    ---------------------------------------------------------------------------
    --- VIRTUAL TEXT DISPLAY CONFIGURATION
    ---------------------------------------------------------------------------

    --- Highlight groups used for virtual text indicators.
    blocked_highlight = "DiagnosticWarn",
    ready_highlight = "DiagnosticOk",
    mixed_progress_highlight = "Normal",

    --- Format function for the "blocked" indicator.
    --- @type fun(done: number, total: number): string
    blocked_format = function(done, total)
        return string.format("[BLOCKED: %d/%d prereqs done]", done, total)
    end,

    --- Text shown when all prerequisites are done and the item hasn't started.
    ready_text = "[READY_FOR_IMPLEMENTATION]",

    --- Format function for the mixed progress indicator.
    --- Shows combined count of child headings + list items with todo states.
    --- @type fun(done: number, total: number): string
    mixed_format = function(done, total)
        return string.format("[%d/%d]", done, total)
    end,

    ---------------------------------------------------------------------------
    --- CROSS-FILE / PROJECT SETTINGS
    ---------------------------------------------------------------------------

    --- Enable project-wide features (cross-file hop, prereqs, status tree).
    cross_file = true,

    --- Project root detection.
    --- nil = auto-detect by looking for project.norg in ancestor directories.
    --- string = explicit absolute path to project root.
    --- function(filepath) → string|nil = custom detection logic.
    project_root = nil,

    --- File prefix extraction.
    --- nil = auto-detect from filename using number_title_separator.
    --- string = use this fixed prefix for all files.
    --- function(filepath) → string|nil = custom extraction logic.
    file_prefix = nil,

    --- Lazy index: pre-index all project files on idle timer.
    --- When false (default), files are only parsed when referenced.
    preindex_on_idle = false,

    --- Rename confirmation threshold.
    --- If the number of file/dir renames exceeds this, a confirmation prompt is shown.
    rename_confirm_threshold = 5,

    ---------------------------------------------------------------------------
    --- KEYBINDINGS
    ---------------------------------------------------------------------------

    --- Set to false to disable all default keybindings.
    --- You can then map commands manually via :NeorgPMRenumber etc.
    default_keybinds = true,

    --- Keybind prefix (appended to <LocalLeader>).
    --- Default binds become <LocalLeader>pr, <LocalLeader>pP, <LocalLeader>ps, etc.
    keybind_prefix = "p",
}

--- The active configuration (populated by setup()).
M.config = {}

--- Namespaces for virtual text extmarks (one per feature for independent clearing).
M.ns = {
    prereqs = vim.api.nvim_create_namespace("neorg-pm/prereqs"),
    mixed = vim.api.nvim_create_namespace("neorg-pm/mixed"),
}

--- Per-buffer state tracking.
--- Keys are buffer handles, values are tables with:
---   dirty_heading_line: number|nil  -- line of a heading that was modified (0-indexed)
---   timer: uv_timer_t|nil           -- debounce timer for virtual text refresh
M.state = {}

--- Initialize the plugin. Call this from your lazy.nvim config function.
--- Sets up FileType autocmd for norg buffers and registers all commands.
---
--- @param opts table|nil  User configuration (merged with M.defaults)
function M.setup(opts)
    -- Version guard
    if vim.fn.has("nvim-0.10") == 0 then
        vim.notify("neorg-project-manager requires Neovim >= 0.10", vim.log.levels.ERROR)
        return
    end

    M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})

    -- Set shared config (all modules read from this)
    cfg.set(M.config)

    -- Define highlight groups (user can override with :highlight link)
    vim.api.nvim_set_hl(0, "NeorgPMBlocked", { default = true, link = "DiagnosticWarn" })
    vim.api.nvim_set_hl(0, "NeorgPMReady", { default = true, link = "DiagnosticOk" })
    vim.api.nvim_set_hl(0, "NeorgPMProgress", { default = true, link = "Comment" })

    -- Use plugin highlight groups in config (override user's generic references)
    M.config.blocked_highlight = M.config.blocked_highlight or "NeorgPMBlocked"
    M.config.ready_highlight = M.config.ready_highlight or "NeorgPMReady"
    M.config.mixed_progress_highlight = M.config.mixed_progress_highlight or "NeorgPMProgress"

    -- Auto-attach to norg buffers
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "norg",
        group = vim.api.nvim_create_augroup("NeorgProjectManager", { clear = true }),
        callback = function(ev)
            M.attach(ev.buf)
        end,
    })

    -- Cache invalidation + auto-update on save (any .norg file in project)
    if M.config.cross_file then
        vim.api.nvim_create_autocmd("BufWritePost", {
            pattern = "*.norg",
            group = vim.api.nvim_create_augroup("NeorgPM_CrossFile", { clear = true }),
            callback = function(ev)
                local filepath = vim.api.nvim_buf_get_name(ev.buf)
                local filename = vim.fn.fnamemodify(filepath, ":t")

                -- Invalidate project index cache for this file
                idx.invalidate(filepath)

                -- Auto-update parent index.norg if this is a content file (not index/project)
                if filename ~= "index.norg" and filename ~= "project.norg" then
                    M.auto_update_parent_index(filepath)
                end
            end,
        })
    end

    ---------------------------------------------------------------------------
    --- COMMANDS
    ---------------------------------------------------------------------------

    --- Renumber headings in the current file (prefix-aware).
    vim.api.nvim_create_user_command("NeorgPMRenumber", function()
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype == "norg" then
            numbering.renumber(buf)
            M.refresh_virtual_text(buf)
            vim.api.nvim_exec_autocmds("User", { pattern = "NeorgPMRenumber", data = { buf = buf } })
        end
    end, { desc = "Renumber headings and update links in current file" })

    --- Renumber the entire project (files, dirs, links, status).
    vim.api.nvim_create_user_command("NeorgPMRenumberProject", function()
        local buf = vim.api.nvim_get_current_buf()
        rename.renumber_project(buf)
    end, { desc = "Renumber all project files/dirs and update all links" })

    --- Regenerate status content in current buffer (project.norg or index.norg).
    --- Uses surgical update on populated files; full generation on empty files.
    --- Warns if the buffer has unsaved changes (full generation would overwrite them).
    vim.api.nvim_create_user_command("NeorgPMStatus", function()
        local buf = vim.api.nvim_get_current_buf()
        local line_count = vim.api.nvim_buf_line_count(buf)
        local content = vim.api.nvim_buf_get_lines(buf, 0, line_count, false)
        local is_empty = line_count <= 1 and (content[1] or "") == ""

        if is_empty then
            if vim.bo[buf].modified then
                vim.ui.select({ "Yes", "No" }, {
                    prompt = "Buffer has unsaved changes. Overwrite with generated status?",
                }, function(choice)
                    if choice == "Yes" then
                        status.generate(buf)
                    end
                end)
            else
                status.generate(buf)
            end
        else
            status.update(buf)
        end
    end, { desc = "Update status in current project.norg/index.norg (preserves manual content)" })

    --- Regenerate ALL index.norg + project.norg files in the project.
    vim.api.nvim_create_user_command("NeorgPMStatusAll", function()
        local buf = vim.api.nvim_get_current_buf()
        local filepath = vim.api.nvim_buf_get_name(buf)
        local root = project.find_root(filepath)
        if root then
            status.regenerate_all(root)
            vim.notify("All status files regenerated.", vim.log.levels.INFO)
        else
            vim.notify("No project root found.", vim.log.levels.ERROR)
        end
    end, { desc = "Regenerate ALL index.norg + project.norg in the project" })

    --- Toggle fold (collapse/expand) a tree element in project.norg/index.norg.
    vim.api.nvim_create_user_command("NeorgPMToggle", function()
        local buf = vim.api.nvim_get_current_buf()
        fold.toggle(buf)
    end, { desc = "Toggle tree element fold (collapse/expand heading with children)" })

    --- Extract a .norg file into a directory with separate files per heading.
    vim.api.nvim_create_user_command("NeorgPMExtract", function()
        local buf = vim.api.nvim_get_current_buf()
        extract.extract(buf)
    end, { desc = "Extract file headings into a directory structure" })
end

--- Attach the plugin to a norg buffer.
--- Sets up buffer-local keymaps, autocmds, and initial virtual text.
---
--- @param buf number  Buffer handle
function M.attach(buf)
    -- Skip if already attached or buffer-local disable
    if M.state[buf] then
        return
    end
    if vim.b[buf].neorg_pm_disabled then
        return
    end

    M.state[buf] = {
        dirty_heading_line = nil,
        timer = nil,
    }

    -- Initial refresh of virtual text (don't renumber on open — assume file is correctly numbered)
    M.refresh_virtual_text(buf)

    -- Attach hop (number-based link resolution via <CR>)
    hop.attach(buf)

    -- Buffer-local keybinds
    if M.config.default_keybinds then
        local prefix = "<LocalLeader>" .. M.config.keybind_prefix

        -- Register which-key group if available
        local wk_ok, wk = pcall(require, "which-key")
        if wk_ok then
            pcall(wk.add, {
                { prefix, group = "neorg-pm", buffer = buf },
            })
        end

        vim.keymap.set("n", prefix .. "r", "<cmd>NeorgPMRenumber<CR>",
            { buffer = buf, desc = "Renumber headings" })
        vim.keymap.set("n", prefix .. "R", "<cmd>NeorgPMRenumberProject<CR>",
            { buffer = buf, desc = "Renumber project" })
        vim.keymap.set("n", prefix .. "s", "<cmd>NeorgPMStatus<CR>",
            { buffer = buf, desc = "Update status" })
        vim.keymap.set("n", prefix .. "S", "<cmd>NeorgPMStatusAll<CR>",
            { buffer = buf, desc = "Update all status files" })
        vim.keymap.set("n", prefix .. "t", "<cmd>NeorgPMToggle<CR>",
            { buffer = buf, desc = "Toggle tree fold" })
        vim.keymap.set("n", prefix .. "e", "<cmd>NeorgPMExtract<CR>",
            { buffer = buf, desc = "Extract to directory" })
    end

    -- Fire User event for extensibility
    vim.api.nvim_exec_autocmds("User", { pattern = "NeorgPMAttach", data = { buf = buf } })

    -- Set up folds for status files (project.norg / index.norg)
    if fold.is_status_file(buf) then
        fold.setup_folds(buf)
    end

    --- Check if auto-renumbering should run for this buffer.
    --- Only renumbers if the file is inside a project OR already has numbered headings.
    local function should_auto_renumber()
        -- Always renumber if inside a project
        local filepath = vim.api.nvim_buf_get_name(buf)
        if filepath ~= "" and project.find_root(filepath) then
            return true
        end
        -- Check if the file already has numbered headings (user previously ran :NeorgPMRenumber)
        local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(20, vim.api.nvim_buf_line_count(buf)), false)
        for _, line in ipairs(lines) do
            if line:match("^%*+%s+%b()%s+%d") or line:match("^%*+%s+%d") then
                return true
            end
        end
        return false
    end

    -- Renumber on save (BufWritePre) — only if file is in a project or already numbered
    if M.config.renumber_on_save then
        vim.api.nvim_create_autocmd("BufWritePre", {
            buffer = buf,
            group = vim.api.nvim_create_augroup("NeorgPM_Save_" .. buf, { clear = true }),
            callback = function()
                if should_auto_renumber() then
                    numbering.renumber(buf)
                    M.refresh_virtual_text(buf)
                end
            end,
        })
    end

    -- Track heading modifications for renumber-on-leave
    if M.config.renumber_on_heading_leave then
        vim.api.nvim_buf_attach(buf, false, {
            on_lines = function(_, b, _, first_line)
                if not vim.api.nvim_buf_is_valid(b) then
                    return true -- detach
                end
                -- Check if the modified line is a heading (starts with one or more *)
                local line_text = vim.api.nvim_buf_get_lines(b, first_line, first_line + 1, false)[1]
                if line_text and line_text:match("^%*+%s") then
                    if M.state[b] then
                        M.state[b].dirty_heading_line = first_line
                    end
                end
            end,
            on_detach = function(_, b)
                if M.state[b] and M.state[b].timer then
                    M.state[b].timer:stop()
                    M.state[b].timer:close()
                end
                M.state[b] = nil
            end,
        })

        -- When cursor leaves a dirty heading line, trigger renumber
        vim.api.nvim_create_autocmd({ "CursorMoved", "InsertLeave" }, {
            buffer = buf,
            group = vim.api.nvim_create_augroup("NeorgPM_HeadingLeave_" .. buf, { clear = true }),
            callback = function()
                local state = M.state[buf]
                if not state or state.dirty_heading_line == nil then
                    return
                end

                local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
                if cursor_line ~= state.dirty_heading_line then
                    state.dirty_heading_line = nil
                    if should_auto_renumber() then
                        numbering.renumber(buf)
                        M.refresh_virtual_text(buf)
                    end
                end
            end,
        })
    end

    -- Refresh virtual text on text changes (debounced 150ms)
    vim.api.nvim_create_autocmd("TextChanged", {
        buffer = buf,
        group = vim.api.nvim_create_augroup("NeorgPM_TextChanged_" .. buf, { clear = true }),
        callback = function()
            M.schedule_refresh(buf)
        end,
    })
end

--- Schedule a debounced refresh of virtual text.
--- Multiple rapid changes result in only one refresh after 150ms of inactivity.
---
--- @param buf number  Buffer handle
function M.schedule_refresh(buf)
    local state = M.state[buf]
    if not state then
        return
    end

    if state.timer then
        state.timer:stop()
        state.timer:close()
    end

    state.timer = vim.uv.new_timer()
    state.timer:start(150, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "norg" then
            M.refresh_virtual_text(buf)
        end
        if state.timer then
            state.timer:stop()
            state.timer:close()
            state.timer = nil
        end
    end))
end

--- Refresh all virtual text indicators (mixed progress + prereqs).
--- Parses the buffer once and passes the root to both modules.
---
--- @param buf number  Buffer handle
function M.refresh_virtual_text(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    -- Clear existing virtual text
    vim.api.nvim_buf_clear_namespace(buf, M.ns.mixed, 0, -1)
    vim.api.nvim_buf_clear_namespace(buf, M.ns.prereqs, 0, -1)

    -- Parse once (shared by both modules)
    local helpers = require("neorg-project-manager.helpers")
    local root = helpers.get_norg_root(buf)
    if not root then
        return
    end

    -- Build number index from current file content (for prereq link resolution)
    local number_index = numbering.build_number_index(buf)

    -- Display mixed-type propagation indicators
    if M.config.mixed_propagation then
        mixed.refresh(buf, M.ns.mixed, M.config, root)
    end

    -- Display prerequisite tracking indicators
    if M.config.prerequisite_tracking then
        prereqs.refresh(buf, M.ns.prereqs, M.config, number_index, root)
    end
end

--- Auto-update the parent directory's index.norg when a content file is saved.
--- Uses surgical update (preserves manual content) or creates the file if missing.
--- Also cascades up to update project.norg.
--- Only operates if the file is within a detected project root.
---
--- @param filepath string  Absolute path to the saved file
function M.auto_update_parent_index(filepath)
    local root = project.find_root(filepath)
    if not root then
        return
    end

    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")
    local index_path = dir_path .. "/index.norg"

    -- Create or surgically update index.norg
    if vim.fn.filereadable(index_path) == 0 then
        -- Create new index.norg with full generation (direct children only)
        local dir_tree = status.build_directory_tree(dir_path)
        local idx_lines = status.render_as_norg(dir_tree, { max_depth = 2, base_level = 0 })
        vim.fn.writefile(idx_lines, index_path)
    else
        -- Surgical update: only touch managed headings
        status.update_file(index_path, dir_path, "index")
    end

    -- Same for project.norg at the root
    local project_path = root .. "/project.norg"
    if vim.fn.filereadable(project_path) == 0 then
        local project_tree = status.build_project_tree(root)
        local project_lines = status.render_as_norg(project_tree, { max_depth = 6, base_level = 0 })
        vim.fn.writefile(project_lines, project_path)
    else
        status.update_file(project_path, root, "project")
    end
end

return M
