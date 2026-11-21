-- Webhook Bridge for Q-SYS
-- Sends an HTTP request when a control changes, so a room event can reach Slack, Teams, Home
-- Assistant, Node-RED, Zapier, a ticketing system or anything else that takes a webhook.
--
-- TRIGGERS: each has a logic input pin (In) and a text input pin (Text). Mode picks what fires it:
--   On Change (either pin), On Rising (In goes true), On Falling (In goes false), Manual (Send only).
-- REQUEST: Method, URL and Body per trigger. A URL that starts with "/" (or is empty) is joined to
--   the Base URL on the Setup page. Body and URL take placeholders:
--   {name} {value} {string} {bool} {trigger} {time} {epoch} {design}
--   In a JSON body (one starting with { or [) placeholders are JSON-escaped; in a URL, URL-encoded.
-- DELIVERY: one request at a time from a queue, a timeout and retries on network errors and 5xx
--   answers. When the queue is full the oldest request is dropped and counted.
-- SCOPE: outbound only. Receiving webhooks (an HTTP listener on the Core) is not in this version.
--
-- INSTALL: double-click webhook-bridge.qplug, or import webhook-bridge.lua (an identical copy) via
--   Tools > Design Resources > Import; then drag Webhook Bridge from the User tree.
--
-- Made by YZ at the SmartSpaces programming department. Provided as-is, without warranty.
-- Copyright (c) 2026 YZ, SmartSpaces. MIT License: see LICENSE, or the plugin's About page.

PluginInfo = {
    Name = "Smart Spaces WI~Webhook Bridge",
    Version = "0.1.0",
    -- No version in the Id, so a new version updates placed copies in place.
    Id = "smartspaces.webhook-bridge",
    Description = "Sends an HTTP request (POST, PUT, PATCH, DELETE or GET) when a control changes, with placeholders for the value, time and design. Queue, timeout and retries. MIT License.",
    Author = "Smart Spaces WI",
    ShowDebug = false,
}

function GetPrettyName()
    return "Webhook Bridge v" .. PluginInfo.Version
end

MAX_TRIGGERS = 16
MODES = { "On Change", "On Rising", "On Falling", "Manual" }
METHODS = { "POST", "PUT", "PATCH", "DELETE", "GET" }
DEFAULT_BODY = '{"trigger":"{name}","value":{value},"string":"{string}","time":"{time}","design":"{design}"}'

TRIGGER_FIELDS = { "Name", "Enabled", "Mode", "Method", "Url", "Body", "Send", "In", "Text", "Ok", "Last" }

function TKey(i, field) return string.format("T%02d%s", i, field) end

TRIGGER_LABELS = { Name = "Name", Enabled = "Enabled", Mode = "Mode", Method = "Method", Url = "URL",
    Body = "Body", Send = "Send", In = "In", Text = "Text In", Ok = "Last OK", Last = "Last Result" }
GLOBAL_LABELS = { Active = "Active", BaseUrl = "Base URL", Headers = "Headers", Token = "Bearer Token",
    Status = "Status", Sent = "Sent", Failed = "Failed", Dropped = "Dropped", Queue = "Queued",
    LastResult = "Last Result", Clear = "Clear Counts" }

function PrettyFor(name)
    local n, f = name:match("^T(%d%d)(%w+)$")
    if n and TRIGGER_LABELS[f] then return "Trigger " .. n .. " " .. TRIGGER_LABELS[f] end
    return GLOBAL_LABELS[name] or name
end

function PropValue(props, name, default)
    local p = props and props[name]
    if p == nil or p.Value == nil then return default end
    return p.Value
end

function GetProperties()
    return {
        { Name = "Trigger Count",            Type = "integer", Min = 1, Max = MAX_TRIGGERS, Value = 4 },
        { Name = "Timeout (seconds)",        Type = "integer", Min = 1, Max = 30, Value = 5 },
        { Name = "Retries",                  Type = "integer", Min = 0, Max = 5, Value = 1 },
        { Name = "Queue Size",               Type = "integer", Min = 1, Max = 100, Value = 20 },
        { Name = "Min Seconds Between Sends", Type = "integer", Min = 0, Max = 3600, Value = 0 },
        { Name = "Log Requests",             Type = "boolean", Value = false },
    }
end

function RectifyProperties(props)
    return props
end

function GetPages(props)
    return { { name = "Triggers" }, { name = "Setup" }, { name = "About" } }
end

function GetControls(props)
    local n = PropValue(props, "Trigger Count", 4)
    local ctls = {
        { Name = "Active",     ControlType = "Button", ButtonType = "Toggle", PinStyle = "Both", UserPin = true },
        { Name = "BaseUrl",    ControlType = "Text" },
        { Name = "Headers",    ControlType = "Text" },
        { Name = "Token",      ControlType = "Text" },
        { Name = "Status",     ControlType = "Indicator", IndicatorType = "Status", PinStyle = "Output", UserPin = true },
        { Name = "Sent",       ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true },
        { Name = "Failed",     ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true },
        { Name = "Dropped",    ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true },
        { Name = "Queue",      ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true },
        { Name = "LastResult", ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true },
        { Name = "Clear",      ControlType = "Button", ButtonType = "Trigger", PinStyle = "Input", UserPin = true },
    }
    for i = 1, n do
        table.insert(ctls, { Name = TKey(i, "Name"),    ControlType = "Text" })
        table.insert(ctls, { Name = TKey(i, "Enabled"), ControlType = "Button", ButtonType = "Toggle", PinStyle = "Both", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "Mode"),    ControlType = "Text" })
        table.insert(ctls, { Name = TKey(i, "Method"),  ControlType = "Text" })
        table.insert(ctls, { Name = TKey(i, "Url"),     ControlType = "Text", PinStyle = "Input", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "Body"),    ControlType = "Text", PinStyle = "Input", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "Send"),    ControlType = "Button", ButtonType = "Trigger", PinStyle = "Input", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "In"),      ControlType = "Button", ButtonType = "Toggle", PinStyle = "Input", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "Text"),    ControlType = "Text", PinStyle = "Input", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "Ok"),      ControlType = "Indicator", IndicatorType = "Led", PinStyle = "Output", UserPin = true })
        table.insert(ctls, { Name = TKey(i, "Last"),    ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true })
    end
    return ctls
