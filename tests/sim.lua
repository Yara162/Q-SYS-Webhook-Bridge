-- Runs the Webhook Bridge plugin's real code under Lua 5.3 against stand-ins for the Q-SYS runtime
-- and a fake web server, and checks its behaviour. Usage (from the plugin folder):
--   lua5.3 tests/sim.lua webhook-bridge.qplug
-- Prints PASS/FAIL per check; exits 0 when all pass.
--
-- ASSUMPTIONS the stand-ins make about Q-SYS. A green run shows the plugin's logic is right if these
-- hold, nothing more. None has been confirmed on a Core yet.
--  1. Writing .Value / .Boolean / .String from Lua does not fire that control's EventHandler.
--  2. Setting .Boolean sets .Value to 1/0 and the reverse.
--  3. HttpClient.Upload{Url, Method, Data, Headers, Timeout, EventHandler} calls
--     EventHandler(tbl, code, data, err, headers) once; code is 0 when no answer came.
--  4. HttpClient.Get takes the same table without Method/Data (Download where Get is absent).
--  5. Timer.CallAfter(fn, seconds) runs fn later; Timer.Now() is seconds as a number.
--  6. Design.GetStatus() returns a table with DesignName.

local path = arg[1] or "webhook-bridge.qplug"
local results = { pass = 0, fail = 0 }
local function check(name, ok, detail)
    if ok then results.pass = results.pass + 1 else results.fail = results.fail + 1 end
    print((ok and "PASS  " or "FAIL  ") .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
end

-- ------------------------------------------------------------------ design time
local src = assert(io.open(path, "rb")):read("a")

local function loadPlugin(env)
    local chunk = assert(load(src, "@" .. path, "t", env))
    chunk()
    return env
end

do
    local env = setmetatable({}, { __index = _G })
    loadPlugin(env)
    local props = {}
    for _, p in ipairs(env.GetProperties()) do props[p.Name] = { Value = p.Value } end
    local names = {}
    for _, c in ipairs(env.GetControls(props)) do names[c.Name] = c end
    check("default design declares 4 triggers", names["T04Url"] ~= nil and names["T05Url"] == nil)
    for page = 1, 3 do
        props.page_index = { Value = page }
        local layout = env.GetControlLayout(props)
        local missing
        for k in pairs(layout) do if not names[k] then missing = k end end
        check("page " .. page .. " lays out only declared controls", missing == nil, missing)
    end
    props["Trigger Count"].Value = 16
    local n = 0
    for _ in pairs(env.GetControls(props)) do n = n + 1 end
    check("16 triggers declare 11 + 16 * 11 controls", n == 11 + 16 * 11, n)
end

-- ------------------------------------------------------------------ runtime stand-ins
local clock = 0
local timers = {}
local requests = {}

local function newControl(name)
    local c = { Name = name, _value = 0, _string = "", Choices = {}, Legend = "" }
    return setmetatable(c, {
        __index = function(t, k)
            if k == "Value" then return rawget(t, "_value")
            elseif k == "Boolean" then return rawget(t, "_value") ~= 0
            elseif k == "String" then return rawget(t, "_string") end
        end,
        __newindex = function(t, k, v)
            if k == "Value" then rawset(t, "_value", v); rawset(t, "_string", tostring(v))
            elseif k == "Boolean" then rawset(t, "_value", v and 1 or 0)
            elseif k == "String" then rawset(t, "_string", v)
            else rawset(t, k, v) end
        end,
    })
end

-- A user (or a wired pin) changing a control: sets it, then fires its handler.
local function user(ctl, field, v)
    ctl[field] = v
    if ctl.EventHandler then ctl.EventHandler(ctl) end
end

local function runTimers()
    local again = true
    while again do
        again = false
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = table.remove(timers, 1)
        if t then
            clock = math.max(clock, t.at)
            t.fn()
            again = true
        end
    end
end

-- Answer the oldest unanswered request with `code`.
local function answer(code, err)
    for _, r in ipairs(requests) do
        if not r.answered then
            r.answered = true
            r.args.EventHandler({}, code, "", err or "")
            return r
        end
    end
end

local function boot(trigCount, propOverrides)
    clock, timers, requests = 0, {}, {}
    local env = setmetatable({}, { __index = _G })
    local props = {
        ["Trigger Count"] = { Value = trigCount or 4 },
        ["Timeout (seconds)"] = { Value = 5 },
        ["Retries"] = { Value = 1 },
        ["Queue Size"] = { Value = 3 },
        ["Min Seconds Between Sends"] = { Value = 0 },
        ["Log Requests"] = { Value = false },
    }
    for k, v in pairs(propOverrides or {}) do props[k] = { Value = v } end
    -- Build controls from the plugin's own GetControls.
    local design = setmetatable({}, { __index = _G })
    loadPlugin(design)
    local controls = {}
    for _, c in ipairs(design.GetControls(props)) do controls[c.Name] = newControl(c.Name) end
    env.Controls = controls
    env.Properties = props
    env.print = function() end
    env.Timer = {
        Now = function() return clock end,
        CallAfter = function(fn, s) table.insert(timers, { at = clock + s, fn = fn }) end,
    }
    env.HttpClient = {
        Upload = function(args) table.insert(requests, { args = args }) end,
        Get = function(args) args.Method = "GET"; table.insert(requests, { args = args }) end,
    }
    env.Design = { GetStatus = function() return { DesignName = "Boardroom \"A\"" } end }
    loadPlugin(env)
    return env, controls
end

-- ------------------------------------------------------------------ helpers
do
    local env = boot()
    check("JoinUrl: base + /path", env.JoinUrl("http://ha.local:8123/", "/api/webhook/x") == "http://ha.local:8123/api/webhook/x")
    check("JoinUrl: base + path", env.JoinUrl("http://h/api", "x") == "http://h/api/x")
    check("JoinUrl: full URL wins", env.JoinUrl("http://h", "https://hooks.slack.com/a") == "https://hooks.slack.com/a")
    check("JoinUrl: empty URL is the base", env.JoinUrl("http://h/hook", "") == "http://h/hook")
    local h = env.ParseHeaders("X-Room: Board 1; X-Key:abc ;bad")
    check("ParseHeaders", h["X-Room"] == "Board 1" and h["X-Key"] == "abc" and h["bad"] == nil)
    check("Expand: JSON escaping", env.Expand('{"s":"{string}"}', { string = 'say "hi"\n' }, "json") == '{"s":"say \\"hi\\"\\n"}')
    check("Expand: URL encoding", env.Expand("/x?r={name}", { name = "Room A&B" }, "url") == "/x?r=Room%20A%26B")
    check("Expand: unknown placeholder kept", env.Expand("{nope} {name}", { name = "n" }, "text") == "{nope} n")
end

-- ------------------------------------------------------------------ behaviour
do
    local env, C = boot()
    C.T01Url.String = "http://example.test/hook"
    C.T01Enabled.Boolean = true
    user(C.T01In, "Boolean", true)
    check("nothing is sent while Active is off", #requests == 0)
    check("Status says Off", C.Status.Value == 3)

    user(C.Active, "Boolean", true)
    user(C.T01In, "Boolean", false)
    check("On Change fires on a change", #requests == 1, #requests)
    local r = requests[1].args
    check("default method is POST", r.Method == "POST")
    check("default body is JSON with the trigger values",
        r.Data:find('"trigger":"Trigger 1"', 1, true) and r.Data:find('"value":0', 1, true)
        and r.Data:find('"string":"false"', 1, true) ~= nil, r.Data)
    check("design name is JSON-escaped", r.Data:find('"design":"Boardroom \\"A\\""', 1, true) ~= nil, r.Data)
    check("Content-Type is application/json", r.Headers["Content-Type"] == "application/json")
    answer(200)
    check("200 counts as sent and lights OK", C.Sent.String == "1" and C.T01Ok.Boolean)
    check("Status OK after success", C.Status.Value == 0 and C.Status.String == "OK")
end

do
    local env, C = boot()
    user(C.Active, "Boolean", true)
    C.BaseUrl.String = "http://nodered.local:1880"
    C.Headers.String = "X-Room: Boardroom"
    C.Token.String = "secret123"
    C.T02Enabled.Boolean = true
    C.T02Mode.String = "On Rising"
    C.T02Url.String = "/room/{name}"
    C.T02Name.String = "Occupancy Sensor"
    user(C.T02In, "Boolean", true)
    user(C.T02In, "Boolean", false)
    check("On Rising fires once for true then false", #requests == 1, #requests)
    local a = requests[1].args
    check("relative URL joined to Base URL and URL-encoded", a.Url == "http://nodered.local:1880/room/Occupancy%20Sensor", a.Url)
    check("custom header sent", a.Headers["X-Room"] == "Boardroom")
    check("bearer token sent", a.Headers["Authorization"] == "Bearer secret123")
    answer(204)

    C.T03Enabled.Boolean = true
    C.T03Mode.String = "On Falling"
    C.T03Url.String = "/f"
    user(C.T03In, "Boolean", true)
    check("On Falling ignores rising", #requests == 1)
    user(C.T03In, "Boolean", false)
    check("On Falling fires on falling", #requests == 2)
    answer(200)

    C.T04Enabled.Boolean = true
    C.T04Mode.String = "Manual"
    C.T04Url.String = "/m"
    C.T04Method.String = "GET"
    user(C.T04In, "Boolean", true)
    check("Manual ignores the input", #requests == 2)
    user(C.T04Send, "Boolean", true)
    check("Send fires a Manual trigger", #requests == 3)
    check("GET carries no body", requests[3].args.Method == "GET" and requests[3].args.Data == nil)
    answer(200)
end

do
    local env, C = boot()
    user(C.Active, "Boolean", true)
    C.T01Url.String = "http://x/h"
    C.T01Body.String = "level={value} at {time}"
    C.T01Enabled.Boolean = true
    user(C.T01Text, "String", "-12.5")
    local a = requests[1].args
    check("text body is not JSON-escaped and uses the number", a.Data:match("^level=%-12%.5 at %d") ~= nil, a.Data)
    check("text body gets text/plain", a.Headers["Content-Type"] == "text/plain")
    answer(200)

    C.T01Enabled.Boolean = false
    user(C.T01Text, "String", "1")
    check("a disabled trigger does not fire", #requests == 1)
    user(C.T01Send, "Boolean", true)
    check("Send still works on a disabled trigger (for testing)", #requests == 2)
    answer(200)
end

do
    local env, C = boot(4, { ["Retries"] = 2 })
    user(C.Active, "Boolean", true)
    C.T01Url.String = "http://x/h"
    C.T01Enabled.Boolean = true
    user(C.T01In, "Boolean", true)
    answer(503)
    check("503 is retried, not failed yet", C.Failed.String == "0" and #timers == 1)
    runTimers()
    check("retry sent", #requests == 2)
    answer(0, "timeout")
    runTimers()
    check("second retry sent", #requests == 3)
    answer(200)
    check("success after retries", C.Sent.String == "1" and C.Failed.String == "0")

    user(C.T01In, "Boolean", false)
    answer(404)
    check("404 fails without retry", C.Failed.String == "1" and #timers == 0)
    check("Status shows the fault", C.Status.Value == 2 and C.Status.String:find("404") ~= nil, C.Status.String)
    check("trigger shows the failure", not C.T01Ok.Boolean and C.T01Last.String:find("404") ~= nil)
    user(C.Clear, "Boolean", true)
    check("Clear resets counts and status", C.Failed.String == "0" and C.Status.Value == 0)
end

do
    local env, C = boot(4, { ["Queue Size"] = 2 })
    user(C.Active, "Boolean", true)
    C.T01Url.String = "http://x/h"
    C.T01Enabled.Boolean = true
    C.T01Mode.String = "On Change"
    for k = 1, 5 do user(C.T01Text, "String", tostring(k)) end
    check("one request in flight at a time", #requests == 1)
    check("queue keeps its size and counts drops", C.Queue.String == "2" and C.Dropped.String == "2",
        C.Queue.String .. "/" .. C.Dropped.String)
    answer(200); answer(200); answer(200)
    check("queue drains newest kept, oldest dropped",
        #requests == 3 and requests[2].args.Data:find('"string":"4"', 1, true) ~= nil
        and requests[3].args.Data:find('"string":"5"', 1, true) ~= nil)
end

do
    local env, C = boot(4, { ["Min Seconds Between Sends"] = 10 })
    user(C.Active, "Boolean", true)
    C.T01Url.String = "http://x/h"
    C.T01Enabled.Boolean = true
    user(C.T01In, "Boolean", true); answer(200)
    clock = 5
    user(C.T01In, "Boolean", false)
    check("Min Seconds Between Sends skips a quick repeat", #requests == 1)
    clock = 11
    user(C.T01In, "Boolean", true)
    check("and allows it after the gap", #requests == 2)
end

do
    local env, C = boot()
    user(C.Active, "Boolean", true)
    C.T01Enabled.Boolean = true
    user(C.T01In, "Boolean", true)
    check("no URL: nothing queued, trigger says so", #requests == 0 and C.T01Last.String:find("no URL") ~= nil)
end

do
    local env, C = boot()
    C.T01Url.String = "http://x/h"
    C.T01Enabled.Boolean = true
    user(C.Active, "Boolean", true)
    user(C.T01In, "Boolean", true)
    user(C.Active, "Boolean", false)
    user(C.T01In, "Boolean", false)
    check("turning Active off stops new requests", #requests == 1)
    check("Mode and Method choices are filled", #C.T01Mode.Choices == 4 and #C.T01Method.Choices == 5)
end

print(string.format("%d passed, %d failed", results.pass, results.fail))
os.exit(results.fail == 0 and 0 or 1)
