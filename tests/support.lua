-- Simulated Rex session state; never connects to a running server.
local runtime_json = rex.json
local path = assert(os.getenv("RAFT_ROOT")) .. "/raft.lua"
local function copy(t)
    if type(t) ~= 'table' then return t end
    local r = {}; for k, v in pairs(t) do r[k] = copy(v) end; return r
end
local function fixture(name, opts)
    local state = { label = name, session_id = 'session:one', active_window_id = 'window:a', windows = {
        { window_id = 'window:a', focused_block_id = 'block:a', layers = {{ kind = 'tiled', blocks = {} }} },
        { window_id = 'window:b', focused_block_id = 'block:b', layers = {{ kind = 'tiled', blocks = {} }} },
    }}
    local blocks, actions, nextid = {}, {}, 0
    local function locate(id)
        for _, w in ipairs(state.windows) do for li, l in ipairs(w.layers) do
            for bi, b in ipairs(l.blocks) do if b.block_id == id then return w, l, li, bi end end
        end end
    end
    local function add(id, w, label)
        local b = { block_id = id, creator_name = 'com.superlogical.terminal', label = label,
            placement = 'placed', window_id = w.window_id }
        blocks[id] = b; table.insert(w.layers[1].blocks, b); return b
    end
    add('block:a', state.windows[1]); add('block:a2', state.windows[1]); add('block:b', state.windows[2])
    local function detach(id)
        local w, l, li, bi = locate(id)
        if w then table.remove(l.blocks, bi); if #l.blocks == 0 and l.kind == 'floating' then table.remove(w.layers, li) end end
        blocks[id].placement = 'detached'; blocks[id].window_id = nil
    end
    local function focus(id)
        local w = assert(locate(id)); w.focused_block_id = id; state.active_window_id = w.window_id
    end
    local function float(id)
        local w = assert(locate(id)); detach(id)
        local b = blocks[id]; b.placement = 'placed'; b.window_id = w.window_id
        table.insert(w.layers, { kind = 'floating', layer_id = 'layer:' .. id, blocks = {b} })
        return {layer_id = 'layer:' .. id}
    end
    rex = {
        json = runtime_json,
        action = function(a) actions[a.name] = a.run end,
        block = {call = function(_, _, a) return {child = {cwd = '/cwd/' .. a.block_id}} end},
        session = {
            view = function() return copy(state) end,
            list_blocks = function() local b = {}; for _, v in pairs(blocks) do b[#b+1] = copy(v) end; return {blocks = b} end,
            detach_block = function(a) detach(a.block_id); return {} end,
            focus_block = function(a) focus(a.block_id); return {} end,
            move_block = function(a)
                local w = assert(locate(a.anchor_block_id)); detach(a.block_id)
                local b = blocks[a.block_id]; b.placement = 'placed'; b.window_id = w.window_id
                table.insert(w.layers[1].blocks, b); return {}
            end,
            float_block = function(a)
                if state.fail_float then return nil, 'simulated float failure' end
                return float(a.block_id)
            end,
            new_layer = function(a)
                nextid = nextid + 1; local id = 'block:scratch' .. nextid
                local w; for _, candidate in ipairs(state.windows) do if candidate.window_id == a.window_id then w = candidate end end
                local b = add(id, w, a.layout.block.label); b.cwd = a.layout.block.options.cwd
                local f = float(id); if a.focus then focus(id) end
                return {block_ids = {id}, layer_id = f.layer_id}
            end,
        },
    }
    rex.call = function(method, args)
        assert(method == 'block.close')
        assert(blocks[args.block_id], 'gone')
        detach(args.block_id)
        blocks[args.block_id] = nil
        return {}
    end
    local function load() dofile(path).setup(opts) end
    load()
    local function invoke(id, hide) return actions[hide and 'raft_hide' or 'raft_toggle']({session_id='session:one', block_id=id}) end
    return invoke, blocks, state, load, locate, actions
end

return fixture
