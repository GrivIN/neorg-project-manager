--- neorg-project-manager.fold: Fold-based toggle for status file tree headings.
---
--- Provides fold expression and toggle commands for project.norg / index.norg
--- buffers. Two fold operations:
---   - Toggle body (pt): hides all body/description text, headings stay visible
---   - Toggle all (pT): hides body AND child headings (full collapse to one line)
---
--- Folds are based on heading level (number of leading `*` characters).
--- Body content (non-heading lines) gets its own fold level (parent + 1),
--- allowing it to be folded independently of child headings.
---
--- @module neorg-project-manager.fold

local M = {}

---------------------------------------------------------------------------
--- FOLD EXPRESSION
---------------------------------------------------------------------------

--- Compute the fold level for a given line number.
--- Headings get ">N" (where N = number of stars).
--- Body content (non-heading lines) gets parent_heading_level + 1, creating
--- an independent fold region that can be closed without hiding child headings.
---
--- @param lnum number  Line number (1-indexed, as passed by Neovim foldexpr)
--- @param buf number   Buffer handle
--- @return string      Fold level string (e.g., ">2", "3", "=")
function M.foldexpr(lnum, buf)
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    if not line then
        return "="
    end

    -- Heading lines: fold level = number of leading stars
    local stars = line:match("^(%*+)%s")
    if stars then
        return ">" .. #stars
    end

    -- Non-heading lines: find the nearest heading above to determine body fold level.
    -- Body content gets level = parent_heading_level + 1, which creates an independent
    -- fold region between the heading and its first child heading.
    for i = lnum - 1, math.max(1, lnum - 50), -1 do
        local prev = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if prev then
            local prev_stars = prev:match("^(%*+)%s")
            if prev_stars then
                return tostring(#prev_stars + 1)
            end
        end
    end

    -- Fallback: content before any heading (top of file)
    return "1"
end

---------------------------------------------------------------------------
--- FOLD SETUP
---------------------------------------------------------------------------

--- Set up fold options for a status file buffer (project.norg or index.norg).
--- Configures foldmethod=expr with our custom foldexpr, starts fully expanded.
---
--- @param buf number  Buffer handle
function M.setup_folds(buf)
    -- Use window-local options for the current window displaying this buffer
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = buf,
        group = vim.api.nvim_create_augroup("NeorgPM_Fold_" .. buf, { clear = true }),
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(win) == buf then
                M.apply_fold_options(win, buf)
            end
        end,
    })

    -- Also apply immediately for the current window
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
        M.apply_fold_options(win, buf)
    end
end

--- Apply fold window options.
---
--- @param win number  Window handle
--- @param buf number  Buffer handle
function M.apply_fold_options(win, buf)
    vim.wo[win].foldmethod = "expr"
    vim.wo[win].foldexpr = string.format(
        "v:lua.require'neorg-project-manager.fold'.foldexpr(v:lnum, %d)", buf
    )
    vim.wo[win].foldenable = true
    vim.wo[win].foldlevel = 99 -- Start fully expanded
    vim.wo[win].foldtext = "v:lua.require'neorg-project-manager.fold'.foldtext()"
end

---------------------------------------------------------------------------
--- FOLD TEXT
---------------------------------------------------------------------------

--- Custom foldtext function showing the heading line with a child count indicator.
---
--- @return string  The text to display for a closed fold
function M.foldtext()
    local foldstart = vim.v.foldstart
    local foldend = vim.v.foldend
    local line = vim.fn.getline(foldstart)
    local child_count = foldend - foldstart
    return line .. string.format("  [+%d lines]", child_count)
end

---------------------------------------------------------------------------
--- HELPERS
---------------------------------------------------------------------------

--- Find the heading at or above the given line.
--- Returns the line number and heading level, or nil if not found.
---
--- @param buf number   Buffer handle
--- @param from_line number  Line to start searching from (1-indexed)
--- @return number|nil line_nr  Line number of the heading (1-indexed)
--- @return number|nil level    Heading level (number of stars)
local function find_heading_at_or_above(buf, from_line)
    for i = from_line, 1, -1 do
        local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if line then
            local stars = line:match("^(%*+)%s")
            if stars then
                return i, #stars
            end
        end
    end
    return nil, nil
end

--- Find the end of a heading's section (the line before the next same-or-higher-level heading).
--- Returns the last line number belonging to this heading's section.
---
--- @param buf number   Buffer handle
--- @param heading_line number  Line of the heading (1-indexed)
--- @param heading_level number Heading level
--- @return number      Last line of the section (inclusive, 1-indexed)
local function find_section_end(buf, heading_line, heading_level)
    local total = vim.api.nvim_buf_line_count(buf)
    for i = heading_line + 1, total do
        local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if line then
            local stars = line:match("^(%*+)%s")
            if stars and #stars <= heading_level then
                return i - 1
            end
        end
    end
    return total
