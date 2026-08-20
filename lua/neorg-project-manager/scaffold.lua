--- neorg-project-manager.scaffold: Project initialization and scaffolding.
---
--- Provides :NeorgPMInit to create a new project structure with a numbered
--- root status file, or to initialize an existing directory as a project.
---
--- @module neorg-project-manager.scaffold

local M = {}

local config = require("neorg-project-manager.config")
local project = require("neorg-project-manager.project")
local numbering = require("neorg-project-manager.numbering")

--- Create a project root status file.
--- @param dir string           Project directory
--- @param project_name string  Project name
--- @param start_number string  Starting WBS number (e.g., "1" or "42")
--- @return string|nil filepath  Path to created status file, or nil on error
local function create_root_status_file(dir, project_name, start_number)
    local title_sep = config.get("number_title_separator", ". ")
    local filename = start_number .. title_sep .. project_name .. ".norg"
    local filepath = dir .. "/" .. filename

    if vim.fn.filereadable(filepath) == 1 then
        vim.notify("Status file already exists: " .. filename, vim.log.levels.WARN)
        return filepath
    end

    local content = {
        "* ( ) " .. start_number .. title_sep .. project_name,
        "",
        "  /Project overview — add description here./",
        "",
    }

    vim.fn.writefile(content, filepath)
    return filepath
end

--- Scan existing .norg files in a directory and offer to adopt them.
--- @param dir string
--- @return table[]  List of {name, has_prefix} for existing .norg files
local function scan_existing_files(dir)
    local files = {}
    local handle = vim.uv.fs_scandir(dir)
    if not handle then return files end

    while true do
        local name, entry_type = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if entry_type == "file" and name:match("%.norg$") then
            local prefix, _ = project.extract_prefix(name)
            table.insert(files, { name = name, has_prefix = prefix ~= nil })
        end
    end

    return files
end

--- Initialize a new project interactively.
--- Prompts for project name and starting number, then creates the root status file.
---
--- @param opts table|nil  {dir = string|nil}  Directory to initialize (defaults to cwd)
function M.init(opts)
    opts = opts or {}
    local dir = opts.dir or vim.fn.getcwd()
    dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")

    -- Check if already a project
    local existing_status = project.find_status_file(dir)
    if existing_status then
        vim.notify("Project already initialized: " .. vim.fn.fnamemodify(existing_status, ":t"), vim.log.levels.INFO)
        vim.cmd("edit " .. vim.fn.fnameescape(existing_status))
        return
    end

    -- Check for existing .norg files
    local existing = scan_existing_files(dir)
    local numbered_count = 0
    for _, f in ipairs(existing) do
        if f.has_prefix then numbered_count = numbered_count + 1 end
    end

    if numbered_count > 0 then
        vim.notify(
            string.format("Found %d numbered .norg file(s) but no root status file. Creating one.", numbered_count),
            vim.log.levels.INFO
        )
    end

    -- Prompt for project name
    vim.ui.input({
        prompt = "Project name: ",
        default = vim.fn.fnamemodify(dir, ":t"),
    }, function(project_name)
        if not project_name or project_name == "" then
            vim.notify("Cancelled.", vim.log.levels.INFO)
            return
        end

        -- Prompt for starting number
        vim.ui.input({
            prompt = "Starting WBS number: ",
            default = "1",
        }, function(start_number)
            if not start_number or start_number == "" then
                vim.notify("Cancelled.", vim.log.levels.INFO)
                return
            end

            -- Validate number
            if not start_number:match("^%d+$") then
                vim.notify("Invalid number: " .. start_number, vim.log.levels.ERROR)
                return
            end

            local filepath = create_root_status_file(dir, project_name, start_number)
            if filepath then
                vim.cmd("edit " .. vim.fn.fnameescape(filepath))
                vim.notify(
                    string.format("Project initialized: %s. %s", start_number, project_name),
                    vim.log.levels.INFO
                )
            end
        end)
    end)
end

return M