end

-- ============================================================================ layout
UI = {
    Panel = { 40, 44, 52 }, Stroke = { 20, 22, 26 }, Title = { 235, 238, 242 }, Dim = { 150, 158, 170 },
    Outline = { 95, 102, 114 }, Readout = { 120, 200, 255 }, Btn = { 0, 120, 212 }, BtnOff = { 70, 76, 88 },
    White = { 255, 255, 255 }, Led = { 60, 200, 90 },
}

local function background(graphics, w, h)
    table.insert(graphics, { Type = "GroupBox", Position = { 0, 0 }, Size = { w, h }, Fill = UI.Panel,
        CornerRadius = 0, StrokeColor = UI.Stroke, StrokeWidth = 1 })
end

local function label(graphics, text, x, y, w, h, opts)
    opts = opts or {}
    table.insert(graphics, { Type = "Label", Text = text, Position = { x, y }, Size = { w, h or 16 },
        Color = opts.color or UI.Dim, FontSize = opts.size or 9, IsBold = opts.bold ~= false,
        HTextAlign = opts.align or "Left" })
end

local function field(layout, graphics, name, x, y, w, h)
    table.insert(graphics, { Type = "GroupBox", Position = { x, y }, Size = { w, h }, CornerRadius = 2,
        StrokeColor = UI.Outline, StrokeWidth = 1 })
    layout[name] = { PrettyName = PrettyFor(name), Style = "Text", Position = { x + 3, y + 1 }, Size = { w - 6, h - 2 },
        FontSize = 10, TextColor = UI.Title, TextBoxStyle = "NoBackground", HTextAlign = "Left", VTextAlign = "Center" }
end

local function combo(layout, name, x, y, w, h)
    layout[name] = { PrettyName = PrettyFor(name), Style = "ComboBox", Position = { x, y }, Size = { w, h },
        FontSize = 10, Color = UI.BtnOff, TextColor = UI.Title }
end

