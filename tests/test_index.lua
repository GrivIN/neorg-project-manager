--- Tests for the index module.
--- Covers: index_file, get_file_state, lazy proxy resolution

local cfg = require("neorg-project-manager.config")
local index = require("neorg-project-manager.index")

-- Setup test files
local root = "/tmp/test_pm_index"
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "" }, root .. "/project.norg")
vim.fn.writefile({
    "* (x) 1.1.1.1. Setup Complete",
    "  All done.",
    "** (x) 1.1.1.1.1. Sub task A",
    "** ( ) 1.1.1.1.2. Sub task B",
}, root .. "/1.1.1. Test File.norg")

cfg.set({
    numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
    number_separator = ".",
    number_title_separator = ". ",
    number_format = nil,
})

describe("index.index_file", function()
    it("parses headings from a file on disk", function()
        local headings = index.index_file(root .. "/1.1.1. Test File.norg", "1.1.1")
        assert_true(headings["1.1.1.1"] ~= nil, "found heading 1.1.1.1")
        assert_eq(headings["1.1.1.1"].state, "done", "top heading is done")
        assert_eq(headings["1.1.1.1"].line, 0, "top heading at line 0")
    end)

    it("indexes sub-headings with correct numbers", function()
        local headings = index.index_file(root .. "/1.1.1. Test File.norg", "1.1.1")
        assert_true(headings["1.1.1.1.1"] ~= nil, "found sub-heading .1.1")
        assert_true(headings["1.1.1.1.2"] ~= nil, "found sub-heading .1.2")
        assert_eq(headings["1.1.1.1.1"].state, "done", "sub A is done")
        assert_eq(headings["1.1.1.1.2"].state, "undone", "sub B is undone")
    end)

    it("returns empty for empty file", function()
        vim.fn.writefile({ "" }, root .. "/empty.norg")
        local headings = index.index_file(root .. "/empty.norg", "1.2")
        assert_eq(next(headings), nil, "empty file → empty index")
    end)
end)

describe("index.get_file_state", function()
    it("returns the state of the first heading", function()
        local state = index.get_file_state(root .. "/1.1.1. Test File.norg", "1.1.1")
        assert_eq(state, "done", "file state is done (first heading)")
    end)

    it("returns nil for empty files", function()
        vim.fn.writefile({ "" }, root .. "/empty2.norg")
        local state = index.get_file_state(root .. "/empty2.norg", "1.9")
        assert_nil(state, "nil for empty file")
    end)
end)

describe("index.get (lazy proxy)", function()
    it("resolves a number to a file + heading", function()
        -- Force cache rebuild
        index.rebuild()

        local project = require("neorg-project-manager.project")
        -- Create a buffer pointing to a file in the project
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, root .. "/1.1.1. Test File.norg")

        local proxy = index.get(buf)
        local target = proxy["1.1.1.1"]
        assert_true(target ~= nil, "proxy resolved 1.1.1.1")
        if target then
            assert_eq(target.state, "done", "resolved state is done")
            assert_eq(target.line, 0, "resolved line is 0")
            assert_match(target.filepath, "1.1.1. Test File.norg", "resolved filepath")
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)

describe("index.invalidate", function()
    it("forces re-read on next access", function()
        local filepath = root .. "/1.1.1. Test File.norg"
        -- First read (caches)
        index.get_file_headings(filepath, "1.1.1")
        -- Modify the file
        vim.fn.writefile({ "* ( ) 1.1.1.1. Now Undone" }, filepath)
        -- Without invalidate, cache would return stale state
        index.invalidate(filepath)
        local state = index.get_file_state(filepath, "1.1.1")
        assert_eq(state, "undone", "state refreshed after invalidate")
    end)
end)
