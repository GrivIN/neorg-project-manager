--- neorg-project-manager.extract: Extract a heading's content into its own file.
---
--- Takes a heading in a status file (or any .norg file) and extracts
--- its children into a standalone .norg file. The heading line stays in place
--- (with its {* number} link for navigation), and the content below it moves
--- to the new file with heading levels shifted to start from *.
---
--- Example:
---   status file has: *** (-) 1.1.1. Auth {* 1.1.1}
---                    **** (-) 1.1.1.1. Login {* 1.1.1.1}
---                    ***** (x) 1.1.1.1.1. Design
---
---   After extract: status file keeps the heading line only.
---   New file "1.1.1. Auth.norg" gets the children (stars shifted by 3):
---                     * (-) 1.1.1.1. Login {* 1.1.1.1}
---                     ** (x) 1.1.1.1.1. Design
---
--- @module neorg-project-manager.extract

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")
local project = require("neorg-project-manager.project")
local status = require("neorg-project-manager.status")
local idx = require("neorg-project-manager.index")
local numbering = require("neorg-project-manager.numbering")

---------------------------------------------------------------------------
--- FILESYSTEM UTILITIES
---------------------------------------------------------------------------

--- Sanitize a string for use as a filename.
--- Strips norg-specific syntax (links, progress counts, brackets) and replaces
--- filesystem-unsafe characters. Trims trailing spaces and dots.
---
--- @param name string  The raw name (e.g., a heading title)
--- @return string      Sanitized name safe for use in file paths
local function sanitize_filename(name)
    -- Strip norg link syntax: {* number}, {*** number}, etc.
    local sanitized = name:gsub("{%*+%s+[^}]+}", "")
    -- Strip progress counts: [3/5]
    sanitized = sanitized:gsub("%[%d+/%d+%]", "")
    -- Strip parenthesized annotations: (app/auth/), (optional), etc.
    sanitized = sanitized:gsub("%b()", "")
    -- Strip remaining brackets and braces
    sanitized = sanitized:gsub("[{}%[%]]", "")
    -- Replace filesystem-unsafe characters with underscore
    sanitized = sanitized:gsub('[/\\:*?"<>|]', "_")
    -- Collapse multiple spaces/underscores into one space
    sanitized = sanitized:gsub("[%s_]+", " ")
    -- Trim leading/trailing whitespace
    sanitized = vim.trim(sanitized)
    -- Trim trailing dots (Windows restriction)
    sanitized = sanitized:gsub("%.+$", "")
    return sanitized
end

---------------------------------------------------------------------------
--- TARGET RESOLUTION
---------------------------------------------------------------------------

--- Resolve the target number from the cursor position in a status file.
---
--- @param buf number  Buffer handle
--- @return string|nil number    The target entry number (e.g., "1.1.3.1")
--- @return string|nil root      Project root path
--- @return string|nil error     Error message if resolution failed
function M.resolve_target_number(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        return nil, nil, "Buffer has no filename"
    end

    local root = project.find_root(filepath)
    if not root then
        return nil, nil, "No project root found (no root-level numbered file in ancestor directories)"
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")
    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")

    -- From a status file: read the link on the cursor line
    local status_file = project.find_status_file(dir_path)
    local is_status = status_file and vim.fn.fnamemodify(status_file, ":t") == filename

    if is_status then
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
        local line = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1]
        if not line then
            return nil, nil, "No line at cursor position"
        end

        -- Extract {* number} link from the line
        local number = helpers.extract_link_number_from_line(line)
        if not number then
            -- Try to extract prefix from heading text directly
            local heading_text = line:match("^%*+%s+%(?[^%)]*%)?%s*(.*)")
                or line:match("^%*+%s+(.*)")
            if heading_text then
                local prefix_from_text, _ = numbering.parse_number_and_title(heading_text)
                number = prefix_from_text
            end
        end

        if not number then
            return nil, nil, "No number/link found on current line"
        end

        return number, root, nil
    end

    -- From a content file: use the file's own prefix
    local prefix, _ = project.extract_prefix(filename)
    if not prefix then
        return nil, nil, "File has no number prefix in its name"
    end

    return prefix, root, nil
end

---------------------------------------------------------------------------
--- ENTRY LOCATION
---------------------------------------------------------------------------

--- Information about a located entry within a file.
--- @class EntryLocation
--- @field filepath string       Path to the file containing this entry
--- @field file_prefix string|nil The file's own prefix
--- @field entry_number string   The full number of the entry
--- @field entry_title string    The title of the entry heading
--- @field heading_level number  The heading level (number of *)
--- @field start_line number     1-indexed line where the entry heading starts
--- @field end_line number       1-indexed line where the entry ends (exclusive)
--- @field is_file_level boolean True if entry_number == file_prefix (entry IS the whole file)

