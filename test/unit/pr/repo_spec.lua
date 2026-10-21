local repo = require("differ.pr.repo")

describe("pr.repo.parse_remote", function()
    it("parses an scp-style git@github.com remote", function()
        assert.are.same(
            { owner = "undont", repo = "differ.nvim" },
            repo.parse_remote("git@github.com:undont/differ.nvim.git")
        )
    end)

    it("parses an https remote with a .git suffix", function()
        assert.are.same(
            { owner = "octo", repo = "cat" },
            repo.parse_remote("https://github.com/octo/cat.git")
        )
    end)

    it("parses an https remote without a .git suffix", function()
        assert.are.same(
            { owner = "octo", repo = "cat" },
            repo.parse_remote("https://github.com/octo/cat")
        )
    end)

    it("parses an ssh:// remote, stripping the userinfo", function()
        assert.are.same(
            { owner = "octo", repo = "cat" },
            repo.parse_remote("ssh://git@github.com/octo/cat.git")
        )
    end)

    it("tolerates a trailing slash and surrounding whitespace", function()
        assert.are.same(
            { owner = "octo", repo = "cat" },
            repo.parse_remote("  https://github.com/octo/cat/\n")
        )
    end)

    it("rejects a non-github host", function()
        assert.is_nil(repo.parse_remote("git@gitlab.com:octo/cat.git"))
        assert.is_nil(repo.parse_remote("https://bitbucket.org/octo/cat.git"))
    end)

    it("rejects a github url that is not an owner/repo pair", function()
        assert.is_nil(repo.parse_remote("https://github.com/octo"))
        assert.is_nil(repo.parse_remote("https://github.com/octo/cat/extra"))
    end)

    it("rejects empty / non-string input", function()
        assert.is_nil(repo.parse_remote(""))
        assert.is_nil(repo.parse_remote(nil))
        assert.is_nil(repo.parse_remote(42))
    end)
end)
