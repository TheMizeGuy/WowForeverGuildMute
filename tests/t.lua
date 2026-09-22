-- Minimal test runner: T.test(name, fn), assertions, and T.done() to print a summary and exit.

local T = { passed = 0, failed = 0 }

-- io.write, because tests/wow.lua replaces print to capture the addon's chat output.
local function Say(text)
    io.write(text, "\n")
end

local function Show(value)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    return tostring(value)
end

local function Same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not Same(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

local function Fail(message, level)
    error(message, (level or 1) + 2)
end

function T.ok(value, message)
    if not value then
        Fail(message or "expected a true value")
    end
end

function T.eq(actual, expected, message)
    if actual ~= expected then
        Fail((message and message .. ": " or "") .. "expected " .. Show(expected) .. ", got " .. Show(actual))
    end
end

function T.same(actual, expected, message)
    if not Same(actual, expected) then
        Fail((message and message .. ": " or "") .. "tables differ")
    end
end

function T.test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        T.passed = T.passed + 1
        Say("  PASS  " .. name)
    else
        T.failed = T.failed + 1
        Say("  FAIL  " .. name .. "\n" .. tostring(err))
    end
end

function T.done()
    Say(("%d passed, %d failed"):format(T.passed, T.failed))
    os.exit(T.failed == 0 and 0 or 1)
end

return T
