--- Tests for the project module.
--- Covers: find_root, find_status_file, extract_prefix, scan, resolve_number_to_file, prefix_depth

local cfg = require("neorg-project-manager.config")
local project = require("neorg-project-manager.project")
local helpers = require("neorg-project-manager.helpers")

-- Setup test project structure on disk (new-style: root-level numbered file as marker)
local root = "/tmp/test_pm_project"
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/1.1. Stage 1", "p")
vim.fn.mkdir(root .. "/1.1. Stage 1/1.1.3. Authentication", "p")
-- Root-level status file (depth-1 prefix serves as project root marker)
vim.fn.writefile({ "* (-) 1. My Project {* 1}" }, root .. "/1. My Project.norg")
vim.fn.writefile({ "* (x) Done" }, root .. "/1.1. Stage 1/1.1.1. X-Code Setup.norg")
vim.fn.writefile({ "* ( ) Todo" }, root .. "/1.1. Stage 1/1.1.2. Pipeline.norg")
-- Directory status file: prefix "1.1" matches dir "1.1. Stage 1"
vim.fn.writefile({ "* (-) 1.1. Stage 1 {* 1.1}" }, root .. "/1.1. Stage 1/1.1. Stage 1.norg")
vim.fn.writefile({ "* (-) WIP" }, root .. "/1.1. Stage 1/1.1.3. Authentication/1.1.3.1. Stage 1.norg")

cfg.set({
    number_separator = ".",
    number_title_separator = ". ",
    project_root = nil,
    file_prefix = nil,
})

describe("project.find_root", function()
    it("finds root from a nested file", function()
        local found = project.find_root(root .. "/1.1. Stage 1/1.1.1. X-Code Setup.norg")
        assert_eq(found, root, "root found from nested file")
    end)

    it("finds root from the root status file itself", function()
        local found = project.find_root(root .. "/1. My Project.norg")
        assert_eq(found, root, "root found from root status file")
    end)

    it("returns nil when no root indicator exists", function()
        local found = project.find_root("/tmp/nonexistent/file.norg")
        assert_nil(found, "nil for non-project file")
    end)
end)

describe("project.find_status_file", function()
    it("finds root-level status file (depth-1 prefix)", function()
        local sf = project.find_status_file(root)
        assert_true(sf ~= nil, "found root status file")
        assert_match(sf, "1%. My Project%.norg", "correct root status file")
    end)

    it("finds directory status file (prefix matches dir)", function()
        local sf = project.find_status_file(root .. "/1.1. Stage 1")
        assert_true(sf ~= nil, "found dir status file")
        assert_match(sf, "1%.1%. Stage 1%.norg", "correct dir status file")
    end)

    it("returns nil for directory without status file", function()
        local sf = project.find_status_file(root .. "/1.1. Stage 1/1.1.3. Authentication")
        assert_nil(sf, "nil for dir without matching status file")
    end)
end)

describe("project.extract_prefix", function()
    it("extracts from numbered .norg file", function()
        local prefix, title = project.extract_prefix("1.1.3.1. Stage 1.norg")
        assert_eq(prefix, "1.1.3.1", "prefix from norg file")
        assert_eq(title, "Stage 1", "title from norg file")
    end)

    it("extracts from numbered directory", function()
        local prefix, title = project.extract_prefix("1.1. Stage 1")
        assert_eq(prefix, "1.1", "prefix from directory")
        assert_eq(title, "Stage 1", "title from directory")
    end)

    it("extracts depth-1 prefix", function()
        local prefix, title = project.extract_prefix("42. ACME App.norg")
        assert_eq(prefix, "42", "prefix from root-level file")
        assert_eq(title, "ACME App", "title from root-level file")
    end)

    it("returns nil for unprefixed files", function()
        local prefix, title = project.extract_prefix("notes.norg")
        assert_nil(prefix, "no prefix for generic file")
        assert_eq(title, "notes", "title is basename")
    end)

    it("returns nil for files starting with @", function()
        local prefix, _ = project.extract_prefix("@backend-team.norg")
        assert_nil(prefix, "no prefix for @-prefixed file")
    end)
end)

