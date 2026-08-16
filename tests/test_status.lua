--- Tests for the status module.
--- Covers: aggregate_state, build_directory_tree, render_as_norg, surgical update

local cfg = require("neorg-project-manager.config")
local status = require("neorg-project-manager.status")
local index = require("neorg-project-manager.index")

-- Setup test project
local root = "/tmp/test_pm_status"
vim.fn.delete(root, "rf")
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/1.1. Stage 1", "p")
vim.fn.writefile({ "" }, root .. "/project.norg")
vim.fn.writefile({ "* (x) Done" }, root .. "/1.1. Stage 1/1.1.1. Setup.norg")
vim.fn.writefile({ "* ( ) Todo" }, root .. "/1.1. Stage 1/1.1.2. Feature.norg")
vim.fn.writefile({ "* (-) WIP" }, root .. "/1.1. Stage 1/1.1.3. Auth.norg")

cfg.set({
    numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
    number_separator = ".",
    number_title_separator = ". ",
    number_format = nil,
})

describe("status.aggregate_state", function()
    it("all done → done", function()
        local state, done, total = status.aggregate_state({ "done", "done", "done" })
        assert_eq(state, "done", "all done")
        assert_eq(done, 3, "3 done")
        assert_eq(total, 3, "3 total")
    end)

    it("some done → pending", function()
        local state, done, total = status.aggregate_state({ "done", "undone", "done" })
        assert_eq(state, "pending", "some done")
        assert_eq(done, 2, "2 done")
        assert_eq(total, 3, "3 total")
    end)

    it("none done → undone", function()
        local state, _, _ = status.aggregate_state({ "undone", "undone" })
        assert_eq(state, "undone", "none done")
    end)

    it("empty → undone with 0/0", function()
        local state, done, total = status.aggregate_state({})
        assert_eq(state, "undone", "empty → undone")
        assert_eq(done, 0, "0 done")
        assert_eq(total, 0, "0 total")
    end)

    it("all on_hold → on_hold", function()
        local state, _, _ = status.aggregate_state({ "on_hold", "on_hold" })
        assert_eq(state, "on_hold", "all on_hold")
    end)

    it("pending items → pending", function()
        local state, _, _ = status.aggregate_state({ "undone", "pending", "undone" })
        assert_eq(state, "pending", "has pending")
    end)
end)

describe("status.build_directory_tree", function()
    it("builds tree with aggregated state", function()
        index.rebuild()
        local tree = status.build_directory_tree(root .. "/1.1. Stage 1")
        assert_eq(tree.state, "pending", "directory state is pending (1 done, 1 undone, 1 pending)")
        assert_eq(#tree.children, 3, "3 children")
        assert_eq(tree.done, 1, "1 child done")
        assert_eq(tree.total, 3, "3 total children")
    end)

    it("children are sorted by prefix", function()
        index.rebuild()
        local tree = status.build_directory_tree(root .. "/1.1. Stage 1")
        assert_eq(tree.children[1].prefix, "1.1.1", "first child is 1.1.1")
        assert_eq(tree.children[2].prefix, "1.1.2", "second child is 1.1.2")
        assert_eq(tree.children[3].prefix, "1.1.3", "third child is 1.1.3")
    end)
end)

describe("status.render_as_norg", function()
    it("renders a tree with todo states and links", function()
        index.rebuild()
        local tree = status.build_project_tree(root)
        local lines = status.render_as_norg(tree, { max_depth = 6, base_level = 0 })
        assert_true(#lines > 0, "rendered lines not empty")
        -- Check that managed headings have {* prefix} links
        local has_link = false
        for _, line in ipairs(lines) do
            if line:match("{%* 1.1.1}") then has_link = true end
        end
        assert_true(has_link, "rendered tree includes {* 1.1.1} link")
    end)

    it("respects max_depth", function()
        index.rebuild()
        local tree = status.build_project_tree(root)
        local lines = status.render_as_norg(tree, { max_depth = 1, base_level = 0 })
        -- max_depth 1 → only root heading
        assert_eq(#lines, 1, "max_depth=1 → only root")
    end)
end)

describe("status.update_file (surgical)", function()
    it("updates managed heading states without destroying manual content", function()
        index.rebuild()
        -- Write a project.norg with manual + managed content
        vim.fn.writefile({
            "* Project Overview",
            "  My manual notes.",
            "",
            "** (-) 1.1. Stage 1 {* 1.1} [0/3]",
            "*** ( ) 1.1.1. Setup {* 1.1.1}",
            "*** ( ) 1.1.2. Feature {* 1.1.2}",
            "*** ( ) 1.1.3. Auth {* 1.1.3}",
            "",
            "** My Notes",
            "   Architecture decisions.",
        }, root .. "/project.norg")

        status.update_file(root .. "/project.norg", root, "project")

        local lines = vim.fn.readfile(root .. "/project.norg")

        -- Manual content preserved
        assert_eq(lines[1], "* Project Overview", "manual heading preserved")
        assert_eq(lines[2], "  My manual notes.", "manual text preserved")
        assert_match(lines[9] or lines[10] or "", "My Notes", "manual notes heading preserved")

        -- Managed headings updated
        local found_setup_done = false
        local found_feature_undone = false
        for _, line in ipairs(lines) do
            if line:match("1.1.1") and line:match("%(x%)") then found_setup_done = true end
            if line:match("1.1.2") and line:match("%(%)") or line:match("%( %)") then found_feature_undone = true end
        end
        assert_true(found_setup_done, "1.1.1 Setup state updated to (x)")
    end)

    it("inserts missing entries for new files", function()
        index.rebuild()
        -- Add a new file
        vim.fn.writefile({ "* ( ) New" }, root .. "/1.1. Stage 1/1.1.4. New Feature.norg")

        vim.fn.writefile({
            "** (-) 1.1. Stage 1 {* 1.1} [1/3]",
            "*** (x) 1.1.1. Setup {* 1.1.1}",
            "*** ( ) 1.1.2. Feature {* 1.1.2}",
            "*** (-) 1.1.3. Auth {* 1.1.3}",
        }, root .. "/project.norg")

        status.update_file(root .. "/project.norg", root, "project")

        local lines = vim.fn.readfile(root .. "/project.norg")
        local found_new = false
        for _, line in ipairs(lines) do
            if line:match("1.1.4") and line:match("New Feature") then
                found_new = true
            end
        end
        assert_true(found_new, "new file 1.1.4 inserted")

        -- Cleanup
        vim.fn.delete(root .. "/1.1. Stage 1/1.1.4. New Feature.norg")
    end)
end)
