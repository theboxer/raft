local path = assert(os.getenv("RAFT_ROOT")) .. "/raft.lua"
local fixture = dofile(os.getenv("RAFT_ROOT") .. "/tests/support.lua")
local opts = {scope='pane', sessions={rex='session', sentinel='tab'}}
local run, blocks, state, reload, locate = fixture('rex', opts)
local a = run('block:a'); assert(a.scope=='session'); assert(blocks[a.block_id].cwd=='/cwd/block:a')
blocks[a.block_id].sentinel = 'shell state'
local b = run('block:b'); assert(a.block_id==b.block_id and blocks[a.block_id].sentinel=='shell state')
assert(locate(a.block_id).window_id=='window:b')
reload(); assert(run(a.block_id).state=='hidden'); assert(state.windows[2].focused_block_id=='block:b')
assert(run('block:a').block_id==a.block_id)
print('PASS session override: cross-tab reuse, state retained, hide from scratch after reload')
run, blocks, state, reload, locate = fixture('sentinel', opts)
a = run('block:a'); b = run('block:a2'); assert(a.scope=='tab' and b.state=='hidden' and a.block_id==b.block_id)
b = run('block:b'); assert(a.block_id~=b.block_id)
assert(run('block:a').block_id==a.block_id)
print('PASS tab override: same shell across panes, separate shells across tabs')
run, blocks, state, reload, locate = fixture('other', opts)
a = run('block:a'); b = run('block:a2'); assert(a.scope=='pane' and a.block_id~=b.block_id)
assert(blocks[a.block_id].placement=='detached')
reload(); assert(run(b.block_id).state=='hidden'); assert(state.windows[1].focused_block_id=='block:a2')
assert(run('block:a').block_id==a.block_id)
print('PASS pane default: separate shells, overlay switching, owner recovered after reload')
run(a.block_id)
state.fail_float=true
local ok = pcall(run, 'block:a'); assert(not ok and blocks[a.block_id].placement=='detached')
state.fail_float=false; assert(run('block:a').block_id==a.block_id)
print('PASS failed reopen: scratch stays alive and detached, retry reuses it')
local options = {scope='tab'}
run, blocks, state, reload, locate = fixture('other', options)
a = run('block:a'); assert(blocks[a.block_id].label=='raft:scratch:window:a')
options.scope='session'; reload(); assert(run(a.block_id).state=='hidden')
b = run('block:a'); assert(a.block_id~=b.block_id and blocks[a.block_id].placement=='detached')
run(b.block_id); options.scope='tab'; reload(); assert(run('block:a').block_id==a.block_id)
print('PASS scope changes: old shells preserved and reused when switching back')
local bad = pcall(function() dofile(path).setup {scope='workspace'} end); assert(not bad)
print('PASS invalid scope rejected')

