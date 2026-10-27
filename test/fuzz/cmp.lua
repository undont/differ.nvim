-- the stage fuzz run over the same seeded cases against lua/ at a git rev and against
-- the working tree, counting how each op's outcome moves from one to the other. each
-- side gets its own differ.* modules and its own copy of the harness, swapped in
-- package.loaded around every op, since the op core requires some modules lazily

local M = {}

---@class differ.fuzz.Side
---@field path string                -- package.path while this side runs
---@field loaded table<string, any>  -- its differ.* modules and harness
---@field fuzz table                 -- test.fuzz.stage as this side loads it

---@param name string
---@return boolean
local function swapped(name)
    return name == "differ" or name:match("^differ%.") ~= nil or name == "test.fuzz.stage"
end

local current ---@type differ.fuzz.Side|nil

---@param side differ.fuzz.Side
local function use(side)
    if current == side then
        return
    end
    for name, mod in pairs(package.loaded) do
        if swapped(name) then
            if current then
                current.loaded[name] = mod
            end
            package.loaded[name] = nil
        end
    end
    package.path = side.path
    for name, mod in pairs(side.loaded) do
        package.loaded[name] = mod
    end
    current = side
end

---@param path string
---@return differ.fuzz.Side
local function side_at(path)
    local side = { path = path, loaded = {} }
    use(side)
    side.fuzz = require("test.fuzz.stage")
    return side
end

---@param cmd string[]
---@return string
local function run(cmd)
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then
        error(("%s: %s"):format(table.concat(cmd, " "), r.stderr), 0)
    end
    return r.stdout
end

-- lua/ at `rev`, unpacked into a new temp dir
---@param rev string
---@return string dir, string sha
local function archive(rev)
    local sha = vim.trim(run({ "git", "rev-parse", "--verify", rev .. "^{commit}" }))
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    run({ "sh", "-c", 'git archive "$1" lua | tar -x -C "$2"', "sh", sha, dir })
    return dir, sha
end

---@param o differ.fuzz.Outcome
---@return string
local function kind(o)
    if o.kind == "refused" then
        return o.reason
    end
    return o.kind
end

---@class differ.fuzz.Change
---@field op string
---@field what string  -- the transition
---@field triple differ.fuzz.Triple
---@field rows differ.fuzz.Row[]
---@field old differ.fuzz.Outcome
---@field new differ.fuzz.Outcome

---@class differ.fuzz.Cmp
---@field rev string
---@field sha string
---@field order string[]  -- the ops
---@field ops table<string, table<string, integer>>  -- op -> transition -> count
---@field regressions table<string, table<string, integer>>
---@field shown differ.fuzz.Change[]  -- the first few regressions, then changed texts

-- a new side that refuses what the old one wrote or left alone, or writes what the
-- oracle reads as wrong where the old one didn't
---@param old differ.fuzz.Outcome
---@param new differ.fuzz.Outcome
---@param old_wrong boolean
---@param new_wrong boolean
---@return string|nil
local function regression(old, new, old_wrong, new_wrong)
    if new.kind == "refused" and old.kind ~= "refused" then
        return ("%s -> %s"):format(kind(old), kind(new))
    end
    if new_wrong and not old_wrong then
        return "new mismatch"
    end
    return nil
end

---@param t differ.fuzz.Triple
---@param side differ.fuzz.Side
---@param o differ.fuzz.Outcome
---@return boolean
local function wrong(t, side, o)
    return o.kind == "written" and not side.fuzz.matches(t, o)
end

---@param report differ.fuzz.Cmp
---@param change differ.fuzz.Change
---@param keep integer
local function show(report, change, keep)
    if #report.shown < keep then
        report.shown[#report.shown + 1] = change
    end
end

---@param opts differ.fuzz.Opts
---@param rev string
---@return differ.fuzz.Cmp
function M.run(opts, rev)
    local keep = opts.keep or 5
    local base = package.path
    local dir, sha = archive(rev)
    local old = side_at(("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(dir, dir, base))
    local new = side_at(base)
    local report =
        { rev = rev, sha = sha, order = new.fuzz.OPS, ops = {}, regressions = {}, shown = {} }
    for _, op in ipairs(new.fuzz.OPS) do
        report.ops[op], report.regressions[op] = {}, {}
    end
    local changed = {} ---@type differ.fuzz.Change[]
    local ok, err = pcall(new.fuzz.cases, opts, function(t, rows, selection)
        for _, op in ipairs(new.fuzz.OPS) do
            use(old)
            local was = old.fuzz.run_op(t, op, selection)
            local old_wrong = wrong(t, old, was)
            use(new)
            local now = new.fuzz.run_op(t, op, selection)
            local new_wrong = wrong(t, new, now)
            local what = ("%s -> %s"):format(kind(was), kind(now))
            if kind(was) == kind(now) then
                what = nil
                if now.kind == "written" and (now.index ~= was.index or now.work ~= was.work) then
                    what = "written -> written, other text"
                end
            end
            if not what and new_wrong and not old_wrong then
                what = kind(was) .. " -> " .. kind(now)
            end
            if what then
                local counts = report.ops[op]
                counts[what] = (counts[what] or 0) + 1
                local change =
                    { op = op, what = what, triple = t, rows = rows, old = was, new = now }
                local why = regression(was, now, old_wrong, new_wrong)
                if why then
                    report.regressions[op][why] = (report.regressions[op][why] or 0) + 1
                    show(report, change, keep)
                elseif now.kind == "written" and was.kind == "written" then
                    changed[#changed + 1] = change
                end
            end
        end
    end)
    use(new)
    vim.fn.delete(dir, "rf")
    if not ok then
        error(err, 0)
    end
    for _, change in ipairs(changed) do
        show(report, change, keep)
    end
    return report
end

---@param counts table<string, integer>
---@param op string
---@param out string[]
local function tally(counts, op, out)
    local keys = vim.tbl_keys(counts)
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = ("%s  %-46s %d"):format(op, k, counts[k])
    end
end

---@param o differ.fuzz.Outcome
---@param shown fun(text: string): string
---@return string
local function wrote(o, shown)
    if o.kind ~= "written" then
        return kind(o)
    end
    local line = "index " .. shown(o.index)
    if o.work then
        line = line .. " | work " .. shown(o.work)
    end
    return line
end

---@param report differ.fuzz.Cmp
---@return string
function M.format(report)
    local shown = require("test.fuzz.stage").shown
    local out = { ("cmp %s (%s) -> working tree"):format(report.rev, report.sha:sub(1, 7)) }
    local regressed = {}
    for _, op in ipairs(report.order) do
        tally(report.regressions[op], op, regressed)
    end
    if #regressed == 0 then
        out[#out + 1] = "regressions: none"
    else
        out[#out + 1] = "REGRESSIONS"
        vim.list_extend(out, regressed)
    end
    out[#out + 1] = ""
    for _, op in ipairs(report.order) do
        tally(report.ops[op], op, out)
    end
    for _, c in ipairs(report.shown) do
        local rows = {}
        for _, r in ipairs(c.rows) do
            rows[#rows + 1] = r.side .. " " .. r.line
        end
        out[#out + 1] = ("\n%s on %s: %s"):format(c.op, table.concat(rows, ", "), c.what)
        out[#out + 1] = "  head  " .. shown(c.triple.head)
        out[#out + 1] = "  index " .. shown(c.triple.index)
        out[#out + 1] = "  work  " .. shown(c.triple.work)
        out[#out + 1] = "  old   " .. wrote(c.old, shown)
        out[#out + 1] = "  new   " .. wrote(c.new, shown)
    end
    return table.concat(out, "\n")
end

return M