local function readout(layout, name, x, y, w, h)
    layout[name] = { PrettyName = PrettyFor(name), Style = "Text", IsReadOnly = true, Position = { x, y }, Size = { w, h },
        FontSize = 10, TextColor = UI.Readout, TextBoxStyle = "NoBackground", HTextAlign = "Left", VTextAlign = "Center" }
end

local function toggle(layout, name, legend, x, y, w, h)
    layout[name] = { PrettyName = PrettyFor(name), Style = "Button", ButtonStyle = "Toggle", Legend = legend,
        Position = { x, y }, Size = { w, h }, FontSize = 9, IsBold = true, Color = UI.Btn, OffColor = UI.BtnOff,
        UnlinkOffColor = true, TextColor = UI.White }
end

local function button(layout, name, legend, x, y, w, h)
    layout[name] = { PrettyName = PrettyFor(name), Style = "Button", ButtonStyle = "Trigger", Legend = legend,
        Position = { x, y }, Size = { w, h }, FontSize = 9, IsBold = true, Color = UI.Btn, TextColor = UI.White }
end

local function led(layout, name, x, y, s)
    layout[name] = { PrettyName = PrettyFor(name), Style = "Led", Position = { x, y }, Size = { s, s },
        Color = UI.Led, OffColor = UI.BtnOff, UnlinkOffColor = true }
end

-- Triggers page columns: x, width, header.
COLS = {
    { "Num", 8, 22, "#" }, { "Name", 32, 110, "NAME" }, { "Enabled", 146, 36, "ON" },
    { "Mode", 186, 92, "MODE" }, { "Method", 282, 70, "METHOD" }, { "Url", 356, 220, "URL" },
    { "Body", 580, 250, "BODY" }, { "In", 834, 30, "IN" }, { "Text", 868, 70, "TEXT IN" },
    { "Send", 942, 44, "" }, { "Ok", 992, 16, "OK" }, { "Last", 1014, 150, "LAST RESULT" },
}
ROW_H, ROW_GAP, TOP = 20, 4, 44

local function triggersPage(props, layout, graphics)
    local n = PropValue(props, "Trigger Count", 4)
    local w = 1172
    local h = TOP + n * (ROW_H + ROW_GAP) + 10
    background(graphics, w, h)
    label(graphics, "Webhook Bridge - Triggers", 8, 6, w - 16, 20, { color = UI.Title, size = 13, align = "Center" })
    for _, c in ipairs(COLS) do label(graphics, c[4], c[2], 26, c[3], 16) end
    for i = 1, n do
        local y = TOP + (i - 1) * (ROW_H + ROW_GAP)
        local x = {}
        for _, c in ipairs(COLS) do x[c[1]] = c end
        label(graphics, string.format("%d", i), x.Num[2], y + 2, x.Num[3], 16, { color = UI.Title })
        field(layout, graphics, TKey(i, "Name"), x.Name[2], y, x.Name[3], ROW_H)
        toggle(layout, TKey(i, "Enabled"), "ON", x.Enabled[2], y, x.Enabled[3], ROW_H)
        combo(layout, TKey(i, "Mode"), x.Mode[2], y, x.Mode[3], ROW_H)
        combo(layout, TKey(i, "Method"), x.Method[2], y, x.Method[3], ROW_H)
        field(layout, graphics, TKey(i, "Url"), x.Url[2], y, x.Url[3], ROW_H)
        field(layout, graphics, TKey(i, "Body"), x.Body[2], y, x.Body[3], ROW_H)
        toggle(layout, TKey(i, "In"), "", x.In[2], y, x.In[3], ROW_H)
        field(layout, graphics, TKey(i, "Text"), x.Text[2], y, x.Text[3], ROW_H)
        button(layout, TKey(i, "Send"), "SEND", x.Send[2], y, x.Send[3], ROW_H)
        led(layout, TKey(i, "Ok"), x.Ok[2], y + 2, x.Ok[3])
        readout(layout, TKey(i, "Last"), x.Last[2], y, x.Last[3], ROW_H)
    end
end

