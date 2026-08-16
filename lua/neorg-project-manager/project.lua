--- neorg-project-manager.project: Project structure utilities.
---
--- Handles:
---   - Project root detection (by locating `project.norg` in ancestor directories)
---   - Extracting number prefixes from filenames and directory names
---   - Scanning a project tree for all numbered entries
---   - Resolving a number to its target file (longest prefix match)
---
--- @module neorg-project-manager.project

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")

--- Get the configured number_title_separator.
--- @return string  The separator (default ". ")
local function get_title_separator()
    return config.get("number_title_separator", ". ")
end

---------------------------------------------------------------------------
--- PROJECT ROOT DETECTION
---------------------------------------------------------------------------

--- Find the project root by walking up from the given filepath.
--- The root is the directory containing a `project.norg` file.
---
--- @param filepath string  Absolute path to the current file
--- @return string|nil      Absolute path to the project root directory, or nil if not found
function M.find_root(filepath)
    -- Check config override first
    local project_root_cfg = config.get("project_root", nil)
    if project_root_cfg then
        if type(project_root_cfg) == "function" then
            return project_root_cfg(filepath)
        else
            return project_root_cfg
        end
    end

    -- Walk up from the file's directory looking for project.norg
    local dir = vim.fn.fnamemodify(filepath, ":p:h")

    -- Limit traversal to prevent infinite loops (max 20 levels)
    for _ = 1, 20 do
        local marker = dir .. "/project.norg"
        if vim.fn.filereadable(marker) == 1 then
            return dir
        end

        -- Move to parent directory
        local parent = vim.fn.fnamemodify(dir, ":h")
        if parent == dir then
            break -- Reached filesystem root
        end
        dir = parent
    end

    return nil
end

---------------------------------------------------------------------------
--- PREFIX EXTRACTION
---------------------------------------------------------------------------

--- Extract the number prefix and title from a filename or directory name.
--- Splits on the FIRST occurrence of `number_title_separator`.
---
--- Examples (with separator ". "):
---   "1.1.3.1. Stage 1.norg"  → prefix="1.1.3.1", title="Stage 1"
---   "1.1.3. Authentication"  → prefix="1.1.3",   title="Authentication"
---   "index.norg"             → prefix=nil,        title="index"
---   "project.norg"           → prefix=nil,        title="project"
---
--- @param name string  Filename (with or without extension) or directory name
--- @return string|nil  prefix  The number prefix, or nil if none found
--- @return string      title   The title portion (without number or extension)
function M.extract_prefix(name)
    -- Check config override
    local file_prefix_cfg = config.get("file_prefix", nil)
    if file_prefix_cfg then
        if type(file_prefix_cfg) == "function" then
            local prefix = file_prefix_cfg(name)
            if prefix then
                return prefix, name
            end
        elseif type(file_prefix_cfg) == "string" then
            return file_prefix_cfg, name
        end
    end

    -- Remove .norg extension if present
    local basename = name:gsub("%.norg$", "")

    local sep = get_title_separator()

    -- Find the first occurrence of the separator
    local sep_start, sep_end = basename:find(sep, 1, true)

    if sep_start and sep_start > 1 then
        local number_part = basename:sub(1, sep_start - 1)
        local title_part = basename:sub(sep_end + 1)

        -- Validate: number part should not contain spaces
        if not number_part:match("%s") then
            return number_part, title_part
        end
    end

    -- No valid prefix found
    return nil, basename
end

---------------------------------------------------------------------------
--- PROJECT SCANNING
---------------------------------------------------------------------------

--- Entry in the scanned project tree.
--- @class ProjectEntry
--- @field filepath string   Absolute path to the file or directory
--- @field prefix string|nil The number prefix extracted from the name
--- @field title string      The title portion of the name
--- @field is_dir boolean    Whether this entry is a directory
--- @field depth number      Depth of the prefix (number of separator-delimited parts)
--- @field name string       Original filename/dirname (without parent path)