end

---------------------------------------------------------------------------
--- TOGGLE BODY (pt) — hide descriptions, keep headings visible
---------------------------------------------------------------------------

--- Toggle body/description folds within the current heading's subtree.
--- When closing: hides all non-heading content at every level, leaving only
--- the heading tree structure visible.
--- When opening: reveals all body content in the subtree.
---
--- @param buf number|nil  Buffer handle (defaults to current buffer)
function M.toggle_body(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    -- Check if folding is active
    if vim.wo.foldmethod ~= "expr" then
        vim.notify("Folds not active in this buffer. Use on project.norg or index.norg.", vim.log.levels.WARN)
        return
    end

    -- Find the heading at or above cursor
    local heading_line, heading_level = find_heading_at_or_above(buf, cursor_line)
    if not heading_line then
        vim.notify("No heading found at or above cursor.", vim.log.levels.INFO)
        return
    end

    -- Find the section range
    local section_end = find_section_end(buf, heading_line, heading_level)

    -- Detect current state: are body folds open or closed?
    -- Look for the first non-heading line in the section to determine toggle direction.
    local should_open = false
    for i = heading_line + 1, section_end do
        local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if line and not line:match("^%*+%s") and line:match("%S") then
            -- Found a body line — check if it's inside a closed fold
            if vim.fn.foldclosed(i) ~= -1 then
                should_open = true
            end
            break
        end
    end

    -- Iterate through the section and close/open body folds
    local i = heading_line + 1
    while i <= section_end do
        local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
        if not line then
            i = i + 1
            goto continue
        end

        local is_heading = line:match("^%*+%s") ~= nil

        if not is_heading then
            if should_open then
                -- Open body fold if it's closed
                local fold_start = vim.fn.foldclosed(i)
                if fold_start ~= -1 then
                    pcall(vim.cmd, i .. "foldopen")
                end
            else
                -- Close body fold if it's open
                local fold_start = vim.fn.foldclosed(i)
                if fold_start == -1 and vim.fn.foldlevel(i) > 0 then
                    pcall(vim.cmd, i .. "foldclose")
                    -- Skip past the closed fold
                    local fold_end = vim.fn.foldclosedend(i)
                    if fold_end > i then
                        i = fold_end
                    end
                end
            end
        end

        -- If this line is inside a closed fold (after our operation), skip to fold end
        local closed_end = vim.fn.foldclosedend(i)
        if closed_end > i then
            i = closed_end + 1
        else
            i = i + 1
        end

        ::continue::
    end
end

---------------------------------------------------------------------------
--- TOGGLE ALL (pT) — hide body AND children (full collapse)
---------------------------------------------------------------------------

--- Toggle the entire fold at the current cursor position.
--- If on a heading: close the fold (hides body + all children).
--- If on a closed fold: open recursively (shows everything).
---
--- @param buf number|nil  Buffer handle (defaults to current buffer)
function M.toggle_all(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

    -- Check if folding is active
    if vim.wo.foldmethod ~= "expr" then
        vim.notify("Folds not active in this buffer. Use on project.norg or index.norg.", vim.log.levels.WARN)
        return
    end

    -- Check if current line is inside a closed fold
    local fold_closed = vim.fn.foldclosed(cursor_line)
    if fold_closed ~= -1 then
        -- We're inside (or on) a closed fold — open it recursively
        pcall(vim.cmd, "normal! zO")
        return
    end

    -- Check if current line is a heading (can be folded)
    local line = vim.api.nvim_buf_get_lines(buf, cursor_line - 1, cursor_line, false)[1]
    if line and line:match("^%*+%s") then
        -- It's a heading line that is currently open — close just this fold level
        pcall(vim.cmd, "normal! zc")
        return
    end

    -- Not on a heading — try to find the fold we're inside and close it
    local fold_level = vim.fn.foldlevel(cursor_line)
    if fold_level > 0 then
        -- Move to the fold start and close just this level
        pcall(vim.cmd, "normal! [zzc")
    else
        vim.notify("No foldable heading at cursor position.", vim.log.levels.INFO)
    end
end

---------------------------------------------------------------------------
--- LEGACY ALIAS
---------------------------------------------------------------------------

---------------------------------------------------------------------------
--- DETECT STATUS FILE
---------------------------------------------------------------------------

--- Check if a buffer is a status file (root-level or directory-matching numbered file).
---
--- @param buf number  Buffer handle
--- @return boolean    True if the buffer is a status file
function M.is_status_file(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    local project_mod = require("neorg-project-manager.project")
    return project_mod.is_status_file(filepath)
end

return M
