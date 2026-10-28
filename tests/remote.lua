local runtime_json = rex.json
local fixture = dofile(assert(os.getenv("RAFT_ROOT")) .. "/tests/support.lua")
local run, blocks, state, reload, locate, actions = fixture('remote', {scope='tab', sessions={remote='session'}})
local ctx={session_id='session:one',block_id='block:a'}
local ids={}
for slot=1,3 do ids[slot]=actions.raft_toggle(ctx,{slot=slot}).block_id end
actions.raft_open(ctx,{block_id=ids[2]})
local launched
rex.session.new_layer = function(args) launched=args; return {block_ids={'block:manager'}} end
actions.raft_manage({session_id='session:one', block_id=ids[2]})
local cmd = launched.layout.block.options.command
assert(cmd[1]=='rex' and cmd[2]=='do')
assert(cmd[4]=='session:one' and cmd[6]=='block:a')
-- The remote Rex CLI has no files from the Mac's config directory.
if cmd[7] ~= '-e' then
    error('Error: reading script: open ' .. cmd[7] .. ': no such file or directory', 0)
end
assert(loadstring(cmd[8]), 'inline manager must be valid Lua')
print('PASS remote launch requires no Mac filesystem paths')

local original_open, original_write, original_flush, original_read = io.open, io.write, io.flush, io.read
local api = rex
local original_focus = api.session.focus_block
api.session.focus_block = function(args)
    if not locate(args.block_id) then return nil, 'block not found' end
    return original_focus(args)
end
for _, scenario in ipairs({
    {flag='-F', keys='q'}, {flag='-f', keys='q'},
    {flag='-F', keys='\r'}, {flag='-F', keys='xyq'},
}) do
    local registry, operations, display, tty_calls = {}, {}, {}, {}
    local index, raw, restored = 0, false, false
    rex = {session=api.session, block=api.block, call=api.call, json=runtime_json,
        session_id=cmd[4], block_id=cmd[6], args={return_to=ids[2]}}
    rex.action=function(action) registry[action.name]=action.run end
    rex.invoke=function(name, args)
        operations[#operations+1]=name
        assert(registry[name], 'manager depends on actions in remote init.lua: '..name)
        return registry[name]({session_id=cmd[4], block_id=cmd[6]}, args)
    end
    rex.exec=function(argv)
        assert(argv[1]=='stty' and argv[3]=='/dev/tty')
        tty_calls[#tty_calls+1]=argv[2]..':'..argv[4]
        if argv[2]~=scenario.flag then return {ok=false, stderr='stty: invalid option'} end
        if argv[4]=='-g' then return {ok=true, stdout='saved-settings'} end
        if argv[4]=='size' then return {ok=true, stdout='26 100'} end
        if argv[4]=='raw' then raw=true; return {ok=true} end
        assert(argv[4]=='saved-settings'); raw=false; restored=true; return {ok=true}
    end
    io.open=function(path)
        assert(path=='/dev/tty', 'remote manager tried to read Mac file: '..path)
        return {setvbuf=function() end, close=function() end, read=function(_, n)
            index=index+1
            assert(index<=#scenario.keys, 'manager did not handle scripted keys')
            return scenario.keys:sub(index,index)
        end}
    end
    io.write=function(...) for _,value in ipairs({...}) do display[#display+1]=value end end
    io.flush=function() end
    io.read=function() error('manager failed: '..table.concat(display)) end
    assert(loadstring(cmd[8]))()
    io.open, io.write, io.flush, io.read = original_open, original_write, original_flush, original_read
    assert(not raw and restored, 'TTY not restored')
    local screen=table.concat(display)
    assert(screen:find('Scratch terminals',1,true), 'manager did not render')
    assert(screen:find('current scope: session',1,true), 'local config was lost')
    assert(not screen:find('Cannot refresh:',1,true), 'remote listing failed')
    assert(not screen:find('Cannot open:',1,true), 'remote opening failed')
    assert(not screen:find('Cannot close:',1,true), 'remote closing failed')
    if scenario.keys=='\r' then assert(operations[2]=='raft_open') end
    if scenario.keys=='xyq' then assert(operations[2]=='raft_close' and operations[3]=='raft_list') end
    print('PASS inline remote manager '..scenario.flag..': '..table.concat(operations, ', ')..'; TTY restored; no installed files/actions')
end
