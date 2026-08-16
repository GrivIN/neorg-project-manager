--- neorg-project-manager.rename: Project-wide file/directory renaming.
---
--- Provides `:NeorgPMRenumberProject` which:
---   1. Scans all numbered files/directories in the project
---   2. Determines correct sequential numbering per directory
---   3. Shows confirmation if many renames are needed
---   4. Renames files/directories using temp suffix to avoid collisions
---   5. Updates all {* number} links across all project files
---   6. Regenerates all index.norg + project.norg files
---
--- Collision avoidance uses a two-phase rename:
---   Phase 1: old_name → old_name.neorg_tmp
---   Phase 2: old_name.neorg_tmp → new_name
---
--- @module neorg-project-manager.rename

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")
local project = require("neorg-project-manager.project")
local status = require("neorg-project-manager.status")
local idx = require("neorg-project-manager.index")

--- Temporary suffix used during rename to avoid collisions.
local TEMP_SUFFIX = ".neorg_tmp"

---------------------------------------------------------------------------
--- RENAME COMPUTATION
---------------------------------------------------------------------------

--- Compute the correct sequential numbering for all entries within a single directory.
--- Returns a list of rename operations needed.
---
--- @param dir_path string  Directory to process
--- @return table[]         List of {old_path, new_path, old_prefix, new_prefix}
local function compute_dir_renames(dir_path)
    local renames = {}

    -- Get the parent prefix (from the directory name itself)
    local dir_name = vim.fn.fnamemodify(dir_path, ":t")
    local parent_prefix, _ = project.extract_prefix(dir_name)

    -- Scan direct entries in this directory
    local entries = {}
    local handle = vim.uv.fs_scandir(dir_path)
    if not handle then
        return renames
    end

    while true do
        local name, entry_type = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if name:sub(1, 1) == "." or name == "index.norg" or name == "project.norg" then
            goto continue
        end

        local prefix, title = project.extract_prefix(name)
        if prefix then
            table.insert(entries, {
                name = name,
                prefix = prefix,
                title = title,
                entry_type = entry_type,
                full_path = dir_path .. "/" .. name,
            })
        end

        ::continue::
    end

    -- Sort by existing prefix (natural sort for correct ordering at 10+ items)
    local h = require("neorg-project-manager.helpers")
    table.sort(entries, function(a, b)
        return h.natural_sort_prefixes(a.prefix, b.prefix)
    end)

    -- Assign correct sequential numbers
    local numbering = require("neorg-project-manager.numbering")
    local title_sep = config.get("number_title_separator", ". ")

    for i, entry in ipairs(entries) do
        local correct_prefix = numbering.format_prefix_for_position(parent_prefix, i)

        -- Build the correct filename/dirname
        local correct_name
        if entry.entry_type == "directory" then
            correct_name = correct_prefix .. title_sep .. entry.title
        else
            correct_name = correct_prefix .. title_sep .. entry.title .. ".norg"
        end

        -- Check if rename is needed
        if entry.name ~= correct_name then
            table.insert(renames, {
                old_path = entry.full_path,
                new_path = dir_path .. "/" .. correct_name,
                old_prefix = entry.prefix,
                new_prefix = correct_prefix,
            })
        end
    end

    return renames
end

--- Compute all renames needed for the entire project (recursive).
---
--- @param root_path string  Project root directory
--- @return table[]          All rename operations: {old_path, new_path, old_prefix, new_prefix}
--- @return table            old_to_new prefix mapping for link updates
function M.compute(root_path)
    local all_renames = {}
    local old_to_new = {} -- Maps old prefixes to new prefixes

    --- Process a directory and all its subdirectories (depth-first).
    local function process_dir(dir_path)
        -- First, process subdirectories (depth-first so child renames happen before parent)
        local handle = vim.uv.fs_scandir(dir_path)
        if not handle then return end

        local subdirs = {}
        while true do
            local name, entry_type = vim.uv.fs_scandir_next(handle)
            if not name then break end
            if entry_type == "directory" and name:sub(1, 1) ~= "." then
                table.insert(subdirs, dir_path .. "/" .. name)
            end
        end

        for _, subdir in ipairs(subdirs) do
            process_dir(subdir)
        end

        -- Then compute renames for this directory's direct entries
        local renames = compute_dir_renames(dir_path)
        for _, r in ipairs(renames) do
            table.insert(all_renames, r)
            if r.old_prefix ~= r.new_prefix then
                old_to_new[r.old_prefix] = r.new_prefix
            end
        end
    end

    process_dir(root_path)
    return all_renames, old_to_new
end

---------------------------------------------------------------------------
--- RENAME EXECUTION
---------------------------------------------------------------------------

