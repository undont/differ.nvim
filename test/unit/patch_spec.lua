local patch = require("differ.git.patch")

describe("patch.hunk", function()
    it("builds a zero-context patch for a one-line modification", function()
        local h = {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 1,
            old_lines = { "local x = 1" },
            new_lines = { "local x = 2" },
        }
        local p = patch.hunk("a.lua", h, "local x = 1\nreturn x\n", "local x = 2\nreturn x\n")
        assert.are.equal(
            "diff --git a/a.lua b/a.lua\n"
                .. "--- a/a.lua\n"
                .. "+++ b/a.lua\n"
                .. "@@ -1,1 +1,1 @@\n"
                .. "-local x = 1\n"
                .. "+local x = 2\n",
            p
        )
    end)

    it("emits all removed lines before added lines", function()
        local h = {
            old_start = 2,
            old_count = 2,
            new_start = 2,
            new_count = 1,
            old_lines = { "b", "c" },
            new_lines = { "X" },
        }
        local p = patch.hunk("f", h, "a\nb\nc\nd\n", "a\nX\nd\n")
        assert.are.equal("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -2,2 +2,1 @@\n-b\n-c\n+X\n", p)
    end)

    it("formats a pure insertion (old_count 0) against the preceding line", function()
        local h = {
            old_start = 1,
            old_count = 0,
            new_start = 2,
            new_count = 1,
            old_lines = {},
            new_lines = { "b" },
        }
        local p = patch.hunk("f", h, "a\n", "a\nb\n")
        assert.are.equal("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,0 +2,1 @@\n+b\n", p)
    end)

    it("marks a missing final newline on each side that reaches EOF", function()
        -- old "a\nb" (no trailing nl) -> "a\nB" (no trailing nl): the second line is
        -- the file's last on both sides, so both -/+ lines get the marker
        local h = {
            old_start = 2,
            old_count = 1,
            new_start = 2,
            new_count = 1,
            old_lines = { "b" },
            new_lines = { "B" },
        }
        local p = patch.hunk("f", h, "a\nb", "a\nB")
        assert.are.equal(
            "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -2,1 +2,1 @@\n"
                .. "-b\n\\ No newline at end of file\n"
                .. "+B\n\\ No newline at end of file\n",
            p
        )
    end)

    it("shifts the located side by the staged-hunk offset (forward stage)", function()
        -- a hunk at old/new line 5, with two extra lines already staged before it,
        -- applies at index line 7. forward apply locates by the `-` side, so old_start
        -- shifts to 7 and new_start stays frozen at 5
        local h = {
            old_start = 5,
            old_count = 1,
            new_start = 5,
            new_count = 1,
            old_lines = { "e" },
            new_lines = { "E" },
        }
        -- both sides name the same place: a one-hunk patch has nothing ahead of it to
        -- shift one relative to the other
        local p = patch.hunk("f", h, "a\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n", 2)
        assert.is_truthy(p:find("@@ -7,1 +7,1 @@", 1, true), p)
    end)

    it("never emits a negative line number when a deletion offset underflows", function()
        -- an earlier staged hunk deleted 6 lines (net offset -6), more than precede this
        -- one. a real hunk can't reach that, but `@@ -3,1 +-3,1 @@` is rejected outright
        -- as a corrupt patch at line 4, so the clamp keeps it merely wrong, not fatal
        local h = {
            old_start = 3,
            old_count = 1,
            new_start = 3,
            new_count = 1,
            old_lines = { "i" },
            new_lines = { "I" },
        }
        local p = patch.hunk("f", h, "", "", -6)
        local header = p:match("@@[^\n]*@@")
        assert.is_nil(header:find("%-%-"), "negative old_start in header: " .. header)
        assert.is_nil(header:find("%+%-"), "negative new_start in header: " .. header)
    end)

    -- git can only relocate a hunk by content where a side has content. staging a pure
    -- insertion leaves the `-` side empty, so git reads `+` instead, and that side has
    -- to name the index too or the lines land somewhere else entirely
    it("puts a staged insertion's `+` side in index coordinates", function()
        local h = {
            old_start = 20,
            old_count = 0,
            new_start = 31,
            new_count = 2,
            old_lines = {},
            new_lines = { "x", "y" },
        }
        -- 4 lines staged ahead of it: the insert follows index line 24, occupying 25-26
        local p = patch.hunk("f", h, "", "", 4, "old")
        assert.is_truthy(p:find("@@ -24,0 +25,2 @@", 1, true), p)
    end)

    -- the mirror: unstaging a pure deletion leaves the `+` side empty, so git reads `-`
    it("puts an unstaged deletion's `-` side in index coordinates", function()
        local h = {
            old_start = 5,
            old_count = 2,
            new_start = 6,
            new_count = 0,
            old_lines = { "e", "f" },
            new_lines = {},
        }
        local p = patch.hunk("f", h, "", "", 2, "old")
        assert.is_truthy(p:find("@@ -7,2 +6,0 @@", 1, true), p)
    end)

    -- a revert patches the file the new side was read from, so it anchors on new_start
    it("anchors a revert on the new side", function()
        local h = {
            old_start = 3,
            old_count = 1,
            new_start = 9,
            new_count = 1,
            old_lines = { "i" },
            new_lines = { "I" },
        }
        local p = patch.hunk("f", h, "", "", -6, "new")
        assert.is_truthy(p:find("@@ -3,1 +3,1 @@", 1, true), p)
    end)

    it("anchors a reverted deletion on the line the new side left behind", function()
        local h = {
            old_start = 5,
            old_count = 2,
            new_start = 6,
            new_count = 0,
            old_lines = { "e", "f" },
            new_lines = {},
        }
        -- the empty new side names line 6, so the block itself begins at 7
        local p = patch.hunk("f", h, "", "", 0, "new")
        assert.is_truthy(p:find("@@ -7,2 +6,0 @@", 1, true), p)
    end)

    it("omits the marker when the hunk does not reach an unterminated EOF", function()
        -- the file lacks a trailing newline, but the hunk touches the first line only
        local h = {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 1,
            old_lines = { "a" },
            new_lines = { "A" },
        }
        local p = patch.hunk("f", h, "a\nb", "A\nb")
        assert.is_nil(p:find("No newline", 1, true))
    end)
end)