local options = {scope='pane'}
local run, blocks, state, reload, locate, actions = fixture('sample', options)
blocks['block:b2'] = {block_id='block:b2', creator_name='com.superlogical.terminal', placement='placed', window_id='window:b'}
table.insert(state.windows[2].layers[1].blocks, blocks['block:b2'])
local ids = {}
for _, id in ipairs({'block:a', 'block:a2', 'block:b', 'block:b2'}) do ids[#ids+1] = run(id).block_id end
options.scope='session'; reload()
local ctx = {session_id='session:one', block_id='block:a'}
local listed = actions.raft_list(ctx)
assert(#listed.scratches==4 and listed.configured_scope=='session')
for _, item in ipairs(listed.scratches) do assert(item.scope=='pane' and not item.current_scope) end
-- Simulate the second source pane closing while its scratch survives.
blocks['block:a2'] = nil
table.remove(state.windows[1].layers[1].blocks, 2)
listed = actions.raft_list(ctx)
local orphan
for _, item in ipairs(listed.scratches) do if item.block_id==ids[2] then orphan=item end end
assert(orphan and not orphan.source_exists)
local opened = actions.raft_open(ctx, {block_id=ids[2]})
assert(opened.block_id==ids[2] and opened.owner_id=='block:a2' and opened.scope=='pane')
assert(locate(ids[2]).window_id=='window:a')
assert(actions.raft_open(ctx, {block_id=ids[2]}).state=='visible')
print('PASS manager inventory and recovery: four old pane shells, orphan recovery, explicit open never toggles off')
assert(not pcall(actions.raft_close, ctx, {block_id='block:a'}))
local closed = actions.raft_close(ctx, {block_id=ids[3]})
assert(closed.state=='closed' and not blocks[ids[3]])
assert(#actions.raft_list(ctx).scratches==3)
assert(blocks[ids[1]] and blocks[ids[2]] and blocks[ids[4]] and blocks['block:a'])
assert(not pcall(actions.raft_open, ctx, {block_id=ids[3]}))
assert(not pcall(actions.raft_close, ctx, {block_id=ids[3]}))
print('PASS manager close: only the selected scratch ends; regular panes and stale IDs rejected')
local launched
rex.session.new_layer = function(args) launched=args; return {block_ids={'block:manager'}} end
actions.raft_manage({session_id='session:one', block_id=ids[2]})
local cmd = launched.layout.block.options.command
assert(cmd[1]=='rex' and cmd[2]=='do' and cmd[3]=='-s' and cmd[4]=='session:one')
assert(cmd[5]=='-b' and cmd[6]=='block:a')
assert(cmd[7]=='-e' and loadstring(cmd[8]))
assert(cmd[9]=='return_to='..ids[2])
assert(launched.layout.block.label=='raft:manager' and launched.layout.block.options.exit.on_completion)
blocks['block:manager']={block_id='block:manager', creator_name='com.superlogical.terminal', label='raft:manager', placement='placed', window_id='window:a'}
table.insert(state.windows[1].layers, {kind='floating', blocks={blocks['block:manager']}})
launched=nil
actions.raft_manage({session_id='session:one', block_id='block:a'})
assert(not launched and state.windows[1].focused_block_id=='block:manager')
print('PASS floating manager launch: Lua script, stable source, return focus, repeated shortcut reuses manager')

for _, scope in ipairs({'session','tab','pane'}) do
    local options={scope=scope}
    local run, blocks, state, reload, locate, actions = fixture('slots', options)
    local ctx={session_id='session:one', block_id='block:a2'}
    local ids={}
    for number=1,9 do
        local result=actions.raft_toggle(ctx,{slot=number})
        assert(result.slot==number and result.scope==scope and result.state=='visible')
        ids[number]=result.block_id
        blocks[result.block_id].marker='state-'..number
        if number>1 then assert(blocks[ids[number-1]].placement=='detached') end
        ctx.block_id=result.block_id
    end
    assert(#actions.raft_list(ctx).scratches==9)
    assert(actions.raft_toggle(ctx).slot==9 and blocks[ids[9]].placement=='detached')
    assert(state.windows[1].focused_block_id=='block:a2', 'slot switch lost original source focus')
    ctx.block_id='block:a2'
    local reopened=actions.raft_toggle(ctx,{slot=4})
    assert(reopened.block_id==ids[4] and blocks[ids[4]].marker=='state-4')
    assert(actions.raft_hide(ctx).slot==4 and blocks[ids[4]].placement=='detached')
    assert(#actions.raft_list(ctx).scratches==9)
    local expected_count=9
    local other=actions.raft_toggle({session_id='session:one',block_id='block:b'},{slot=4})
    if scope=='session' then assert(other.block_id==ids[4] and locate(ids[4]).window_id=='window:b')
    else assert(other.block_id~=ids[4]); expected_count=10 end
    reload()
    local back=actions.raft_toggle({session_id='session:one',block_id=other.block_id},{slot=2})
    assert(back.slot==2 and back.scope==scope)
    if scope=='session' then assert(back.block_id==ids[2]) else expected_count=11 end
    local listed=actions.raft_list(ctx).scratches
    assert(#listed==expected_count)
    for _, entry in ipairs(listed) do assert(entry.slot>=1 and entry.slot<=9) end
    assert(actions.raft_close(ctx,{block_id=ids[3]}).slot==3)
    assert(not blocks[ids[3]] and blocks[ids[1]] and blocks[ids[9]])
    local fresh=actions.raft_toggle(ctx,{slot=3})
    assert(fresh.block_id~=ids[3] and fresh.slot==3)
    print('PASS '..scope..' slots: all 9, switch/resume, focus, hide, scope isolation, reload and close/recreate')
end

-- Existing prototype shells in every scope/slot must be reused, not replaced.
for _, scope in ipairs({'session', 'tab', 'pane'}) do
    local options={scope=scope}
    local run,blocks,state,reload,locate,actions=fixture('legacy',options)
    local ctx={session_id='session:one',block_id='block:a'}
    local ids={}
    for slot=1,9 do
        local item=actions.raft_toggle(ctx,{slot=slot})
        ids[slot]=item.block_id
        blocks[item.block_id].label=blocks[item.block_id].label:gsub('^raft:scratch:', 'raft:single-prototype:')
        actions.raft_hide(ctx)
    end
    reload()
    for slot=1,9 do
        assert(actions.raft_toggle(ctx,{slot=slot}).block_id==ids[slot])
    end
    assert(#actions.raft_list(ctx).scratches==9)
    options.scope=scope=='session' and 'tab' or 'session'; reload()
    assert(actions.raft_hide(ctx).block_id==ids[9], 'hide ignored visible old-scope slot')
    for _, bad in ipairs({0,10,-1,1.5,'2',false}) do
        assert(not pcall(actions.raft_toggle,ctx,{slot=bad}))
    end
    assert(#actions.raft_list(ctx).scratches==9, 'invalid requests created shells')
    print('PASS prototype migration: all 9 '..scope..' slots survive reload; invalid slots rejected')
end
