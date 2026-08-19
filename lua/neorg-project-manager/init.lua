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
local breadcrumb = require("neorg-project-manager.breadcrumb")

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

    --- Anchor root headings: when true, level-1 headings in files without a
    --- prefix (standalone files, project.norg) preserve their existing numbers.
    --- Children are numbered relative to the anchor. Un-numbered level-1 headings
    --- get the next consecutive number after the previous anchor.
    ---
    --- Example: if you type "* 42. Project Alpha", children become 42.1, 42.2, etc.
    --- The next un-numbered level-1 heading becomes "43. ..."
    anchor_root_headings = true,

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
    --- nil = auto-detect by looking for a root-level numbered file in ancestor directories.
    --- string = explicit absolute path to project root.
    --- function(filepath) → string|nil = custom detection logic.
    project_root = nil,

    --- File prefix extraction.
    --- nil = auto-detect from filename using number_title_separator.
    --- string = use this fixed prefix for all files.
    --- function(filepath) → string|nil = custom extraction logic.
    file_prefix = nil,

    --- Rename confirmation threshold.
    --- If the number of file/dir renames exceeds this, a confirmation prompt is shown.
    rename_confirm_threshold = 5,

    ---------------------------------------------------------------------------
    --- BREADCRUMB / HEADING PATH
    ---------------------------------------------------------------------------

    --- Display mode for the heading breadcrumb path.
    ---   "statusline" — export M.get() for use in lualine (no auto-setup)
    ---   "winbar"     — show in vim.wo.winbar at top of window
    ---   "virtual"    — show as virtual text on the current heading line
    ---   "none"       — disabled (M.get() still works if called manually)
    breadcrumb_display = "statusline",

    --- Separator between path segments.
    breadcrumb_separator = " > ",

    --- Include full project path (directories + project root) in breadcrumb.
    --- Set to false for file-only context (current file headings only).
    breadcrumb_project_path = true,

    --- Custom format function for breadcrumb display.
    --- Receives a list of title strings, returns a formatted string.
    --- @type nil|fun(segments: string[]): string
    breadcrumb_format = nil,

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
    breadcrumb = vim.api.nvim_create_namespace("neorg-pm/breadcrumb"),
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

                -- Invalidate project index cache for this file
                idx.invalidate(filepath)

                -- Auto-update status files (circular prevention is inside the function)
                M.auto_update_parent_index(filepath)
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

    --- Regenerate status content in current buffer (status file).
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
    end, { desc = "Update status in current status file (preserves manual content)" })

    --- Regenerate ALL status files in the project.
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
    end, { desc = "Regenerate ALL status files in the project" })

    --- Toggle fold (collapse/expand) a tree element in status files.
    --- Hides body/description content while keeping all headings visible.
    vim.api.nvim_create_user_command("NeorgPMToggle", function()
        local buf = vim.api.nvim_get_current_buf()
        fold.toggle_body(buf)
    end, { desc = "Toggle body folds (show headings only, hide descriptions)" })

    --- Toggle full fold — collapse heading with ALL children (body + sub-headings).
    vim.api.nvim_create_user_command("NeorgPMToggleAll", function()
        local buf = vim.api.nvim_get_current_buf()
        fold.toggle_all(buf)
    end, { desc = "Toggle full fold (collapse/expand heading with all children)" })

    --- Extract a heading into its own .norg file.
    vim.api.nvim_create_user_command("NeorgPMExtract", function()
        local buf = vim.api.nvim_get_current_buf()
        extract.extract(buf)
    end, { desc = "Extract heading into its own file" })
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
            { buffer = buf, desc = "Toggle body folds (headings only)" })
        vim.keymap.set("n", prefix .. "T", "<cmd>NeorgPMToggleAll<CR>",
            { buffer = buf, desc = "Toggle full fold (collapse all)" })
        vim.keymap.set("n", prefix .. "e", "<cmd>NeorgPMExtract<CR>",
            { buffer = buf, desc = "Extract heading to file" })
    end

    -- Fire User event for extensibility
    vim.api.nvim_exec_autocmds("User", { pattern = "NeorgPMAttach", data = { buf = buf } })

    -- Set up folds for all norg buffers (heading-based folding with body toggle)
    fold.setup_folds(buf)

    -- Set up breadcrumb display
    local bc_display = M.config.breadcrumb_display
    if bc_display == "winbar" then
        breadcrumb.setup_winbar(buf)
    elseif bc_display == "virtual" then
        breadcrumb.setup_virtual_text(buf, M.ns.breadcrumb)
    end
    -- "statusline" needs no setup — user calls breadcrumb.get() from lualine

    --- Check if auto-renumbering should run for this buffer.
    --- Only renumbers if the file is inside a project OR already has numbered headings.
    --- Never renumbers status files (their headings are managed, not sequential).
    local function should_auto_renumber()
        local filepath = vim.api.nvim_buf_get_name(buf)
        if filepath == "" then
            return false
        end

        -- Never auto-renumber status files — their headings represent managed
        -- entries from companion files, not sequential document structure
        if project.is_status_file(filepath) then
            return false
        end

        -- Renumber if inside a project
        if project.find_root(filepath) then
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
        mixed.refresh(buf, M.ns.mixed, root)
    end

    -- Display prerequisite tracking indicators
    if M.config.prerequisite_tracking then
        prereqs.refresh(buf, M.ns.prereqs, number_index, root)
    end
end

--- Auto-update status files when a content file is saved.
--- Finds and surgically updates the status file for the saved file's directory,
--- then cascades up to the root status file.
--- Only operates if the file is within a detected project root.
---
--- @param filepath string  Absolute path to the saved file
function M.auto_update_parent_index(filepath)
    local root = project.find_root(filepath)
    if not root then
        return
    end

    -- Determine the root status file
    local root_status_file = project.find_status_file(root)

    -- Prevent circular self-update: if the saved file IS a status file, skip
    local saved_full = vim.fn.fnamemodify(filepath, ":p")
    if root_status_file and saved_full == vim.fn.fnamemodify(root_status_file, ":p") then
        return
    end

    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")

    -- Update subdirectory status file (if file is in a subdirectory, not at root)
    if vim.fn.fnamemodify(dir_path, ":p") ~= vim.fn.fnamemodify(root, ":p") then
        local dir_status_file = project.find_status_file(dir_path)
        -- Skip self-update but DON'T return — still cascade to root
        if dir_status_file and saved_full ~= vim.fn.fnamemodify(dir_status_file, ":p") then
            if vim.fn.filereadable(dir_status_file) == 1 then
                status.update_file(dir_status_file, dir_path, "index")
            end
        end
    end

    -- Update root status file
    if root_status_file and vim.fn.filereadable(root_status_file) == 1 then
        status.update_file(root_status_file, root, "project")
    end
end

return M
