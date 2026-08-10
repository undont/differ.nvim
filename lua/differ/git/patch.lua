-- build a git-apply-ready unified diff for a single hunk, straight from the hunk
-- model (never derived from buffer text). zero context, so callers apply
-- with `git apply --unidiff-zero`; the `@@` line numbers come from the model and
-- match the index/worktree content exactly. the missing-final-newline marker is
-- emitted when a hunk reaches an unterminated end of file, so staging the last
-- hunk doesn't corrupt it, widening the hunk by one line where the marker would
-- otherwise have no line to sit on. pure: no vim, no git, unit-testable

local to_lines = require("differ.util.text").to_lines

local M = {}

local NO_NL = "\\ No newline at end of file"

-- does `text`'s final line lack a trailing newline (so a hunk reaching it needs
-- the `\ No newline` marker)
---@param text string
---@return boolean
local function unterminated(text)
    return text ~= "" and text:sub(-1) ~= "\n"
end

---@param head string
---@param rest string[]
---@return string[]
local function prepend(head, rest)
    local out = { head }
    for i = 1, #rest do
        out[#out + 1] = rest[i]
    end
    return out
end

-- the marker attaches to a line, so a side that contributes no lines has nowhere to
-- put one. that is exactly the shape of a terminator change at a zero-context hunk:
-- appending past an unterminated last line gives that line a newline, and deleting a
-- tail takes one away, neither of which the hunk itself carries. widen by the last
-- line of the side that owns the terminator so the marker has a line to sit on. the
-- diff runs on newline-ensured copies, so that line is unchanged content and reads
-- the same on both sides; git's own diff widens here for the same reason
---@param hunk differ.Hunk
---@param old_lines string[]
---@param new_lines string[]
---@param old_eof boolean
---@param new_eof boolean
---@return differ.Hunk
local function widen_at_eof(hunk, old_lines, new_lines, old_eof, new_eof)
    local old_n, new_n = #old_lines, #new_lines
    -- a pure insertion naming the old side's last line appends past it: that line
    -- gains a newline, so it has to appear on both sides
    if old_eof and hunk.old_count == 0 and old_n > 0 and hunk.old_start == old_n then
        local tail = old_lines[old_n]
        return {
            old_start = old_n,
            old_count = 1,
            old_lines = { tail },
            new_start = hunk.new_start - 1,
            new_count = hunk.new_count + 1,
            new_lines = prepend(tail, hunk.new_lines),
        }
    end
    -- the mirror: a pure deletion off the end leaves the new side's last line
    -- unterminated, and that line is the only place its marker can go
    if new_eof and hunk.new_count == 0 and new_n > 0 and hunk.new_start == new_n then
        local tail = new_lines[new_n]
        return {
            old_start = hunk.old_start - 1,
            old_count = hunk.old_count + 1,
            old_lines = prepend(tail, hunk.old_lines),
            new_start = new_n,
            new_count = 1,
            new_lines = { tail },
        }
    end
    return hunk
end

-- one hunk as a unified diff against `path`. `old_text`/`new_text` are the full
-- file sides, read only to detect an unterminated end of file. assumes a plain
-- modification (same path both sides); renames/adds/deletes stage file-level.
-- `base` names which of the hunk's own coordinates the file being patched is measured
-- in: "old" for staging and unstaging, which patch the index (the hunk sits at its
-- old-side start there, since the index is HEAD plus whatever is staged), "new" for a
-- revert, which patches the file the diff's new side was read from. `offset` then
-- shifts that start onto the live file, the frozen view's numbers being from open time
-- while git applies against a file that has moved since.
--
-- both sides of the `@@` carry it, and both name the same place: a one-hunk patch has
-- nothing ahead of it to shift one side relative to the other. under `--unidiff-zero`
-- git relocates a hunk by content, but only where it has content to relocate by, and a
-- side with no lines (staging a pure insertion, unstaging or reverting a pure deletion)
-- leaves it trusting the header instead. a side left frozen there doesn't fail loudly,
-- it lands the hunk somewhere else entirely
---@param path string
---@param hunk differ.Hunk
---@param old_text string
---@param new_text string
---@param offset integer|nil
---@param base "old"|"new"|nil  -- which side's coordinates the patched file is in; default "old"
---@return string
function M.hunk(path, hunk, old_text, new_text, offset, base)
    offset = offset or 0
    local old_lines, new_lines = to_lines(old_text), to_lines(new_text)
    local old_n, new_n = #old_lines, #new_lines
    local old_eof, new_eof = unterminated(old_text), unterminated(new_text)

    hunk = widen_at_eof(hunk, old_lines, new_lines, old_eof, new_eof)

    -- where the hunk's block begins in the file being patched. git names a zero-length
    -- side by the line it follows rather than the line it occupies, so a base side with
    -- no lines is one short of the block's own position; clamped so the headers below
    -- stay non-negative, which git rejects outright as a corrupt patch
    local on_new = base == "new"
    local start = on_new and hunk.new_start or hunk.old_start
    local base_empty = (on_new and hunk.new_count or hunk.old_count) == 0
    local at = math.max(1, start + offset + (base_empty and 1 or 0))
    -- and back to git's convention for each side, now in the target's coordinates
    local old_at = hunk.old_count == 0 and at - 1 or at
    local new_at = hunk.new_count == 0 and at - 1 or at

    local out = {
        ("diff --git a/%s b/%s"):format(path, path),
        "--- a/" .. path,
        "+++ b/" .. path,
        ("@@ -%d,%d +%d,%d @@"):format(old_at, hunk.old_count, new_at, hunk.new_count),
    }
    for i, line in ipairs(hunk.old_lines) do
        out[#out + 1] = "-" .. line
        if old_eof and (hunk.old_start + i - 1) == old_n then
            out[#out + 1] = NO_NL
        end
    end
    for i, line in ipairs(hunk.new_lines) do
        out[#out + 1] = "+" .. line
        if new_eof and (hunk.new_start + i - 1) == new_n then
            out[#out + 1] = NO_NL
        end
    end
    return table.concat(out, "\n") .. "\n"
end

return M