local function setupPage(props, layout, graphics)
    local w, h = 520, 330
    background(graphics, w, h)
    label(graphics, "Webhook Bridge - Setup", 8, 6, w - 16, 20, { color = UI.Title, size = 13, align = "Center" })
    local y = 36
    label(graphics, "ACTIVE", 12, y + 2, 120)
    toggle(layout, "Active", "ON", 140, y, 60, 22)
    y = y + 32
    label(graphics, "BASE URL", 12, y + 3, 120)
    field(layout, graphics, "BaseUrl", 140, y, 366, 22)
    y = y + 30
    label(graphics, "HEADERS", 12, y + 3, 120)
    field(layout, graphics, "Headers", 140, y, 366, 22)
    label(graphics, "Name: value; Name: value", 140, y + 22, 366, 14, { bold = false, size = 8 })
    y = y + 44
    label(graphics, "BEARER TOKEN", 12, y + 3, 120)
    field(layout, graphics, "Token", 140, y, 366, 22)
    label(graphics, "Stored in the design file. Sent as Authorization: Bearer.", 140, y + 22, 366, 14, { bold = false, size = 8 })
    y = y + 48
    layout["Status"] = { PrettyName = "Status", Style = "Text", Position = { 12, y }, Size = { 494, 24 }, FontSize = 11 }
    y = y + 34
    local stats = { { "Sent", "SENT" }, { "Failed", "FAILED" }, { "Dropped", "DROPPED" }, { "Queue", "QUEUED" } }
    for k, s in ipairs(stats) do
        local x = 12 + (k - 1) * 104
        label(graphics, s[2], x, y, 96)
        readout(layout, s[1], x, y + 16, 96, 20)
    end
    button(layout, "Clear", "CLEAR", 430, y + 14, 76, 22)
    y = y + 46
    label(graphics, "LAST RESULT", 12, y + 3, 120)
    readout(layout, "LastResult", 140, y, 366, 22)
end

local function aboutPage(props, layout, graphics)
    local w, h = 520, 250
    background(graphics, w, h)
    label(graphics, "Webhook Bridge v" .. PluginInfo.Version, 8, 6, w - 16, 20, { color = UI.Title, size = 13, align = "Center" })
    local lines = {
        "Sends an HTTP request when a trigger's input changes.",
        "",
        "Placeholders for URL and Body:",
        "  {name} {value} {string} {bool} {trigger} {time} {epoch} {design}",
        "A JSON body (starting with { or [) gets JSON-escaped values;",
        "a URL gets URL-encoded values.",
        "",
        "Made by YZ at the SmartSpaces programming department.",
        "Copyright (c) 2026 YZ, SmartSpaces. MIT License.",
        "Provided as-is, without warranty of any kind.",
    }
    for k, t in ipairs(lines) do
        label(graphics, t, 16, 34 + (k - 1) * 18, w - 32, 16, { bold = false, size = 10, color = UI.Title })
    end
end

function GetControlLayout(props)
    local layout, graphics = {}, {}
    local page = PropValue(props, "page_index", 1)
    if page == 1 then triggersPage(props, layout, graphics)
    elseif page == 2 then setupPage(props, layout, graphics)
    else aboutPage(props, layout, graphics) end
    return layout, graphics
end