--- Scan the project tree recursively and return all numbered entries.
--- Returns entries sorted by prefix (lexicographic on the prefix string).
--- Skips `project.norg`, `index.norg`, hidden files, and non-.norg files.
---
--- @param root string  Project root directory (absolute path)
--- @return ProjectEntry[]  Sorted list of entries
function M.scan(root)
    local entries = {}

    local function scan_dir(dir_path)
        local handle = vim.uv.fs_scandir(dir_path)
        if not handle then
            return
        end

        while true do
            local name, entry_type = vim.uv.fs_scandir_next(handle)
            if not name then
                break
            end

            -- Skip hidden files/dirs, index.norg, project.norg
            if name:sub(1, 1) == "." then
                goto continue
            end
            if name == "index.norg" or name == "project.norg" then
                goto continue
            end

            local full_path = dir_path .. "/" .. name

            if entry_type == "directory" then
                local prefix, title = M.extract_prefix(name)
                if prefix then
                    table.insert(entries, {
                        filepath = full_path,
                        prefix = prefix,
                        title = title,
                        is_dir = true,
                        depth = helpers.prefix_depth(prefix),
                        name = name,
                    })
                end
                -- Recurse into all directories (numbered or not)
                scan_dir(full_path)

            elseif entry_type == "file" and name:match("%.norg$") then
                local prefix, title = M.extract_prefix(name)
                if prefix then
                    table.insert(entries, {
                        filepath = full_path,
                        prefix = prefix,
                        title = title,
                        is_dir = false,
                        depth = helpers.prefix_depth(prefix),
                        name = name,
                    })
                end
            end

            ::continue::
        end
    end

    scan_dir(root)

    -- Sort by prefix (natural sort — handles "1.10" > "1.2" correctly)
    table.sort(entries, function(a, b)
        return helpers.natural_sort_prefixes(a.prefix, b.prefix)
    end)

    return entries
end

---------------------------------------------------------------------------
--- NUMBER RESOLUTION
---------------------------------------------------------------------------

--- Resolve a target number to a file using longest prefix match.
---
--- Given a target number like "1.1.3.1.2", finds the file with the longest
--- prefix that is contained in or equal to the target. The remainder after
--- the file prefix is the heading number within that file.
---
--- @param number string         Target number (e.g., "1.1.3.1.2")
--- @param entries ProjectEntry[] Scanned project entries (from M.scan())
--- @return table|nil            {filepath=string, prefix=string, remainder=string|nil}
---                              remainder is nil if number matches prefix exactly
function M.resolve_number_to_file(number, entries)
    local best_match = nil
    local best_prefix_len = 0

    local sep = config.get("number_separator", ".")

    for _, entry in ipairs(entries) do
        if entry.is_dir then
            goto continue
        end

        local prefix = entry.prefix

        -- Check if the target number starts with this file's prefix
        if number == prefix then
            -- Exact match — target is this file itself
            return {
                filepath = entry.filepath,
                prefix = prefix,
                remainder = nil,
            }
        elseif number:sub(1, #prefix + #sep) == prefix .. sep then
            -- Target starts with this prefix followed by separator
            -- e.g., target "1.1.3.1.2", prefix "1.1.3.1", sep "."
            if #prefix > best_prefix_len then
                best_prefix_len = #prefix
                best_match = {
                    filepath = entry.filepath,
                    prefix = prefix,
                    remainder = number:sub(#prefix + #sep + 1),
                }
            end
        end

        ::continue::
    end

    return best_match
end

--- Get the prefix depth (number of parts).
--- Delegates to helpers.prefix_depth().
---
--- @param prefix string|nil  The prefix string
--- @param sep string|nil     Unused (kept for backward compatibility)
--- @return number            Depth (0 if prefix is nil)
function M.prefix_depth(prefix, sep)
    return helpers.prefix_depth(prefix)
end

return M
