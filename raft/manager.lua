-- Run in its own Rex terminal: rex do -s SESSION -b SOURCE this-file.lua.
-- All UI/input is Lua; BSD/GNU stty supplies raw mode and terminal dimensions.
local session = assert(rex.session_id, "Run the manager inside Rex")
local source = assert(rex.block_id, "The manager needs a source pane")
local return_to = (rex.args or {}).return_to or source
local terminal = "com.superlogical.terminal"
local esc = string.char(27)
local palette = {
    base = esc .. "[0;38;2;205;214;244;48;2;30;30;46m",
    muted = esc .. "[38;2;147;153;178m",
    accent = esc .. "[1;38;2;137;220;235m",
    selected = esc .. "[1;38;2;205;214;244;48;2;49;50;68m",
    warning = esc .. "[1;38;2;250;179;135m",
}
local entries, filtered, preview = {}, {}, {}
local selected, offset, query, mode = 1, 0, "", "browse"
local session_name, configured_scope, message = session, "?", ""
local rows, columns = 24, 80
local screen, dirty, opened = false, true, false
local saved_tty, confirming
local tty_flag

local function stty(...)
    -- BSD/macOS uses -f; GNU/Linux uses -F. Probe read-only before raw mode
    -- and reuse the successful form for sizing and restoration too.
    if not tty_flag then
        local failures = {}
        for _, flag in ipairs({ "-f", "-F" }) do
            local result, err = rex.exec({ "stty", flag, "/dev/tty", "-g" })
            if result and result.ok then tty_flag = flag; break end
            failures[#failures + 1] = err or (result and result.stderr) or "stty failed"
        end
        assert(tty_flag, "Cannot access terminal: " .. table.concat(failures, "; "))
    end
    local argv = { "stty", tty_flag, "/dev/tty" }
    for _, value in ipairs({...}) do argv[#argv + 1] = value end
    local result, err = rex.exec(argv)
    assert(result, err)
    assert(result.ok, result.stderr or "Cannot configure terminal")
    return (result.stdout or ""):gsub("%s+$", "")
end

local function clean(value)
    -- Never render terminal titles or captured output as control sequences.
    return tostring(value or ""):gsub(esc .. "%][^\7]*\7", "")
        :gsub(esc .. "%[[0-?]*[ -/]*[@-~]", ""):gsub("[%z\1-\31\127]", " ")
end

local function glyph(text, i)
    local a, b, c, d = text:byte(i, i + 3)
    local length, code = 1, a
    local function continuation(n) return n and n >= 128 and n < 192 end
    if a >= 194 and a < 224 and continuation(b) then length, code = 2, (a - 192) * 64 + b - 128
    elseif a >= 224 and a < 240 and continuation(b) and continuation(c) then
        length, code = 3, (a - 224) * 4096 + (b - 128) * 64 + c - 128
    elseif a >= 240 and a < 245 and continuation(b) and continuation(c) and continuation(d) then
        length, code = 4, (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
    elseif a >= 128 then return "?", 1, 1 end
    local width = 1
    if (code >= 0x300 and code <= 0x36f) or code == 0x200d or (code >= 0xfe00 and code <= 0xfe0f) then width = 0
    elseif code >= 0x1100 and (code <= 0x115f or (code >= 0x2e80 and code <= 0xa4cf)
        or (code >= 0xac00 and code <= 0xd7a3) or (code >= 0xf900 and code <= 0xfaff)
        or (code >= 0xfe10 and code <= 0xfe6f) or (code >= 0xff00 and code <= 0xff60)
        or (code >= 0xffe0 and code <= 0xffe6) or code >= 0x1f000) then width = 2 end
    if code >= 128 and code <= 159 then return " ", length, 1 end
    return text:sub(i, i + length - 1), length, width
end

local function fit(value, width)
    local text, out, used, i = clean(value), {}, 0, 1
    while i <= #text do
        local char, length, cells = glyph(text, i)
        if used + cells > width then break end
        out[#out + 1], used, i = char, used + cells, i + length
    end
    return table.concat(out) .. string.rep(" ", math.max(0, width - used))
end

local function current() return filtered[selected] end

local function refilter(keep)
    filtered = {}
    for _, entry in ipairs(entries) do
        local haystack = table.concat({"slot " .. tostring(entry.slot or 1), entry.scope or "", entry.source or "", entry.title or "",
            entry.process or "", entry.cwd or "", entry.block_id or "", entry.placement or ""}, " "):lower()
        if haystack:find(query:lower(), 1, true) then filtered[#filtered + 1] = entry end
    end
    selected = math.max(1, math.min(selected, #filtered))
    if keep then
        for i, entry in ipairs(filtered) do if entry.block_id == keep then selected = i; break end end
    end
    dirty = true
end

local function refresh_preview()
    preview = {}
    local entry = current()
    if not entry then return end
    local result, err = rex.block.call(terminal, "format", {
        session_id = session, block_id = entry.block_id, format = "text", trim = true,
    })
    if not result then preview = { "Preview unavailable: " .. clean(err) }; return end
    -- Keep only a short tail in the UI. Preview is fetched on selection or R.
    local content = result.content or ""
    local tail = content:sub(-64000):gsub("\r\n", "\n"):gsub("\n+$", "")
    for line in (tail .. "\n"):gmatch("(.-)\n") do preview[#preview + 1] = clean(line) end
    dirty = true
end

local function refresh()
    local keep = current() and current().block_id
    local result, err = rex.invoke("raft_list")
    if not result then message = "Cannot refresh: " .. clean(err); dirty = true; return end
    entries = result.scratches or {}
    session_name = result.session_label or session
    configured_scope = result.configured_scope or "?"
    refilter(keep)
    refresh_preview()
end

local function dimensions()
    local size = stty("size")
    local height, width = size:match("(%d+)%s+(%d+)")
    height, width = tonumber(height), tonumber(width)
    if height and width and height > 0 and width > 0 and (height ~= rows or width ~= columns) then
        rows, columns, dirty = height, width, true
    end
end

local function draw()
    local lines = {}
    local function line(y, text, style)
        lines[#lines + 1] = esc .. "[" .. y .. ";1H" .. palette.base .. (style or "") .. fit(text, columns)
    end
    lines[#lines + 1] = palette.base
    if rows < 16 or columns < 58 then
        lines[#lines + 1] = esc .. "[2J"
        line(1, " RAFT: enlarge the pane (58 columns x 16 rows).", palette.accent)
        line(2, " Esc / q: close manager", palette.muted)
    else
        local slots = math.max(3, math.floor((rows - 10) * 0.45))
        if selected <= offset then offset = selected - 1 end
        if selected > offset + slots then offset = selected - slots end
        offset = math.max(0, math.min(offset, math.max(0, #filtered - slots)))
        local slot_width, scope_width, state_width = 5, 9, 13
        local source_width = math.floor((columns - slot_width - scope_width - state_width - 4) * 0.43)
        local title_width = columns - 4 - slot_width - scope_width - state_width - source_width
        line(1, " RAFT  /  Scratch terminals", palette.accent)
        line(2, " " .. session_name .. "   |   current scope: " .. configured_scope ..
            "   |   " .. #filtered .. "/" .. #entries .. " terminals", palette.muted)
        line(3, " " .. (mode == "search" and "Search> " or "/ Search: ") .. query)
        line(4, "   " .. fit("SLOT", slot_width) .. fit("SCOPE", scope_width) .. fit("SOURCE", source_width) ..
            fit("PROGRAM / TITLE", title_width) .. "STATE", palette.muted)
        for slot = 1, slots do
            local index = offset + slot
            local entry = filtered[index]
            local text = ""
            if entry then
                local scope = entry.scope .. (entry.current_scope and "" or " *")
                local source_name = entry.source_exists and entry.source or "[source closed]"
                text = (index == selected and " > " or "   ") .. fit("[" .. (entry.slot or 1) .. "]", slot_width) .. fit(scope, scope_width) ..
                    fit(source_name, source_width) .. fit(entry.process or entry.title, title_width) .. entry.placement
            elseif #filtered == 0 and slot == 1 then
                text = #entries == 0 and "   No scratch terminals yet." or "   No matches. Press / to edit the search."
            end
            line(4 + slot, text, index == selected and entry and palette.selected or nil)
        end
        local divider = 5 + slots
        line(divider, " " .. string.rep("-", columns - 2), palette.muted)
        local entry = current()
        line(divider + 1, " " .. (entry and ("Slot " .. (entry.slot or 1) .. " / " .. entry.title) or "Terminal preview"), palette.accent)
        line(divider + 2, " " .. (entry and (entry.cwd or "Directory unavailable") or ""), palette.muted)
        local available = rows - 3 - (divider + 2)
        for i = 1, available do
            line(divider + 2 + i, " " .. (preview[math.max(0, #preview - available) + i] or ""))
        end
        if mode == "confirm" then
            line(rows - 2, " Close slot " .. (confirming.slot or 1) .. " / " .. (confirming.title or confirming.block_id) ..
                "? Running work will end.", palette.warning)
            line(rows - 1, " Y: close this terminal    N / Esc: cancel", palette.warning)
        else
            line(rows - 2, " " .. (message ~= "" and message or "* other scope; these shells are still available"),
                message ~= "" and palette.warning or palette.muted)
            line(rows - 1, mode == "search" and " Type to filter   Enter: finish search   Esc: back   Ctrl+U: clear" or
                " Up/Down j/k: select   Enter: open   X: close   /: search")
        end
        line(rows, " R: refresh   Esc / q: close manager", palette.muted)
    end
    io.write(table.concat(lines), palette.base, esc .. "[?25l")
    io.flush()
    dirty = false
end

local function read_key()
    -- Reopen after each read: VMIN=0 timeout is EOF to Lua's stdio wrapper.
    -- A fresh handle clears that EOF without requiring a C/FFI dependency.
    local input = assert(io.open("/dev/tty", "r"))
    input:setvbuf("no")
    local key = input:read(1)
    if key == esc then
        local next_byte = input:read(1)
        if next_byte == "[" or next_byte == "O" then
            local sequence = next_byte
            for _ = 1, 12 do
                local char = input:read(1)
                if not char then break end
                sequence = sequence .. char
                if char:match("[@-~]") then break end
            end
            key = ({["[A"]="up", ["OA"]="up", ["[B"]="down", ["OB"]="down",
                ["[H"]="home", ["OH"]="home", ["[F"]="end", ["OF"]="end",
                ["[5~"]="pageup", ["[6~"]="pagedown"})[sequence] or "ignored"
        elseif next_byte then key = "ignored" end
    elseif key and key:byte() >= 194 then
        local length = key:byte() < 224 and 2 or (key:byte() < 240 and 3 or 4)
        key = key .. (input:read(length - 1) or "")
    end
    input:close()
    return key
end

local function main()
    saved_tty = stty("-g")
    stty("raw", "-echo", "min", "0", "time", "1")
    io.write(esc .. "[?1049h", esc .. "[?7l", esc .. "[?25l", palette.base, esc .. "[2J")
    io.flush()
    screen = true
    dimensions()
    refresh()
    local ticks = 0
    while true do
        if dirty then draw() end
        local key = read_key()
        ticks = ticks + 1
        if ticks >= 5 then dimensions(); ticks = 0 end
        if key == "\3" or key == "\4" then break end
        if key then
            if mode == "confirm" then
                if key == "y" or key == "Y" then
                    local result, err = rex.invoke("raft_close", { block_id = confirming.block_id })
                    mode, message = "browse", result and "Terminal closed." or ("Cannot close: " .. clean(err))
                    confirming = nil
                    refresh()
                elseif key == "n" or key == "N" or key == esc or key == "\r" then
                    mode, confirming = "browse", nil
                end
            elseif mode == "search" then
                if key == esc or key == "\r" or key == "\n" then mode = "browse"
                elseif key == "\21" then query = ""
                elseif key == "\127" or key == "\8" then query = query:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
                elseif (#key == 1 or key:byte() >= 194) and key:byte() >= 32 and #query < 200 then query = query .. key end
                refilter(); refresh_preview()
            elseif key == esc or key == "q" then break
            elseif key == "/" then mode = "search"
            elseif key == "r" or key == "R" then message = ""; refresh()
            elseif (key == "x" or key == "X") and current() then
                confirming, mode = current(), "confirm"
            elseif (key == "\r" or key == "\n") and current() then
                local result, err = rex.invoke("raft_open", { block_id = current().block_id })
                if result then opened = true; break end
                message = "Cannot open: " .. clean(err)
                refresh()
            else
                local before = selected
                if key == "j" or key == "down" then selected = selected + 1
                elseif key == "k" or key == "up" then selected = selected - 1
                elseif key == "g" or key == "home" then selected = 1
                elseif key == "G" or key == "end" then selected = #filtered
                elseif key == "pageup" then selected = selected - 5
                elseif key == "pagedown" then selected = selected + 5 end
                selected = math.max(1, math.min(selected, #filtered))
                if before ~= selected then message = ""; refresh_preview() end
            end
            dirty = true
        end
    end
end

local ok, err = xpcall(main, function(problem) return tostring(problem) end)
if screen then io.write(esc .. "[0m", esc .. "[?7h", esc .. "[?25h", esc .. "[?1049l"); io.flush() end
if saved_tty then pcall(stty, saved_tty) end
if not ok then
    io.write("RAFT manager: ", clean(err), "\nPress Enter to close.\n")
    io.flush()
    io.read("*l")
end
if not opened then
    local focused = rex.session.focus_block { session_id = session, block_id = return_to }
    if not focused then rex.session.focus_block { session_id = session, block_id = source } end
end