describe("project.scan", function()
    it("finds all numbered entries recursively", function()
        local entries = project.scan(root)
        -- 1. My Project.norg, 1.1. Stage 1 (dir), 1.1. Stage 1.norg,
        -- 1.1.1. X-Code Setup.norg, 1.1.2. Pipeline.norg,
        -- 1.1.3. Authentication (dir), 1.1.3.1. Stage 1.norg
        assert_eq(#entries, 7, "7 numbered entries (including status files)")
    end)

    it("sorts entries by prefix (natural sort)", function()
        local entries = project.scan(root)
        for i = 2, #entries do
            assert_true(helpers.natural_sort_prefixes(entries[i - 1].prefix, entries[i].prefix)
                or entries[i - 1].prefix == entries[i].prefix,
                "sorted: " .. entries[i - 1].prefix .. " <= " .. entries[i].prefix)
        end
    end)

    it("includes status files in scan (for link resolution)", function()
        local entries = project.scan(root)
        local found_root_status = false
        local found_dir_status = false
        for _, e in ipairs(entries) do
            if e.name == "1. My Project.norg" then found_root_status = true end
            if e.name == "1.1. Stage 1.norg" then found_dir_status = true end
        end
        assert_true(found_root_status, "root status file in scan")
        assert_true(found_dir_status, "dir status file in scan")
    end)

    it("identifies directories vs files", function()
        local entries = project.scan(root)
        local dirs = vim.tbl_filter(function(e) return e.is_dir end, entries)
        local files = vim.tbl_filter(function(e) return not e.is_dir end, entries)
        assert_eq(#dirs, 2, "2 directories")
        assert_eq(#files, 5, "5 files")
    end)
end)

describe("project.resolve_number_to_file", function()
    it("resolves exact file prefix match", function()
        local entries = project.scan(root)
        local result = project.resolve_number_to_file("1.1.1", entries)
        assert_true(result ~= nil, "found result")
        assert_match(result.filepath, "1.1.1. X%-Code Setup.norg", "correct file")
        assert_nil(result.remainder, "no remainder for exact match")
    end)

    it("resolves number to heading within a file", function()
        local entries = project.scan(root)
        local result = project.resolve_number_to_file("1.1.3.1.2", entries)
        assert_true(result ~= nil, "found result")
        assert_match(result.filepath, "1.1.3.1. Stage 1.norg", "correct file")
        assert_eq(result.remainder, "2", "remainder is heading number")
    end)

    it("resolves root prefix to root status file", function()
        local entries = project.scan(root)
        local result = project.resolve_number_to_file("1", entries)
        assert_true(result ~= nil, "found result")
        assert_match(result.filepath, "1%. My Project%.norg", "correct root file")
        assert_nil(result.remainder, "no remainder for root prefix")
    end)

    it("returns nil for unknown numbers", function()
        local entries = project.scan(root)
        local result = project.resolve_number_to_file("9.9.9", entries)
        assert_nil(result, "nil for unknown number")
    end)
end)

describe("helpers.prefix_depth", function()
    it("returns 0 for nil", function()
        assert_eq(helpers.prefix_depth(nil), 0, "nil → 0")
    end)

    it("returns 0 for empty string", function()
        assert_eq(helpers.prefix_depth(""), 0, "empty → 0")
    end)

    it("counts single-part prefix", function()
        assert_eq(helpers.prefix_depth("1"), 1, "1 → depth 1")
    end)

    it("counts multi-part prefix", function()
        assert_eq(helpers.prefix_depth("1.1.3"), 3, "1.1.3 → depth 3")
        assert_eq(helpers.prefix_depth("1.1.3.1.2"), 5, "1.1.3.1.2 → depth 5")
    end)
end)
