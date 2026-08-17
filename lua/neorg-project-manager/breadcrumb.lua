--- neorg-project-manager.breadcrumb: Heading path / breadcrumb display.
---
--- Shows the current cursor position as a breadcrumb path through the project
--- hierarchy. Three display modes: statusline, winbar, virtual text.
---
--- Example output: "Encora Pulse Proxy > Python API > Authentication > Design"
---
--- @module neorg-project-manager.breadcrumb

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")
local project = require("neorg-project-manager.project")
local numbering = require("neorg-project-manager.numbering")

--- Result cache to avoid recomputation on every statusline redraw.
--- @type {buf: number|nil, line: number|nil, tick: number|nil, result: string}
local cache = { buf = nil, line = nil, tick = nil, result = "" }

---------------------------------------------------------------------------
--- TITLE EXTRACTION
---------------------------------------------------------------------------

--- Extract a clean title from a heading's paragraph_segment text.
--- Strips number prefix, {* number} links, [N/M] counts, and trims.
---
--- @param node TSNode    A heading node
--- @param buf number     Buffer handle
--- @return string|nil    Clean title, or nil if no title found
local function get_heading_title(node, buf)
    for child in node:iter_children() do
        if child:type() == "paragraph_segment" then
            local text = vim.treesitter.get_node_text(child, buf)
            if not text then
                return nil
            end

            -- Strip leading whitespace
            text = vim.trim(text)

            -- Remove number prefix (e.g., "1.1.1. " → "")
            local _, title, _ = numbering.parse_number_and_title(text)
            text = title or text

            -- Strip {* number} links
            text = text:gsub("%s*{%*+%s+[^}]+}%s*", "")
            -- Strip [N/M] progress counts
            text = text:gsub("%s*%[%d+/%d+%]%s*", "")
            -- Strip parenthesized annotations: (`app/auth/`), (optional), etc.
            text = text:gsub("%s*%b()%s*", "")

            text = vim.trim(text)
            if text ~= "" then
                return text
            end
            return nil
        end
    end
    return nil
end

---------------------------------------------------------------------------
--- SEGMENT COLLECTION: HEADING ANCESTORS (within file)
---------------------------------------------------------------------------

--- Collect ancestor heading titles from cursor position upward.
--- Returns segments in root-to-leaf order (first = outermost heading).
---
--- @param buf number       Buffer handle
--- @param file_prefix string|nil  File's number prefix (to skip file-title heading)
--- @return string[]        List of title strings
local function collect_heading_ancestors(buf, file_prefix)
    local node = vim.treesitter.get_node({ bufnr = buf })
    if not node then
        return {}
    end

    local segments = {}
    local current = node

    while current do
        local level = helpers.get_heading_level(current)
        if level then
            local title = get_heading_title(current, buf)
            if title then
                -- Skip the file-title heading (number == file prefix) to avoid
                -- duplicating the file segment added by collect_file_context
                local skip = false
                if file_prefix then
                    for child in current:iter_children() do
                        if child:type() == "paragraph_segment" then
                            local text = vim.treesitter.get_node_text(child, buf)
                            if text then
                                local num, _, _ = numbering.parse_number_and_title(vim.trim(text))
                                if num == file_prefix then
                                    skip = true
                                end
                            end
                            break
                        end
                    end
                end

                if not skip then
                    table.insert(segments, 1, title) -- prepend (root-first order)
                end
            end
        end
        current = current:parent()
    end

    return segments
end

---------------------------------------------------------------------------
--- SEGMENT COLLECTION: FILE + DIRECTORY CONTEXT (above file)
---------------------------------------------------------------------------

