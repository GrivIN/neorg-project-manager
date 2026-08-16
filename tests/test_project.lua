--- Tests for the project module.
--- Covers: find_root, extract_prefix, scan, resolve_number_to_file, prefix_depth

local cfg = require("neorg-project-manager.config")
local project = require("neorg-project-manager.project")
local helpers = require("neorg-project-manager.helpers")

-- Setup test project structure on disk
local root = "/tmp/test_pm_project"
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/1.1. Stage 1", "p")
vim.fn.mkdir(root .. "/1.1. Stage 1/1.1.3. Authentication", "p")
vim.fn.writefile({ "" }, root .. "/project.norg")
vim.fn.writefile({ "* (x) Done" }, root .. "/1.1. Stage 1/1.1.1. X-Code Setup.norg")
vim.fn.writefile({ "* ( ) Todo" }, root .. "/1.1. Stage 1/1.1.2. Pipeline.norg")
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

    it("finds root from the root directory itself", function()
        local found = project.find_root(root .. "/project.norg")
        assert_eq(found, root, "root found from project.norg")
    end)

    it("returns nil when no project.norg exists", function()
        local found = project.find_root("/tmp/nonexistent/file.norg")
        assert_nil(found, "nil for non-project file")
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

    it("returns nil for index.norg", function()
        local prefix, title = project.extract_prefix("index.norg")
        assert_nil(prefix, "no prefix for index.norg")
        assert_eq(title, "index", "title is basename without ext")
    end)

    it("returns nil for project.norg", function()
        local prefix, _ = project.extract_prefix("project.norg")
        assert_nil(prefix, "no prefix for project.norg")
    end)

    it("returns nil for unprefixed files", function()
        local prefix, title = project.extract_prefix("notes.norg")
        assert_nil(prefix, "no prefix for generic file")
        assert_eq(title, "notes", "title is basename")
    end)
end)

describe("project.scan", function()
    it("finds all numbered entries recursively", function()
        local entries = project.scan(root)
        assert_eq(#entries, 5, "5 numbered entries")
    end)

    it("sorts entries by prefix", function()
        local entries = project.scan(root)
        for i = 2, #entries do
            assert_true(entries[i - 1].prefix <= entries[i].prefix,
                "sorted: " .. entries[i - 1].prefix .. " <= " .. entries[i].prefix)
        end
    end)

    it("skips index.norg and project.norg", function()
        local entries = project.scan(root)
        for _, e in ipairs(entries) do
            assert_true(e.name ~= "index.norg" and e.name ~= "project.norg",
                "skipped special file: " .. e.name)
        end
    end)

    it("identifies directories vs files", function()
        local entries = project.scan(root)
        local dirs = vim.tbl_filter(function(e) return e.is_dir end, entries)
        local files = vim.tbl_filter(function(e) return not e.is_dir end, entries)
        assert_eq(#dirs, 2, "2 directories")
        assert_eq(#files, 3, "3 files")
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
