-- RAFT — Rapid Access Floating Terminal for Rex.
-- Rex owns the shells; labels retain their scope and slot across config reloads.
local M = {}
local terminal = "com.superlogical.terminal"
local prefix = "raft:scratch:"
local legacy_prefix = "raft:single-prototype:"
local config = { scope = "session", sessions = {}, bounds = { 0.1, 0.1, 0.8, 0.8 } }
local scopes = { session = true, tab = true, pane = true }
local return_focus = {}
local source_path = debug.getinfo(1, "S").source:gsub("^@", "")
local directory = assert(source_path:match("^(.*)/[^/]+$"), "RAFT: load using an absolute path")
local manager_label = "raft:manager"

function M.setup(opts)
    opts = opts or {}
    for key in pairs(opts) do
        assert(key == "scope" or key == "sessions" or key == "bounds",
            "RAFT: unknown option " .. tostring(key))
    end
    local scope = opts.scope or "session"
    assert(scopes[scope], "RAFT: scope must be session, tab, or pane")
    local sessions = {}
    assert(opts.sessions == nil or type(opts.sessions) == "table", "RAFT: sessions must be a table")
    for name, value in pairs(opts.sessions or {}) do
        assert(type(name) == "string" and name ~= "" and scopes[value],
            "RAFT: sessions maps exact session names to session, tab, or pane")
        sessions[name] = value
    end
    local bounds = opts.bounds or { 0.1, 0.1, 0.8, 0.8 }
    assert(type(bounds) == "table" and #bounds == 4, "RAFT: bounds must be {x, y, width, height}")
    for _, n in ipairs(bounds) do
        assert(type(n) == "number" and n >= 0 and n <= 1, "RAFT: bounds must be between 0 and 1")
    end
    assert(bounds[3] > 0 and bounds[4] > 0 and bounds[1] + bounds[3] <= 1 and bounds[2] + bounds[4] <= 1,
        "RAFT: bounds must fit inside the tab")
    config = { scope = scope, sessions = sessions, bounds = { unpack(bounds) } }
    return M
end

local function call(method, args)
    return assert(rex.session[method](args))
end

local function slot_label(key, slot)
    -- Slot 1 has no suffix; the original prototype used the same convention.
    return prefix .. key .. (slot == 1 and "" or (":slot:" .. slot))
end

local function owner(block)
    local label = block and block.label or ""
    local matched_prefix
    if label:sub(1, #prefix) == prefix then matched_prefix = prefix
    elseif label:sub(1, #legacy_prefix) == legacy_prefix then matched_prefix = legacy_prefix
    else return end
    local id = label:sub(#matched_prefix + 1)
    local key, number = id:match("^(.-):slot:([1-9])$")
    if id:find(":slot:", 1, true) and not key then return end
    local slot = tonumber(number) or 1
    id = key or id
    local kind = id:match("^(%a+):.+$")
    local scope = ({ session = "session", window = "tab", block = "pane" })[kind]
    if scope then
        assert(block.creator_name == terminal, "RAFT: scratch label belongs to a non-terminal")
        return scope, id, slot
    end
end

local function snapshot(session)
    local view = call("view", { session_id = session })
    local blocks, locations, windows = {}, {}, {}
    for _, block in ipairs(call("list_blocks", { session_id = session }).blocks or {}) do
        blocks[block.block_id] = block
    end
    for _, window in ipairs(view.windows or {}) do
        windows[window.window_id] = window
        for _, layer in ipairs(window.layers or {}) do
            for _, block in ipairs(layer.blocks or {}) do
                locations[block.block_id] = { window = window, layer = layer }
            end
        end
    end
    return view, blocks, locations, windows
end

local function operate(ctx, hide_only, selected_id, requested_slot)
    assert(requested_slot == nil or (type(requested_slot) == "number" and requested_slot >= 1
        and requested_slot <= 9 and requested_slot == math.floor(requested_slot)),
        "RAFT: slot must be an integer from 1 to 9")
    local session = assert(ctx.session_id, "RAFT: run inside a Rex session")
    local view, blocks, locations, windows = snapshot(session)
    local location = ctx.block_id and locations[ctx.block_id]
    local window = ctx.block_id and location and location.window
        or (not ctx.block_id and windows[view.active_window_id])
    assert(window, "RAFT: source terminal must belong to a tab")
    local current = ctx.block_id or window.focused_block_id

    local function anchor_in(target_window, preferred)
        local first
        for _, layer in ipairs(target_window.layers or {}) do
            if layer.kind == "tiled" then
                for _, block in ipairs(layer.blocks or {}) do
                    if not owner(blocks[block.block_id]) and (blocks[block.block_id] or {}).label ~= manager_label then
                        first = first or block.block_id
                        if block.block_id == preferred then return block.block_id end
                    end
                end
            end
        end
        return first
    end

    -- Inside a scratch, its label wins even after a config reload/scope change.
    -- This also recovers the source pane without an in-memory ownership map.
    local scope, key, current_slot = owner(blocks[current])
    local from_scratch = scope ~= nil
    local slot = requested_slot or current_slot or 1
    local anchor
    if selected_id then
        scope, key, slot = owner(blocks[selected_id])
        assert(scope, "RAFT: selected scratch no longer exists")
        anchor = anchor_in(window, from_scratch and return_focus[slot_label(key, slot)] or current)
    elseif from_scratch then
        anchor = anchor_in(window, scope == "pane" and key or return_focus[slot_label(key, current_slot)])
    else
        scope = config.sessions[view.label or ""] or config.scope
        anchor = anchor_in(window, current)
        if scope == "session" then key = session
        elseif scope == "tab" then key = window.window_id
        else key = anchor end
    end
    -- An unqualified Hide from underneath a float hides whichever slot is up,
    -- including a recovered terminal from an old scope. It never creates one.
    if hide_only and not from_scratch and requested_slot == nil then
        local visible
        for id, placed in pairs(locations) do
            if placed.window == window and placed.layer.kind == "floating" and owner(blocks[id]) then
                assert(not visible, "RAFT: multiple scratch floats; hide from inside the one you want")
                visible = id
            end
        end
        if not visible then return { state = "hidden" } end
        scope, key, slot = owner(blocks[visible])
    end
    assert(key, "RAFT: keep a tiled source pane open")
    local label = slot_label(key, slot)
    local scratch = selected_id and blocks[selected_id]
    if not selected_id then
        for _, block in pairs(blocks) do
            local block_scope, block_owner, block_slot = owner(block)
            if block_scope == scope and block_owner == key and block_slot == slot then
                assert(not scratch, "RAFT: duplicate scratch labels")
                scratch = block
            end
        end
    end
    local placement = scratch and locations[scratch.block_id]
    if scratch and scratch.placement == "placed" then
        assert(placement, "RAFT: scratch placement changed; retry")
    end
    local function check_detach(block)
        local placed = locations[block.block_id]
        if not placed then return end
        assert(placed.layer.kind == "tiled" or #placed.layer.blocks == 1,
            "RAFT: move extra panes out of the scratch float first")
        assert(anchor_in(placed.window), "RAFT: keep a tiled source pane beneath the scratch")
    end
    local function detach(block)
        call("detach_block", { session_id = session, block_id = block.block_id })
        locations[block.block_id] = nil
    end
    local function result(state, block_id, layer_id)
        return { state = state, scope = scope, owner_id = key, slot = slot, block_id = block_id, layer_id = layer_id }
    end

    if selected_id and placement and placement.window == window and placement.layer.kind == "floating" then
        call("focus_block", { session_id = session, block_id = scratch.block_id })
        return result("visible", scratch.block_id, placement.layer.layer_id)
    end

    if hide_only or (placement and placement.window == window and placement.layer.kind == "floating") then
        if placement then
            check_detach(scratch)
            detach(scratch)
            if placement.window == window then
                call("focus_block", { session_id = session, block_id = assert(anchor) })
            end
        end
        return result("hidden", scratch and scratch.block_id)
    end

    assert(anchor, "RAFT: keep a tiled source pane open")
    if placement then check_detach(scratch) end
    -- Only one scratch overlay is visible in a tab. Switching slots or source
    -- panes hides the previous scratch without ending its shell.
    local others = {}
    for id, placed in pairs(locations) do
        if placed.window == window and placed.layer.kind == "floating"
            and owner(blocks[id]) and (not scratch or id ~= scratch.block_id) then
            check_detach(blocks[id])
            others[#others + 1] = blocks[id]
        end
    end
    for _, block in ipairs(others) do detach(block) end
    return_focus[label] = anchor

    if scratch then
        -- Session-scoped shells travel to the invoking tab on demand. Pane-
        -- scoped shells can likewise follow their source pane to another tab.
        if placement and placement.window ~= window then
            detach(scratch)
            placement = nil
        end
        local was_hidden = not placement
        if was_hidden then
            call("move_block", {
                session_id = session, block_id = scratch.block_id, anchor_block_id = anchor,
            })
        end
        local floated, err = rex.session.float_block {
            session_id = session, block_id = scratch.block_id, bounds = config.bounds,
        }
        if not floated then
            local rollback_err
            if was_hidden then
                local ignored
                ignored, rollback_err = rex.session.detach_block {
                    session_id = session, block_id = scratch.block_id,
                }
            end
            error(tostring(err) .. (rollback_err and ("; detach: " .. rollback_err) or ""))
        end
        call("focus_block", { session_id = session, block_id = scratch.block_id })
        return result("visible", scratch.block_id, floated.layer_id)
    end

    local options = {}
    local process = rex.block.call(terminal, "process", { session_id = session, block_id = anchor })
    if process then
        options.cwd = (process.foreground and process.foreground.cwd)
            or (process.child and process.child.cwd)
    end
    local created = call("new_layer", {
        session_id = session, window_id = window.window_id, bounds = config.bounds, focus = true,
        layout = { block = {
            flavor = terminal .. ".shell", label = label, options = options,
        } },
    })
    return result("visible", created.block_ids[1], created.layer_id)
end

local function list_scratch(ctx)
    local session = assert(ctx.session_id, "RAFT: run inside a Rex session")
    local view, blocks, locations, windows = snapshot(session)
    local configured_scope = config.sessions[view.label or ""] or config.scope
    local entries = {}
    local function name(value, fallback)
        return value and value ~= "" and value or fallback
    end
    for id, block in pairs(blocks) do
        local scope, key, slot = owner(block)
        if scope then
            local source, exists
            if scope == "session" then
                source, exists = name(view.label, session), key == session
            elseif scope == "tab" then
                exists = windows[key] ~= nil
                source = exists and name(windows[key].label, key) or ("closed tab " .. key)
            else
                exists = blocks[key] ~= nil
                source = exists and name(blocks[key].label, key) or ("closed pane " .. key)
                if exists then
                    local title = rex.block.call(terminal, "title", { session_id = session, block_id = key })
                    if title then source = name(title.title, source) end
                end
            end
            local title = rex.block.call(terminal, "title", { session_id = session, block_id = id })
            local process = rex.block.call(terminal, "process", { session_id = session, block_id = id })
            local program = process and (process.foreground or process.child)
            local placed = locations[id]
            entries[#entries + 1] = {
                block_id = id, scope = scope, owner_id = key, slot = slot, source = source, source_exists = exists,
                title = name(title and title.title, id), process = program and program.name,
                cwd = program and program.cwd, current_scope = scope == configured_scope,
                placement = placed and (placed.layer.kind == "floating" and "floating" or "docked") or "hidden",
                window_id = placed and placed.window.window_id,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.scope ~= b.scope then return a.scope < b.scope end
        if a.source ~= b.source then return a.source < b.source end
        if a.owner_id ~= b.owner_id then return a.owner_id < b.owner_id end
        if a.slot ~= b.slot then return a.slot < b.slot end
        return a.block_id < b.block_id
    end)
    return { session_id = session, session_label = view.label, configured_scope = configured_scope, scratches = entries }
end

local function close_scratch(ctx, id)
    local session = assert(ctx.session_id, "RAFT: run inside a Rex session")
    local _, blocks = snapshot(session)
    local scope, key, slot = owner(blocks[id])
    assert(scope, "RAFT: selected scratch no longer exists")
    assert(rex.call("block.close", { session_id = session, block_id = id }))
    return_focus[slot_label(key, slot)] = nil
    return { state = "closed", block_id = id, scope = scope, owner_id = key, slot = slot }
end

local function manage_scratch(ctx)
    local session = assert(ctx.session_id, "RAFT: run inside a Rex session")
    local view, blocks, locations, windows = snapshot(session)
    local placed = ctx.block_id and locations[ctx.block_id]
    local window = placed and placed.window or (not ctx.block_id and windows[view.active_window_id])
    assert(window, "RAFT: open the manager from a tab")
    local current = ctx.block_id or window.focused_block_id
    local origin
    for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
            if block.label == manager_label then
                return call("focus_block", { session_id = session, block_id = block.block_id })
            end
            if layer.kind == "tiled" and not owner(blocks[block.block_id]) and block.label ~= manager_label then
                if not origin or block.block_id == current then origin = block.block_id end
            end
        end
    end
    assert(origin, "RAFT: keep a regular tiled pane beneath the manager")
    -- The terminal runs on the target server, which may not have these files
    -- or our init.lua actions. Send the Lua code and effective config together.
    local function read(path)
        local file = assert(io.open(path, "r"))
        local content = file:read("*a")
        file:close()
        return assert(content)
    end
    local payload = string.format("local raft = assert(loadstring(%q, %q))()\nraft.setup(assert(rex.json.decode(%q)))\n",
        read(source_path), "@" .. source_path, assert(rex.json.encode(config)))
        .. read(directory .. "/raft/manager.lua")
    return call("new_layer", {
        session_id = session, window_id = window.window_id,
        bounds = { 0.05, 0.06, 0.9, 0.88 }, focus = true,
        layout = { block = {
            flavor = terminal .. ".shell", label = manager_label,
            options = {
                shell = "none",
                command = { "rex", "do", "-s", session, "-b", origin,
                    "-e", payload, "return_to=" .. (current or origin) },
                exit = { on_completion = true },
            },
        } },
    })
end

rex.action {
    name = "raft_toggle", title = "RAFT: Toggle scratch terminal", category = "RAFT",
    args = { slot = "integer?" },
    run = function(ctx, args) return operate(ctx, false, nil, (args or {}).slot) end,
}
rex.action {
    name = "raft_hide", title = "RAFT: Hide scratch terminal", category = "RAFT",
    args = { slot = "integer?" },
    run = function(ctx, args) return operate(ctx, true, nil, (args or {}).slot) end,
}
rex.action {
    name = "raft_list", title = "RAFT: List all scratch terminals", category = "RAFT",
    run = function(ctx) return list_scratch(ctx) end,
}
rex.action {
    name = "raft_open", title = "RAFT: Open scratch by ID", category = "RAFT",
    args = { block_id = "string" },
    run = function(ctx, args) return operate(ctx, false, args.block_id) end,
}
rex.action {
    name = "raft_close", title = "RAFT: Close scratch by ID", category = "RAFT",
    args = { block_id = "string" },
    run = function(ctx, args) return close_scratch(ctx, args.block_id) end,
}
rex.action {
    name = "raft_manage", title = "RAFT: Manage scratch terminals…", category = "RAFT",
    run = manage_scratch,
}

return M
