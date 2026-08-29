local pr = require("differ.pr")

describe("pr.error_hint", function()
    it("gives a fixable code its static hint", function()
        assert.are.equal("run gh auth login", pr.error_hint({ code = "auth" }))
        assert.are.equal("install gh or set GH_TOKEN", pr.error_hint({ code = "gh_missing" }))
    end)

    it("has no hint for a code the user cannot act on", function()
        assert.is_nil(pr.error_hint({ code = "internal" }))
        assert.is_nil(pr.error_hint({ code = "not_found" }))
        assert.is_nil(pr.error_hint(nil))
    end)

    it("spends github's retry_after when it sent one", function()
        assert.are.equal(
            "github rate limit hit, retry in 30s",
            pr.error_hint({ code = "rate_limited", retry_after = 30 })
        )
        assert.are.equal(
            "github rate limit hit, retry in 2m",
            pr.error_hint({ code = "rate_limited", retry_after = 90 })
        )
    end)

    -- a secondary limit and a graphql RATE_LIMITED both arrive without one
    it("falls back to the static wording with no usable retry_after", function()
        local static = "github rate limit hit, retry shortly"
        assert.are.equal(static, pr.error_hint({ code = "rate_limited" }))
        assert.are.equal(static, pr.error_hint({ code = "rate_limited", retry_after = 0 }))
    end)

    it("ignores retry_after on any other code", function()
        assert.is_nil(pr.error_hint({ code = "internal", retry_after = 30 }))
    end)
end)
