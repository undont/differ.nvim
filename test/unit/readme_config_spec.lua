local config = require("differ.config")

local function readme_block()
    local f = assert(io.open("README.md"))
    local src = f:read("*a")
    f:close()
    return assert(
        src:match("## Configuration.-```lua\n(.-)```"),
        "no lua block under ## Configuration"
    )
end

-- ci runs busted on lua 5.1 (setfenv), a local luarocks busted may be 5.2+ (load env)
local function compile(src, env)
    if setfenv then
        return setfenv(assert(loadstring(src, "README.md")), env)
    end
    return assert(load(src, "README.md", "t", env))
end

local function evaluate(block)
    local captured
    local stub = {
        setup = function(opts)
            captured = opts
        end,
    }
    compile(block, {
        require = function()
            return stub
        end,
    })()
    return captured
end

local function show(value)
    if type(value) == "string" then
        return ('"%s"'):format(value)
    end
    return tostring(value)
end

local function drift(defaults, readme, path, out)
    for key, default in pairs(defaults) do
        local where, value = path .. key, readme[key]
        if type(default) == "table" and type(value) == "table" then
            drift(default, value, where .. ".", out)
        elseif value == nil then
            out[#out + 1] = ("%s: missing from README, default %s"):format(where, show(default))
        elseif value ~= default then
            out[#out + 1] = ("%s: README %s, default %s"):format(where, show(value), show(default))
        end
    end
    for key, value in pairs(readme) do
        if defaults[key] == nil then
            out[#out + 1] = ("%s: README %s, not a default"):format(path .. key, show(value))
        end
    end
    return out
end

describe("README configuration block", function()
    local block = readme_block()

    it("matches config.defaults key by key", function()
        assert.are.same({}, drift(config.defaults, evaluate(block), "", {}))
    end)

    it("writes every nil default as key = nil", function()
        local missing = {}
        for key in pairs(config.nilable) do
            if not block:match("\n%s*" .. key .. "%s*=%s*nil") then
                missing[#missing + 1] = key
            end
        end
        assert.are.same({}, missing)
    end)

    it("writes no nil key that config.nilable doesn't list", function()
        local unknown = {}
        for key in block:gmatch("([%w_]+)%s*=%s*nil") do
            if not config.nilable[key] then
                unknown[#unknown + 1] = key
            end
        end
        assert.are.same({}, unknown)
    end)
end)