--- Search for a heading with a specific number inside a file.
--- Returns an EntryLocation if found, nil otherwise.
---
--- @param filepath string       Path to the file to search
--- @param file_prefix string|nil The file's own prefix (nil for status files)
--- @param number string         The heading number to find
--- @return EntryLocation|nil    Location info
--- @return string|nil           Error message
function M._find_heading_in_file(filepath, file_prefix, number)
    local lines = vim.fn.readfile(filepath)
    if #lines == 0 then
        return nil, nil
    end

    local target_level = nil
    local target_title = nil
    local target_start = nil
    local target_end = nil

    for i, line in ipairs(lines) do
        local stars = line:match("^(%*+)%s")
        if stars then
            local heading_text = line:match("^%*+%s+(.*)$")
            local content = heading_text

            -- Strip todo state
            local _, rest = heading_text:match("^%((.-)%)%s+(.*)")
            if rest then
                content = rest
            end

            local num, title, _ = numbering.parse_number_and_title(content)

            -- Also check if the number is in a {* number} link on this line
            if not num or num ~= number then
                local link_num = helpers.extract_link_number_from_line(line)
                if link_num == number and num then
                    -- The link matches and heading has a parsed number — use it
                elseif link_num == number and not num then
                    -- Link matches but no number prefix in title — use content as title
                    title = content
                    num = link_num
                else
                    -- No match — check if this is end of section
                    if target_start and #stars <= target_level then
                        target_end = i
                        break
                    end
                    goto continue
                end
            end

            -- Clean link syntax and progress counts from the title
            if title then
                title = title:gsub("%s*{%*+%s+[^}]+}%s*", "")
                title = title:gsub("%s*%[%d+/%d+%]%s*$", "")
                title = vim.trim(title)
            end

            if num == number then
                if target_start then
                    -- Already found — this is the end marker (same number shouldn't repeat)
                    target_end = i
                    break
                end
                target_level = #stars
                target_title = title
                target_start = i
            elseif target_start and #stars <= target_level then
                target_end = i
                break
            end
        end
        ::continue::
    end

    if not target_start then
        return nil, nil
    end

    if not target_end then
        target_end = #lines + 1
    end

    return {
        filepath = filepath,
        file_prefix = file_prefix,
        entry_number = number,
        entry_title = target_title,
        heading_level = target_level,
        start_line = target_start,
        end_line = target_end,
        is_file_level = false,
    }, nil
end

--- Locate an entry within the project: find which file contains it and where.
---
--- @param number string          The entry number to find (e.g., "1.1.3.1")
--- @param root string            Project root path
--- @return EntryLocation|nil     Location info, or nil if not found
--- @return string|nil            Error message
function M.locate_entry(number, root)
    local entries = project.scan(root)

    -- Case 1: number IS a file prefix (entry = entire file, already extracted)
    for _, entry in ipairs(entries) do
        if not entry.is_dir and entry.prefix == number then
            local lines = vim.fn.readfile(entry.filepath)
            return {
                filepath = entry.filepath,
                file_prefix = entry.prefix,
                entry_number = number,
                entry_title = entry.title,
                heading_level = nil,
                start_line = 1,
                end_line = #lines + 1,
                is_file_level = true,
            }, nil
        end
    end

    -- Case 1b: number IS a directory prefix — already extracted
    for _, entry in ipairs(entries) do
        if entry.is_dir and entry.prefix == number then
            return nil, string.format(
                "Entry '%s' (%s/) is already a directory — nothing to extract.",
                number, entry.title
            )
        end
    end

    -- Case 2: number is a heading inside a content file — use longest prefix match
    local resolved = project.resolve_number_to_file(number, entries)
    if resolved then
        local stat = vim.uv.fs_stat(resolved.filepath)
        if stat and stat.type == "file" then
            local found, err = M._find_heading_in_file(resolved.filepath, resolved.prefix, number)
            if found then return found, nil end
            if err then return nil, err end
        end
    end

    -- Case 3: number is a heading inside a status file
    local status_files = {}
    local root_status = project.find_status_file(root)
    if root_status and vim.fn.filereadable(root_status) == 1 then
        table.insert(status_files, root_status)
    end

    local function find_status_files(dir)
        local dir_status = project.find_status_file(dir)
        if dir_status and vim.fn.filereadable(dir_status) == 1 then
            -- Avoid duplicating the root status file
            if dir_status ~= root_status then
                table.insert(status_files, dir_status)
            end
        end
        helpers.scandir(dir, function(name, entry_type, full_path)
            if entry_type == "directory" then
                find_status_files(full_path)
            end
        end)
    end
    find_status_files(root)

    for _, status_filepath in ipairs(status_files) do
        local found, _ = M._find_heading_in_file(status_filepath, nil, number)
        if found then return found, nil end
    end

    return nil, string.format("Cannot resolve '%s' to any file or heading in the project", number)
end

---------------------------------------------------------------------------
--- EXTRACTION
---------------------------------------------------------------------------

--- Execute the extraction: create file, remove content from source.
---
--- @param location EntryLocation  The located entry
--- @return boolean success
--- @return string|nil error
local function execute_extraction(location)
    local title_sep = config.get("number_title_separator", ". ")
    local parent_dir = vim.fn.fnamemodify(location.filepath, ":p:h")

    -- Build target filename
    local file_name = location.entry_number .. title_sep
        .. sanitize_filename(location.entry_title) .. ".norg"
    local file_path = parent_dir .. "/" .. file_name

    -- Abort if target file already exists
    if vim.uv.fs_stat(file_path) then
        return false, string.format("File already exists: %s", file_name)
    end

    -- Read source file
    local source_lines = vim.fn.readfile(location.filepath)

    -- Build root heading: the entry heading shifted to level 1, with link/count stripped
    local heading_line = source_lines[location.start_line]
    local root_heading
    do
        local stars, rest = heading_line:match("^(%*+)(%s.*)$")
        if stars then
            -- Shift to level 1
            root_heading = "*" .. rest
        else
            root_heading = heading_line
        end
        -- Strip {* number} link syntax (status-file artifact)
        root_heading = root_heading:gsub("%s*{%*+%s+[^}]+}", "")
        -- Strip [N/M] progress count (status-file artifact)
        root_heading = root_heading:gsub("%s*%[%d+/%d+%]%s*$", "")
    end

    -- Extract section content (children below the heading)
    -- Shift = heading_level - 1 (root heading takes level 1, children start at level 2)
    local content = { root_heading }
    local shift = location.heading_level - 1

    for i = location.start_line + 1, location.end_line - 1 do
        local line = source_lines[i]
        -- Shift heading stars (keep numbering and everything else untouched)
        local stars, rest = line:match("^(%*+)(%s.*)$")
        if stars then
            local new_level = #stars - shift
            if new_level < 1 then
                new_level = 1
            end
            line = string.rep("*", new_level) .. rest
        end
        table.insert(content, line)
    end

    -- Remove trailing empty lines from content
    while #content > 0 and content[#content] == "" do
        table.remove(content)
    end

    -- Write new file
    vim.fn.writefile(content, file_path)

    -- Remove children from source (keep heading line at start_line)
    local new_source = {}
    for i = 1, location.start_line do
        table.insert(new_source, source_lines[i])
    end
    for i = location.end_line, #source_lines do
        table.insert(new_source, source_lines[i])
    end
    vim.fn.writefile(new_source, location.filepath)

    -- Invalidate caches
    idx.invalidate(location.filepath)
    idx.invalidate_project_cache()

    -- Update status files if applicable
    local root = project.find_root(file_path)
    if root then
        local root_status = project.find_status_file(root)
        if root_status and vim.fn.filereadable(root_status) == 1 and location.filepath ~= root_status then
            status.update_file(root_status, root, "project")
        end
    end

    return true, nil
end

---------------------------------------------------------------------------
--- MAIN ENTRY
---------------------------------------------------------------------------

--- Extract a heading's content into its own .norg file.
--- The heading line stays in place (for navigation via its link),
--- and all content below it moves to the new file with heading levels shifted.
---
--- @param buf number|nil  Buffer handle (defaults to current buffer)
function M.extract(buf)
    buf = buf or vim.api.nvim_get_current_buf()

    -- Resolve target number from cursor
    local number, root, err = M.resolve_target_number(buf)
    if not number then
        vim.notify("NeorgPMExtract: " .. (err or "Unknown error"), vim.log.levels.ERROR)
        return
    end

    -- Locate the entry in the project
    local location, loc_err = M.locate_entry(number, root)
    if not location then
        vim.notify("NeorgPMExtract: " .. (loc_err or "Unknown error"), vim.log.levels.ERROR)
        return
    end

    -- Entry is already a standalone file — nothing to extract
    if location.is_file_level then
        vim.notify(
            string.format("NeorgPMExtract: Entry '%s' is already a file — nothing to extract.", number),
            vim.log.levels.WARN
        )
        return
    end

    -- Section has no content below the heading
    if location.end_line - location.start_line <= 1 then
        vim.notify(
            string.format("NeorgPMExtract: Entry '%s' has no content below it to extract.", number),
            vim.log.levels.WARN
        )
        return
    end

    -- Build preview
    local title_sep = config.get("number_title_separator", ". ")
    local file_name = location.entry_number .. title_sep
        .. sanitize_filename(location.entry_title) .. ".norg"
    local source_name = vim.fn.fnamemodify(location.filepath, ":t")
    local line_count = location.end_line - location.start_line - 1

    -- Show confirmation
    vim.ui.select({ "Yes", "No" }, {
        prompt = string.format(
            "Extract '%s' (%d lines) → %s? ",
            number, line_count, file_name
        ),
    }, function(choice)
        if choice == "Yes" then
            local ok, extract_err = execute_extraction(location)
            if ok then
                vim.notify(
                    string.format("Extracted → %s", file_name),
                    vim.log.levels.INFO
                )

                -- Refresh current buffer if it's the source file
                local current_buf = vim.api.nvim_get_current_buf()
                if vim.api.nvim_buf_is_valid(current_buf)
                    and vim.api.nvim_buf_get_name(current_buf) == location.filepath then
                    vim.cmd("edit!")
                end
            else
                vim.notify("NeorgPMExtract: " .. (extract_err or "Unknown error"), vim.log.levels.ERROR)
            end
        end
    end)
end

return M