-- ============================================================================ runtime
if Controls then
    NT = Properties["Trigger Count"].Value
    TIMEOUT = Properties["Timeout (seconds)"].Value
    RETRIES = Properties["Retries"].Value
    QUEUE_MAX = Properties["Queue Size"].Value
    MIN_GAP = Properties["Min Seconds Between Sends"].Value
    LOG = Properties["Log Requests"].Value
    RETRY_BASE_S = 2      -- wait 2 s, 4 s, 6 s ... between attempts

    queue = {}            -- pending requests, oldest first
    busy = false
    counts = { sent = 0, failed = 0, dropped = 0 }
    lastSend = {}         -- trigger -> Timer.Now() of its last queued request
    lastIn = {}           -- trigger -> last In state, so rising/falling can be told apart

    local function T(i, field) return Controls[TKey(i, field)] end
    local function now() return Timer.Now() end
    local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    local function log(...) if LOG then print(...) end end

    -- ------------------------------------------------------------ text helpers
    local function jsonEscape(s)
        return (tostring(s):gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
            return map[c] or string.format("\\u%04x", c:byte())
        end))
    end

    local function urlEncode(s)
        return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
    end

    -- A number as JSON accepts it: integers without ".0", NaN and infinities as 0.
    local function number(v)
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
        return string.format("%.6g", v)
    end

    local function designName()
        local ok, st = pcall(function() return Design.GetStatus() end)
        if ok and type(st) == "table" and st.DesignName then return st.DesignName end
        return ""
    end

    -- Fill {placeholders}. `kind` is "json", "url" or "text" and decides the escaping.
    function Expand(template, values, kind)
        return (template:gsub("{(%a+)}", function(key)
            local v = values[key]
            if v == nil then return nil end   -- unknown placeholder: leave it as written
            if key == "value" or key == "trigger" or key == "epoch" then return v end
            if key == "bool" then return v end
            if kind == "json" then return jsonEscape(v) end
            if kind == "url" then return urlEncode(v) end
            return v
        end))
    end

    function JoinUrl(base, url)
        base, url = trim(base), trim(url)
        if url:match("^%a[%w+.-]*://") then return url end
        if base == "" then return url end
        if url == "" then return base end
        if url:sub(1, 1) == "/" then return (base:gsub("/+$", "")) .. url end
        return (base:gsub("/+$", "")) .. "/" .. url
    end

    -- "Name: value; Name: value" -> { Name = value, ... }
    function ParseHeaders(text)
        local h = {}
        for part in (text or ""):gmatch("[^;\n]+") do
            local k, v = part:match("^%s*([^:]-)%s*:%s*(.-)%s*$")
            if k and k ~= "" then h[k] = v end
        end
        return h
    end

    -- ------------------------------------------------------------ status
    local function showCounts()
        Controls.Sent.String = tostring(counts.sent)
        Controls.Failed.String = tostring(counts.failed)
        Controls.Dropped.String = tostring(counts.dropped)
        Controls.Queue.String = tostring(#queue)
    end

    local function setStatus()
        if not Controls.Active.Boolean then
            Controls.Status.Value = 3            -- Not Present: bridge switched off
            Controls.Status.String = "Off: requests are not sent"
        elseif counts.lastFailed then
            Controls.Status.Value = 2            -- Fault
            Controls.Status.String = "Last request failed: " .. (counts.lastError or "")
        elseif #queue > 0 or busy then
            Controls.Status.Value = 0
            Controls.Status.String = string.format("Sending (%d queued)", #queue)
        else
            Controls.Status.Value = 0            -- OK
            Controls.Status.String = "OK"
        end
    end

    local function stamp() return os.date("%H:%M:%S") end

    -- ------------------------------------------------------------ delivery
    local pump

    local function finish(req, ok, text)
        local i = req.trigger
        if ok then counts.sent = counts.sent + 1 else counts.failed = counts.failed + 1 end
        counts.lastFailed = not ok
        counts.lastError = (not ok) and text or nil
        local line = string.format("%s %s", stamp(), text)
        if i then
            T(i, "Ok").Boolean = ok
            T(i, "Last").String = line
        end
        Controls.LastResult.String = (i and ("#" .. i .. " ") or "") .. line
        log("Webhook Bridge:", req.method, req.url, "->", text)
        busy = false
        showCounts()
        setStatus()
        pump()
    end

    local function attempt(req)
        req.attempts = req.attempts + 1
        local args = {
            Url = req.url,
            Headers = req.headers,
            Timeout = TIMEOUT,
            EventHandler = function(_, code, data, err)
                code = tonumber(code) or 0
                if code >= 200 and code < 300 then
                    finish(req, true, tostring(code))
                    return
                end
                local why = code > 0 and tostring(code) or ("no answer" .. (err and err ~= "" and (": " .. tostring(err)) or ""))
                local retryable = code == 0 or code == 429 or code >= 500
                if retryable and req.attempts <= RETRIES then
                    log("Webhook Bridge: retrying", req.url, why)
                    Timer.CallAfter(function() attempt(req) end, RETRY_BASE_S * req.attempts)
                else
                    finish(req, false, why)
                end
            end,
        }
        if req.method == "GET" then
            local get = HttpClient.Get or HttpClient.Download
            get(args)
        else
            args.Method = req.method
            args.Data = req.body
            HttpClient.Upload(args)
        end
    end

    pump = function()
        if busy or #queue == 0 then return end
        if not Controls.Active.Boolean then return end
        busy = true
        local req = table.remove(queue, 1)
        showCounts()
        setStatus()
        attempt(req)
    end

    local function enqueue(req)
        if #queue >= QUEUE_MAX then
            table.remove(queue, 1)
            counts.dropped = counts.dropped + 1
        end
        table.insert(queue, req)
        showCounts()
        pump()
    end

    -- ------------------------------------------------------------ building a request
    local function valuesFor(i)
        local inCtl, textCtl = T(i, "In"), T(i, "Text")
        local s = textCtl.String
        if s == "" then s = inCtl.Boolean and "true" or "false" end
        local num = tonumber(textCtl.String)
        if num == nil then num = inCtl.Boolean and 1 or 0 end
        local name = trim(T(i, "Name").String)
        return {
            name = name ~= "" and name or ("Trigger " .. i),
            value = number(num),
            string = s,
            bool = inCtl.Boolean and "true" or "false",
            trigger = tostring(i),
            time = os.date("%Y-%m-%dT%H:%M:%S"),
            epoch = string.format("%d", os.time()),
            design = designName(),
        }
    end

    function Fire(i, manual)
        if not Controls.Active.Boolean then return false end
        if not manual and not T(i, "Enabled").Boolean then return false end
        if not manual and MIN_GAP > 0 and lastSend[i] and now() - lastSend[i] < MIN_GAP then
            log("Webhook Bridge: trigger", i, "skipped, under Min Seconds Between Sends")
            return false
        end
        local url = JoinUrl(Controls.BaseUrl.String, T(i, "Url").String)
        if url == "" then
            T(i, "Ok").Boolean = false
            T(i, "Last").String = stamp() .. " no URL"
            return false
        end
        local values = valuesFor(i)
        local method = T(i, "Method").String
        if method == "" then method = "POST" end
        local template = T(i, "Body").String
        local isJson = trim(template):match("^[%[{]") ~= nil
        local headers = ParseHeaders(Controls.Headers.String)
        local token = trim(Controls.Token.String)
        if token ~= "" then headers["Authorization"] = "Bearer " .. token end
        local body = ""
        if method ~= "GET" then
            body = Expand(template, values, isJson and "json" or "text")
            if headers["Content-Type"] == nil then
                headers["Content-Type"] = isJson and "application/json" or "text/plain"
            end
        end
        lastSend[i] = now()
        enqueue({ trigger = i, method = method, url = Expand(url, values, "url"), body = body,
            headers = headers, attempts = 0 })
        return true
    end

    -- ------------------------------------------------------------ wiring
    local function mode(i) return T(i, "Mode").String end

    for i = 1, NT do
        T(i, "Mode").Choices = MODES
        T(i, "Method").Choices = METHODS
        if T(i, "Mode").String == "" then T(i, "Mode").String = MODES[1] end
        if T(i, "Method").String == "" then T(i, "Method").String = METHODS[1] end
        if T(i, "Body").String == "" then T(i, "Body").String = DEFAULT_BODY end
        lastIn[i] = T(i, "In").Boolean

        T(i, "In").EventHandler = function(c)
            local was, is = lastIn[i], c.Boolean
            lastIn[i] = is
            local m = mode(i)
            if (m == "On Change" and was ~= is) or (m == "On Rising" and is and not was)
                or (m == "On Falling" and was and not is) then
                Fire(i)
            end
        end
        T(i, "Text").EventHandler = function()
            if mode(i) == "On Change" then Fire(i) end
        end
        T(i, "Send").EventHandler = function() Fire(i, true) end
    end

    Controls.Active.EventHandler = function()
        setStatus()
        pump()
    end
    Controls.Clear.EventHandler = function()
        counts.sent, counts.failed, counts.dropped = 0, 0, 0
        counts.lastFailed, counts.lastError = false, nil
        showCounts()
        setStatus()
    end

    showCounts()
    setStatus()
end
