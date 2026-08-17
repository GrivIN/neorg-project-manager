--- neorg-project-manager.fold: Fold-based toggle for status file tree headings.
---
--- Provides fold expression and toggle command for project.norg / index.norg
--- buffers, allowing quick collapse/expand of tree elements to their title line.
---
--- Folds are based on heading level (number of leading `*` characters).
--- Toggle recursively opens/closes a heading and all its children.
---
--- @module neorg-project-manager.fold

local M = {}

---------------------------------------------------------------------------
--- FOLD EXPRESSION
---------------------------------------------------------------------------

--- Compute the fold level for a given line number.
--- Used as the foldexpr function for status file buffers.
---
--- @param lnum number  Line number (1-indexed, as passed by Neovim foldexpr)
--- @param buf number   Buffer handle
--- @return string      Fold level string (e.g., ">2", "=")
function M.foldexpr(lnum, buf)
    local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
    if not line then
        return "="
    end

    -- Count leading stars: heading level determines fold level
    local stars = line:match("^(%*+)%s")
    if stars then
        return ">" .. #stars
    end

    -- Non-heading lines inherit fold level from previous line
    return "="
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
--- TOGGLE
---------------------------------------------------------------------------

--- Toggle fold at the current cursor position.
--- If on a heading: recursively close if open, recursively open if closed.
--- If not on a heading: find the nearest parent heading and toggle that.
---
--- @param buf number|nil  Buffer handle (defaults to current buffer)
function M.toggle(buf)
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
        -- It's a heading line that is currently open — close it recursively
        pcall(vim.cmd, "normal! zC")
        return
    end

    -- Not on a heading — try to find the fold we're inside and close it
    local fold_level = vim.fn.foldlevel(cursor_line)
    if fold_level > 0 then
        -- Move to the fold start and close
        pcall(vim.cmd, "normal! [zzC")
    else
        vim.notify("No foldable heading at cursor position.", vim.log.levels.INFO)
    end
end

---------------------------------------------------------------------------
--- DETECT STATUS FILE
---------------------------------------------------------------------------

--- Check if a buffer is a status file (project.norg or index.norg).
---
--- @param buf number  Buffer handle
--- @return boolean    True if the buffer is a status file
function M.is_status_file(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        return false
    end
    local filename = vim.fn.fnamemodify(filepath, ":t")
    return filename == "project.norg" or filename == "index.norg"
end

return M
