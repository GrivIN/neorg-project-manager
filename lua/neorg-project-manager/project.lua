--- neorg-project-manager.project: Project structure utilities.
---
--- Handles:
---   - Project root detection (by locating a root-level numbered file)
---   - Status file detection (file whose prefix matches its directory)
---   - Extracting number prefixes from filenames and directory names
---   - Scanning a project tree for all numbered entries
---   - Resolving a number to its target file (longest prefix match)
---
--- @module neorg-project-manager.project

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")

---------------------------------------------------------------------------
--- STATUS FILE DETECTION
---------------------------------------------------------------------------

--- Find the status file for a directory.
---
--- A "status file" is a `.norg` file that serves as the overview/index for
--- its containing directory. Detection rules:
---   - For the project root (directory name has no number prefix): the file
---     with a depth-1 prefix (no separator), e.g., `42. ACME App.norg`
---   - For numbered subdirectories: the file whose prefix matches the
---     directory's own prefix, e.g., `42.2. Chat.norg` inside `42.2. Chat/`
---
--- @param dir string  Absolute path to the directory
--- @return string|nil  Absolute path to the status file, or nil if none found
function M.find_status_file(dir)
    local sep = config.get("number_separator", ".")
    local dir_name = vim.fn.fnamemodify(dir, ":t")
    local dir_prefix, _ = M.extract_prefix(dir_name)

    local result = nil
    helpers.scandir(dir, function(name, entry_type)
        if entry_type == "file" and name:match("%.norg$") then
            local file_prefix, _ = M.extract_prefix(name)
            if file_prefix then
                if dir_prefix then
                    if file_prefix == dir_prefix then
                        result = dir .. "/" .. name
                        return false
                    end
                else
                    if not file_prefix:find(sep, 1, true) then
                        result = dir .. "/" .. name
                        return false
                    end
                end
            end
        end
    end)

    return result
end

---------------------------------------------------------------------------
--- PROJECT ROOT DETECTION
---------------------------------------------------------------------------

--- Find the project root by walking up from the given filepath.
--- The root is the directory containing a root-level numbered file
--- (a `.norg` file with a single-part prefix, e.g., `42. App.norg`).
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

    local sep = config.get("number_separator", ".")

    -- Walk up from the file's directory looking for a root-level status file
    local dir = vim.fn.fnamemodify(filepath, ":p:h")

    -- Limit traversal to prevent infinite loops (max 20 levels)
    for _ = 1, 20 do
        local status_file = M.find_status_file(dir)
        if status_file then
            -- Verify this is a ROOT status file (depth-1 prefix, not a subdir status file)
            local status_name = vim.fn.fnamemodify(status_file, ":t")
            local status_prefix, _ = M.extract_prefix(status_name)
            if status_prefix and not status_prefix:find(sep, 1, true) then
                return dir
            end
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
---   "notes.norg"             → prefix=nil,        title="notes"
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

    local sep = config.get("number_title_separator", ". ")

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
--- Returns entries sorted by prefix (natural sort).
--- Skips hidden files and non-.norg files. All numbered .norg files are
--- included (including status files) so they participate in link resolution.
---
--- @param root string  Project root directory (absolute path)
--- @return ProjectEntry[]  Sorted list of entries
function M.scan(root)
    local entries = {}

    local function scan_dir(dir_path)
        helpers.scandir(dir_path, function(name, entry_type, full_path)
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
        end)
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

--- Check if a filepath is the status file for its containing directory.
---
--- @param filepath string  Absolute path to check
--- @return boolean         True if this file is its directory's status file
function M.is_status_file(filepath)
    if not filepath or filepath == "" then
        return false
    end
    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")
    local status_file = M.find_status_file(dir_path)
    if not status_file then
        return false
    end
    return vim.fn.fnamemodify(filepath, ":p") == vim.fn.fnamemodify(status_file, ":p")
end

return M
