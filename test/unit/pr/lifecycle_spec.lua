local pr = require("differ.pr")
local checks = require("differ.pr.checks")

describe("pr.state_for_verb", function()
    it("maps each lifecycle verb to its set_pr_state value", function()
        assert.are.equal("ready", pr.state_for_verb("ready"))
        assert.are.equal("draft", pr.state_for_verb("draft"))
        assert.are.equal("closed", pr.state_for_verb("close"))
        assert.are.equal("open", pr.state_for_verb("reopen"))
    end)

    it("returns nil for an unknown verb", function()
        assert.is_nil(pr.state_for_verb("merge"))
        assert.is_nil(pr.state_for_verb("frobnicate"))
    end)
end)

describe("pr.merge_method", function()
    it("passes a valid method through", function()
        assert.are.equal("squash", pr.merge_method("squash"))
        assert.are.equal("merge", pr.merge_method("merge"))
        assert.are.equal("rebase", pr.merge_method("rebase"))
    end)

    it("defaults to squash for nil or an unknown method", function()
        assert.are.equal("squash", pr.merge_method(nil))
        assert.are.equal("squash", pr.merge_method(""))
        assert.are.equal("squash", pr.merge_method("ff-only"))
    end)
end)

describe("pr.is_destructive", function()
    it("gates merge and close behind a confirm", function()
        assert.is_true(pr.is_destructive("merge"))
        assert.is_true(pr.is_destructive("close"))
    end)

    it("leaves reversible verbs unprompted", function()
        assert.is_false(pr.is_destructive("ready"))
        assert.is_false(pr.is_destructive("draft"))
        assert.is_false(pr.is_destructive("reopen"))
        assert.is_false(pr.is_destructive("checkout"))
    end)
end)

describe("pr.checks.state_of", function()
    it("buckets a completed check by its conclusion", function()
        assert.are.equal(
            "success",
            checks.state_of({ status = "COMPLETED", conclusion = "SUCCESS" })
        )
        assert.are.equal(
            "failure",
            checks.state_of({ status = "COMPLETED", conclusion = "FAILURE" })
        )
        assert.are.equal(
            "failure",
            checks.state_of({ status = "COMPLETED", conclusion = "TIMED_OUT" })
        )
        assert.are.equal(
            "neutral",
            checks.state_of({ status = "COMPLETED", conclusion = "SKIPPED" })
        )
    end)

    it("treats a still-running check as pending regardless of conclusion", function()
        assert.are.equal("pending", checks.state_of({ status = "IN_PROGRESS", conclusion = "" }))
        assert.are.equal("pending", checks.state_of({ status = "QUEUED", conclusion = "SUCCESS" }))
    end)

    it("maps a legacy StatusContext pending state to pending", function()
        assert.are.equal("pending", checks.state_of({ status = "PENDING", conclusion = "PENDING" }))
        assert.are.equal("pending", checks.rollup_state("PENDING"))
        assert.are.equal("success", checks.rollup_state("SUCCESS"))
        assert.are.equal("failure", checks.rollup_state("FAILURE"))
        assert.are.equal("failure", checks.rollup_state("ERROR"))
    end)
end)