--- Collect file title and parent directory titles up to the project root.
--- Returns segments in root-to-leaf order.
---
--- When `include_project_path` is false, only the current file's title is
--- returned (no directory traversal). Change this config option for a
--- shorter breadcrumb that shows only within-file context.
---
--- @param buf number    Buffer handle
--- @param include_project_path boolean  Whether to include directory/project segments
--- @return string[]     List of title strings
local function collect_file_context(buf, include_project_path)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        return {}
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")

    -- Skip status files (project.norg / index.norg) — they don't have a meaningful title
    if filename == "project.norg" or filename == "index.norg" then
        if include_project_path then
            local root = project.find_root(filepath)
            if root then
                return { vim.fn.fnamemodify(root, ":t") }
            end
        end
        return {}
    end

    local segments = {}

    -- Current file title
    local prefix, title = project.extract_prefix(filename)
    if title and title ~= "" then
        -- Strip parenthesized annotations from title
        title = title:gsub("%s*%b()%s*", "")
        title = vim.trim(title)
        if title ~= "" then
            table.insert(segments, title)
        end
    end

    -- Walk up parent directories to project root
    -- CONFIG POINT: set breadcrumb_project_path = false to skip this
    -- and show only within-file heading context
    if include_project_path then
        local root = project.find_root(filepath)
        if root then
            local dir = vim.fn.fnamemodify(filepath, ":p:h")

            while dir ~= root and #dir > #root do
                local dir_name = vim.fn.fnamemodify(dir, ":t")
                local _, dir_title = project.extract_prefix(dir_name)
                if dir_title and dir_title ~= "" then
                    dir_title = dir_title:gsub("%s*%b()%s*", "")
                    dir_title = vim.trim(dir_title)
                    if dir_title ~= "" then
                        table.insert(segments, 1, dir_title) -- prepend
                    end
                end
                dir = vim.fn.fnamemodify(dir, ":h")
            end

            -- Add project root name as first segment
            local root_name = vim.fn.fnamemodify(root, ":t")
            table.insert(segments, 1, root_name)
        end
    end

    return segments
end

---------------------------------------------------------------------------
--- CORE API
---------------------------------------------------------------------------

--- Get the heading breadcrumb path for the current cursor position.
--- Returns an empty string if not in a norg buffer or no heading context found.
---
--- Designed for use in statusline (lualine), winbar, or programmatic access.
--- Results are cached per {buffer, cursor line, changedtick} — safe to call
--- on every statusline redraw.
---
--- @return string  Breadcrumb path (e.g., "Project > API > Auth > Design")
function M.get()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].filetype ~= "norg" then
        return ""
    end

    -- Cache check: same buffer, same line, same content → return cached
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    if cache.buf == buf and cache.line == cursor_line and cache.tick == tick then
        return cache.result
    end

    local separator = config.get("breadcrumb_separator", " > ")
    local include_project = config.get("breadcrumb_project_path", true)

    -- Get file prefix (for deduplication with file-title heading)
    local file_prefix = numbering.get_file_prefix(buf)

    -- Collect segments
    local segments = {}

    -- 1. File + directory context (above the file)
    local file_segments = collect_file_context(buf, include_project)
    vim.list_extend(segments, file_segments)

    -- 2. Heading ancestors within the file
    local heading_segments = collect_heading_ancestors(buf, file_prefix)
    vim.list_extend(segments, heading_segments)

    -- 3. Format
    local result
    local custom_format = config.get("breadcrumb_format", nil)
    if custom_format then
        result = custom_format(segments)
    else
        result = table.concat(segments, separator)
    end

    -- Update cache
    cache = { buf = buf, line = cursor_line, tick = tick, result = result }

    return result
end

---------------------------------------------------------------------------
--- DISPLAY MODES
---------------------------------------------------------------------------

--- Set up winbar display for a buffer.
--- The winbar evaluates our function on every redraw (no autocmd needed).
---
--- @param buf number  Buffer handle
function M.setup_winbar(buf)
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
        vim.wo[win].winbar = "%{%v:lua.require'neorg-project-manager.breadcrumb'.get()%}"
    end

    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = buf,
        group = vim.api.nvim_create_augroup("NeorgPM_BreadcrumbWinbar_" .. buf, { clear = true }),
        callback = function()
            local w = vim.api.nvim_get_current_win()
            if vim.api.nvim_win_get_buf(w) == buf then
                vim.wo[w].winbar = "%{%v:lua.require'neorg-project-manager.breadcrumb'.get()%}"
            end
        end,
    })
end

--- Set up virtual text display for a buffer.
--- Shows the breadcrumb as virtual text on the current heading line,
--- updated on CursorMoved.
---
--- @param buf number  Buffer handle
--- @param ns number   Namespace ID for extmarks
function M.setup_virtual_text(buf, ns)
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        buffer = buf,
        group = vim.api.nvim_create_augroup("NeorgPM_BreadcrumbVT_" .. buf, { clear = true }),
        callback = function()
            if not vim.api.nvim_buf_is_valid(buf) then
                return
            end
            vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            local path = M.get()
            if path ~= "" then
                local row = vim.api.nvim_win_get_cursor(0)[1] - 1
                vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                    virt_text = { { "  " .. path, "Comment" } },
                    virt_text_pos = "eol",
                    hl_mode = "combine",
                })
            end
        end,
    })
end

return M