--- Execute file/directory renames using temp suffix to avoid collisions.
--- Strategy: rename FILES first (deepest first), then DIRECTORIES (deepest first).
--- This avoids the problem of renaming a parent dir invalidating child paths.
---
--- Within each category (files, then dirs), uses two-phase rename:
---   Phase 1: old_name → old_name.neorg_tmp
---   Phase 2: old_name.neorg_tmp → new_name
---
--- @param renames table[]  List of {old_path, new_path} operations
--- @return boolean         True if all renames succeeded
function M.execute_renames(renames)
    if #renames == 0 then
        return true
    end

    -- Separate files from directories
    local file_renames = {}
    local dir_renames = {}
    for _, r in ipairs(renames) do
        -- Check if old_path is a directory
        local stat = vim.uv.fs_stat(r.old_path)
        if stat and stat.type == "directory" then
            table.insert(dir_renames, r)
        else
            table.insert(file_renames, r)
        end
    end

    -- Sort files deepest first (by path length as proxy for depth)
    table.sort(file_renames, function(a, b)
        return #a.old_path > #b.old_path
    end)
    -- Sort directories deepest first
    table.sort(dir_renames, function(a, b)
        return #a.old_path > #b.old_path
    end)

    --- Two-phase rename for a list of entries.
    --- @param entries table[]
    --- @return boolean
    local function two_phase_rename(entries)
        -- Phase 1: rename to temp
        local temp_map = {} -- temp_path → final_path
        for _, r in ipairs(entries) do
            local temp_path = r.old_path .. TEMP_SUFFIX
            local ok, err = os.rename(r.old_path, temp_path)
            if not ok then
                vim.notify(
                    string.format("Rename failed: %s → temp\nError: %s", r.old_path, err or "unknown"),
                    vim.log.levels.ERROR
                )
                -- Rollback this phase
                for tp, _ in pairs(temp_map) do
                    os.rename(tp, tp:gsub(TEMP_SUFFIX .. "$", ""))
                end
                return false
            end
            temp_map[temp_path] = r.new_path
        end

        -- Phase 2: rename from temp to final
        for temp_path, final_path in pairs(temp_map) do
            local parent_dir = vim.fn.fnamemodify(final_path, ":h")
            vim.fn.mkdir(parent_dir, "p")

            local ok, err = os.rename(temp_path, final_path)
            if not ok then
                vim.notify(
                    string.format("Rename phase 2 failed: %s → %s\nError: %s", temp_path, final_path, err or "unknown"),
                    vim.log.levels.ERROR
                )
                return false
            end
        end
        return true
    end

    -- Rename files first (they're inside directories that haven't changed yet)
    if not two_phase_rename(file_renames) then
        return false
    end

    -- Then rename directories (deepest first, so children are processed before parents)
    if not two_phase_rename(dir_renames) then
        return false
    end

    return true
end

--- Update all {* number} links in all .norg files under root_path.
--- Replaces old prefix references with new ones.
---
--- @param root_path string  Project root directory
--- @param old_to_new table  Maps old prefix strings to new prefix strings
function M.update_all_links(root_path, old_to_new)
    if vim.tbl_isempty(old_to_new) then
        return
    end

    --- Recursively find all .norg files
    local function find_norg_files(dir)
        local files = {}
        local handle = vim.uv.fs_scandir(dir)
        if not handle then return files end

        while true do
            local name, entry_type = vim.uv.fs_scandir_next(handle)
            if not name then break end
            if name:sub(1, 1) == "." then goto continue end

            local full = dir .. "/" .. name
            if entry_type == "file" and name:match("%.norg$") then
                table.insert(files, full)
            elseif entry_type == "directory" then
                vim.list_extend(files, find_norg_files(full))
            end

            ::continue::
        end
        return files
    end

    local files = find_norg_files(root_path)
    local sep = config.get("number_separator", ".")

    for _, filepath in ipairs(files) do
        local lines = vim.fn.readfile(filepath)

        local _, modified = helpers.replace_link_numbers(lines, function(trimmed)
            -- Find longest matching old prefix
            local best_old, best_new = nil, nil
            for old, new in pairs(old_to_new) do
                if trimmed == old or trimmed:sub(1, #old + #sep) == old .. sep then
                    if not best_old or #old > #best_old then
                        best_old = old
                        best_new = new
                    end
                end
            end

            if best_old then
                if trimmed == best_old then
                    return best_new
                else
                    return best_new .. trimmed:sub(#best_old + 1)
                end
            end
            return nil
        end)

        if modified then
            vim.fn.writefile(lines, filepath)
        end
    end
end

---------------------------------------------------------------------------
--- MAIN ENTRY
---------------------------------------------------------------------------

--- Renumber the entire project: files, directories, links, and status files.
--- Shows confirmation if the number of renames exceeds the configured threshold.
---
--- @param buf number  Current buffer (for project root detection)
function M.renumber_project(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project.find_root(filepath)
    if not root then
        vim.notify("No project root found (no project.norg in ancestor directories)", vim.log.levels.ERROR)
        return
    end

    -- Compute all needed renames
    local renames, old_to_new = M.compute(root)

    if #renames == 0 then
        vim.notify("Project numbering is already correct — nothing to rename.", vim.log.levels.INFO)
        return
    end

    -- Count link updates
    local link_count = vim.tbl_count(old_to_new)
    local threshold = config.get("rename_confirm_threshold", 5)

    --- Execute the full renumber pipeline
    local function execute()
        -- 1. Execute file/dir renames
        local ok = M.execute_renames(renames)
        if not ok then
            return
        end

        -- 2. Update links in all files
        M.update_all_links(root, old_to_new)

        -- 3. Rebuild project index cache
        idx.rebuild()

        -- 4. Regenerate all status files (index.norg + project.norg)
        status.regenerate_all(root)

        vim.notify(
            string.format("Project renumbered: %d files/dirs renamed, %d prefix mappings updated.", #renames, link_count),
            vim.log.levels.INFO
        )
    end

    -- Show confirmation if threshold exceeded
    if #renames > threshold then
        local msg = string.format(
            "%d files/dirs will be renamed, %d prefix mappings will update links.\nProceed?",
            #renames, link_count
        )
        vim.ui.select({ "Yes", "No", "Show details" }, { prompt = msg }, function(choice)
            if choice == "Yes" then
                execute()
            elseif choice == "Show details" then
                -- Show rename preview
                local preview_lines = { "Planned renames:" }
                for _, r in ipairs(renames) do
                    table.insert(preview_lines, string.format("  %s → %s",
                        vim.fn.fnamemodify(r.old_path, ":t"),
                        vim.fn.fnamemodify(r.new_path, ":t")))
                end
                vim.notify(table.concat(preview_lines, "\n"), vim.log.levels.INFO)
            end
        end)
    else
        execute()
    end
end

return M
