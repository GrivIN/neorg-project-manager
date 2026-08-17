--- neorg-project-manager.extract: Extract an entry and its sub-entries into a directory.
---
--- Takes a specific numbered entry (e.g., "1.1.3.1" which is a heading inside
--- "1.1.3. Authentication.norg") and extracts it with its children into a new
--- directory structure:
---
---   Before: 1.1.3. Authentication.norg contains headings 1.1.3.1, 1.1.3.2
---   Extract entry 1.1.3.1 (which has sub-headings 1.1.3.1.1, 1.1.3.1.2):
---
---   After:  1.1.3. Authentication.norg  (still has 1.1.3.2, but 1.1.3.1 removed)
---           1.1.3.1. Login Flow/
---             ├── index.norg
---             ├── 1.1.3.1.1. Design.norg
---             └── 1.1.3.1.2. Backend.norg
---
--- If extracting an entry whose number IS the file prefix (i.e., the entire file),
--- the whole file becomes a directory and the original file is removed.
---
--- Triggered from cursor position in project.norg/index.norg (reads the {* number}
--- link to identify the target entry).
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

--- Sanitize a string for use as a filename/directory name.
--- Replaces characters that are unsafe on common filesystems (/ \ : * ? " < > |)
--- with underscores. Also trims trailing spaces and dots (Windows restriction).
---
--- @param name string  The raw name (e.g., a heading title)
--- @return string      Sanitized name safe for use in file paths
local function sanitize_filename(name)
    -- Replace filesystem-unsafe characters with underscore
    local sanitized = name:gsub('[/\\:*?"<>|]', "_")
    -- Trim trailing spaces and dots (problematic on Windows)
    sanitized = sanitized:gsub("[%.%s]+$", "")
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
        return nil, nil, "No project root found (no project.norg in ancestor directories)"
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")

    -- From a status file: read the link on the cursor line
    if filename == "project.norg" or filename == "index.norg" then
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
    -- (Defensive: index.norg is handled above as a status file, but guard anyway)
    if filename == "index.norg" then
        return nil, nil, "Cannot extract from index.norg"
    end

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
--- @field file_prefix string    The file's own prefix
--- @field entry_number string   The full number of the entry
--- @field entry_title string    The title of the entry heading
--- @field heading_level number  The heading level (number of *)
--- @field start_line number     1-indexed line where the entry heading starts
--- @field end_line number       1-indexed line where the entry ends (exclusive)
--- @field is_file_level boolean True if entry_number == file_prefix (entry IS the whole file)

--- Locate an entry within the project: find which file contains it and where.
---
--- @param number string          The entry number to find (e.g., "1.1.3.1")
--- @param root string            Project root path
--- @return EntryLocation|nil     Location info, or nil if not found
--- @return string|nil            Error message
function M.locate_entry(number, root)
    local entries = project.scan(root)
    local sep = config.get("number_separator", ".")

    -- Case 1: number IS a file prefix (entry = entire file)
    for _, entry in ipairs(entries) do
        if not entry.is_dir and entry.prefix == number then
            local lines = vim.fn.readfile(entry.filepath)
            return {
                filepath = entry.filepath,
                file_prefix = entry.prefix,
                entry_number = number,
                entry_title = entry.title,
                heading_level = nil, -- entire file
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
                "Entry '%s' (%s/) is already a directory — nothing to extract.\n"
                .. "Use :NeorgPMExtract on a file entry or a heading within a file.",
                number, entry.title
            )
        end
    end

    -- Case 2: number is a heading inside a file — use longest prefix match
    local resolved = project.resolve_number_to_file(number, entries)
    if not resolved then
        return nil, string.format("Cannot resolve '%s' to any file in the project", number)
    end

    -- Verify it's a file
    local stat = vim.uv.fs_stat(resolved.filepath)
    if not stat or stat.type ~= "file" then
        return nil, string.format("'%s' resolves to a directory, not a file", number)
    end

    -- Parse the file to find the heading
    local lines = vim.fn.readfile(resolved.filepath)
    local title_sep = config.get("number_title_separator", ". ")

    -- Find the heading line for this number
    local target_level = nil
    local target_title = nil
    local target_start = nil
    local target_end = nil

    for i, line in ipairs(lines) do
        local stars = line:match("^(%*+)%s")
        if stars then
            -- Parse heading to get its number
            local heading_text = line:match("^%*+%s+(.*)$")
            local content = heading_text

            -- Strip todo state
            local _, rest = heading_text:match("^%((.-)%)%s+(.*)")
            if rest then
                content = rest
            end

            local num, title, _ = numbering.parse_number_and_title(content)

            if num == number then
                -- Found the target heading
                target_level = #stars
                target_title = title
                target_start = i
            elseif target_start and #stars <= target_level then
                -- Found next same-or-higher-level heading — marks end of our section
                target_end = i
                break
            end
        end
    end

    if not target_start then
        return nil, string.format("Heading '%s' not found in file '%s'", number, resolved.filepath)
    end

    -- If we didn't find an end marker, section goes to end of file
    if not target_end then
        target_end = #lines + 1
    end

    return {
        filepath = resolved.filepath,
        file_prefix = resolved.prefix,
        entry_number = number,
        entry_title = target_title,
        heading_level = target_level,
        start_line = target_start,
        end_line = target_end,
        is_file_level = false,
    }, nil
end

---------------------------------------------------------------------------
--- SECTION PARSING (within an entry's line range)
---------------------------------------------------------------------------

--- Parse an entry's section into child sub-entries.
--- Children are headings one level deeper than the entry itself.
---
--- @param lines string[]          All lines of the source file
--- @param location EntryLocation  The located entry info
--- @return string[] preamble      Lines between entry heading and first child (body content)
--- @return table[] children       List of {prefix, title, heading_line, lines, state_char}
--- @return number child_level     The heading level of the children
local function parse_children(lines, location)
    local preamble = {}
    local children = {}
    local current_child = nil

    -- Determine the child heading level
    local child_level
    if location.is_file_level then
        -- For file-level entries, children are level-1 headings
        child_level = 1
    else
        child_level = location.heading_level + 1
    end

    -- Starting line: skip the entry's own heading line (if not file-level)
    local scan_start = location.start_line
    if not location.is_file_level then
        scan_start = location.start_line + 1
    end

    local title_sep = config.get("number_title_separator", ". ")

    for i = scan_start, location.end_line - 1 do
        local line = lines[i]
        local stars = line:match("^(%*+)%s")

        if stars and #stars == child_level then
            -- Save previous child
            if current_child then
                table.insert(children, current_child)
            end

            -- Parse the child heading
            local heading_text = line:match("^%*+%s+(.*)$")
            local state_char = nil
            local content = heading_text

            -- Strip todo state
            local state, rest = heading_text:match("^%((.-)%)%s+(.*)")
            if state then
                state_char = state
                content = rest
            end

            local num, title, _ = numbering.parse_number_and_title(content)

            -- If no number parsed, generate one
            if not num then
                title = content
                local child_pos = #children + 1
                num = location.entry_number .. config.get("number_separator", ".") .. tostring(child_pos)
            end

            current_child = {
                prefix = num,
                title = title,
                heading_line = line,
                lines = {},
                state_char = state_char,
            }
        else
            if current_child then
                table.insert(current_child.lines, line)
            else
                table.insert(preamble, line)
            end
        end
    end

    -- Don't forget the last child
    if current_child then
        table.insert(children, current_child)
    end

    return preamble, children, child_level
end

---------------------------------------------------------------------------
--- EXTRACTION EXECUTION
---------------------------------------------------------------------------

--- Shift heading levels in a line by a given offset.
--- E.g., "** heading" with shift=-1 becomes "* heading".
---
--- @param line string    A line of norg content
--- @param shift number   Level shift (negative = reduce stars)
--- @return string        The adjusted line
local function shift_heading_level(line, shift)
    local stars, rest = line:match("^(%*+)(%s.*)$")
    if not stars then
        return line
    end
    local new_level = #stars + shift
    if new_level < 1 then
        new_level = 1
    end
    return string.rep("*", new_level) .. rest
end

--- Build the file content for an extracted child.
--- Includes the heading line and all body content.
--- Adjusts heading levels so the child's heading becomes level 1.
---
--- @param child table      Child entry from parse_children()
--- @param child_level number  The original heading level of this child
--- @return string[]        Lines for the new file
local function build_file_content(child, child_level)
    local content = {}
    local shift = 1 - child_level -- e.g., child at level 2 → shift = -1

    -- Include the heading line (shifted to level 1)
    table.insert(content, shift_heading_level(child.heading_line, shift))

    -- Include all body lines (shift any sub-headings)
    for _, line in ipairs(child.lines) do
        table.insert(content, shift_heading_level(line, shift))
    end

    -- Remove trailing empty lines
    while #content > 0 and content[#content] == "" do
        table.remove(content)
    end

    return content
end

--- Execute the extraction.
---
--- @param location EntryLocation  The located entry
--- @param preamble string[]       Preamble lines (content between entry heading and first child)
--- @param children table[]        Parsed child entries
--- @param child_level number      The heading level of the children (for level adjustment)
--- @return boolean success
--- @return string|nil error
local function execute_extraction(location, preamble, children, child_level)
    local title_sep = config.get("number_title_separator", ". ")
    local parent_dir = vim.fn.fnamemodify(location.filepath, ":p:h")

    -- Directory name = entry's prefix + title separator + title (sanitized)
    local dir_name = location.entry_number .. title_sep .. sanitize_filename(location.entry_title)
    local dir_path = parent_dir .. "/" .. dir_name

    -- Check directory doesn't already exist
    local stat = vim.uv.fs_stat(dir_path)
    if stat then
        return false, string.format("Directory already exists: %s", dir_path)
    end

    vim.fn.mkdir(dir_path, "p")

    -- Write each child as a separate file
    for _, child in ipairs(children) do
        local file_name = child.prefix .. title_sep .. sanitize_filename(child.title) .. ".norg"
        local file_path = dir_path .. "/" .. file_name
        local content = build_file_content(child, child_level)
        vim.fn.writefile(content, file_path)
    end

    -- Generate index.norg for the new directory
    local dir_tree = status.build_directory_tree(dir_path)
    local idx_lines = status.render_as_norg(dir_tree, { max_depth = 2, base_level = 0 })

    -- If there's preamble content, prepend it to index.norg
    if #preamble > 0 then
        -- Remove trailing empty lines from preamble
        while #preamble > 0 and preamble[#preamble] == "" do
            table.remove(preamble)
        end
        if #preamble > 0 then
            table.insert(preamble, "") -- blank separator line
            for _, line in ipairs(idx_lines) do
                table.insert(preamble, line)
            end
            idx_lines = preamble
        end
    end

    vim.fn.writefile(idx_lines, dir_path .. "/index.norg")

    -- Remove the entry's section from the source file (or delete the file)
    local source_lines = vim.fn.readfile(location.filepath)

    if location.is_file_level then
        -- Entry is the whole file — delete it
        local ok, err = os.remove(location.filepath)
        if not ok then
            vim.notify(
                string.format("Warning: could not remove original file: %s", err or "unknown"),
                vim.log.levels.WARN
            )
        end
    else
        -- Remove just the entry's section from the file
        -- start_line and end_line are 1-indexed; end_line is exclusive
        local new_lines = {}
        for i = 1, location.start_line - 1 do
            table.insert(new_lines, source_lines[i])
        end
        for i = location.end_line, #source_lines do
            table.insert(new_lines, source_lines[i])
        end

        -- Remove trailing empty lines at the splice point
        -- (avoid double blank lines where the section was removed)
        local splice_point = location.start_line - 1
        while splice_point > 0 and splice_point <= #new_lines
            and new_lines[splice_point] == ""
            and splice_point + 1 <= #new_lines
            and new_lines[splice_point + 1] == "" do
            table.remove(new_lines, splice_point)
        end

        -- Check if file is now empty (or only whitespace)
        local has_content = false
        for _, line in ipairs(new_lines) do
            if line:match("%S") then
                has_content = true
                break
            end
        end

        if not has_content then
            -- File is empty after extraction — delete it
            local ok, err = os.remove(location.filepath)
            if not ok then
                vim.notify(
                    string.format("Warning: could not remove empty file: %s", err or "unknown"),
                    vim.log.levels.WARN
                )
            end
        else
            vim.fn.writefile(new_lines, location.filepath)
        end
    end

    -- Update caches and status files
    idx.invalidate(location.filepath)
    idx.invalidate_project_cache()

    -- Regenerate parent index.norg
    local parent_index = parent_dir .. "/index.norg"
    if vim.fn.filereadable(parent_index) == 1 then
        status.update_file(parent_index, parent_dir, "index")
    else
        local parent_tree = status.build_directory_tree(parent_dir)
        local parent_lines = status.render_as_norg(parent_tree, { max_depth = 2, base_level = 0 })
        vim.fn.writefile(parent_lines, parent_index)
    end

    -- Regenerate project.norg
    local root = project.find_root(dir_path .. "/index.norg")
    if root then
        local project_file = root .. "/project.norg"
        if vim.fn.filereadable(project_file) == 1 then
            status.update_file(project_file, root, "project")
        end
    end

    return true, nil
end

---------------------------------------------------------------------------
--- MAIN ENTRY
---------------------------------------------------------------------------

--- Extract an entry and its sub-entries into a directory structure.
--- Identifies the target from cursor position, locates it in the project,
--- parses its children, shows confirmation, and executes.
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

    -- Read the source file and parse children
    local lines = vim.fn.readfile(location.filepath)
    if #lines == 0 then
        vim.notify("NeorgPMExtract: Source file is empty", vim.log.levels.ERROR)
        return
    end

    local preamble, children, child_level = parse_children(lines, location)

    if #children == 0 then
        vim.notify(
            string.format(
                "NeorgPMExtract: Entry '%s' has no child headings to extract.",
                number
            ),
            vim.log.levels.WARN
        )
        return
    end

    -- Build confirmation message
    local title_sep = config.get("number_title_separator", ". ")
    local dir_name = location.entry_number .. title_sep .. sanitize_filename(location.entry_title)
    local source_name = vim.fn.fnamemodify(location.filepath, ":t")

    local preview = { string.format('Extract "%s. %s" → directory:', location.entry_number, location.entry_title) }
    table.insert(preview, string.format("  Create: %s/", dir_name))
    for _, child in ipairs(children) do
        local fname = child.prefix .. title_sep .. sanitize_filename(child.title) .. ".norg"
        table.insert(preview, string.format("  Create: %s/%s", dir_name, fname))
    end
    table.insert(preview, string.format("  Create: %s/index.norg", dir_name))
    if location.is_file_level then
        table.insert(preview, string.format("  Remove: %s", source_name))
    else
        table.insert(preview, string.format("  Modify: %s (remove section %s)", source_name, number))
    end

    local preview_text = table.concat(preview, "\n")

    -- Show confirmation
    vim.ui.select({ "Yes", "No", "Show details" }, {
        prompt = string.format(
            "Extract '%s' (%d children) into directory '%s/'? ",
            number, #children, dir_name
        ),
    }, function(choice)
        if choice == "Yes" then
            local ok, extract_err = execute_extraction(location, preamble, children, child_level)
            if ok then
                vim.notify(
                    string.format(
                        "Extracted '%s' → %d files in '%s/'",
                        number, #children, dir_name
                    ),
                    vim.log.levels.INFO
                )

                -- If the source file was open in a buffer and got deleted, clean up
                if location.is_file_level or not vim.uv.fs_stat(location.filepath) then
                    for _, b in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.api.nvim_buf_is_valid(b)
                            and vim.api.nvim_buf_get_name(b) == location.filepath then
                            vim.api.nvim_buf_delete(b, { force = true })
                            break
                        end
                    end
                else
                    -- Source file was modified — reload if open
                    for _, b in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.api.nvim_buf_is_valid(b)
                            and vim.api.nvim_buf_get_name(b) == location.filepath then
                            vim.api.nvim_buf_call(b, function()
                                vim.cmd("edit!")
                            end)
                            break
                        end
                    end
                end

                -- Refresh current buffer if it's a status file
                local current_buf = vim.api.nvim_get_current_buf()
                if vim.api.nvim_buf_is_valid(current_buf) then
                    local current_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(current_buf), ":t")
                    if current_name == "project.norg" or current_name == "index.norg" then
                        vim.cmd("edit!")
                    end
                end
            else
                vim.notify("NeorgPMExtract: " .. (extract_err or "Unknown error"), vim.log.levels.ERROR)
            end
        elseif choice == "Show details" then
            vim.notify(preview_text, vim.log.levels.INFO)
        end
    end)
end

return M
