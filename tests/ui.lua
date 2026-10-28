local items = {
    {block_id='block:a', slot=1, scope='pane', source='editor', source_exists=true, title='npm run dev', process='node', cwd='~/Sites/sentinel', placement='hidden', current_scope=false},
    {block_id='block:b', slot=3, scope='pane', source='closed pane block:gone', source_exists=false, title='pytest -x', process='pytest', cwd='~/Sites/sentinel', placement='hidden', current_scope=false},
    {block_id='block:c', slot=2, scope='session', source='rex', source_exists=true, title='zsh', process='zsh', cwd='~/.config/rex', placement='floating', current_scope=true},
    {block_id='block:d', slot=9, scope='tab', source='日本語 é', source_exists=true, title='unicode fixture', process='zsh', cwd='/tmp', placement='hidden', current_scope=false},
}
local operations = {}
rex.session_id = 'session:demo'
rex.block_id = 'block:source'
rex.args = { return_to='block:original' }
rex.invoke = function(action, args)
    operations[#operations+1] = action .. (args and (':' .. args.block_id) or '')
    if action == 'raft_list' then
        return { session_label='rex (simulated)', configured_scope='session', scratches=items }
    elseif action == 'raft_close' then
        for i, item in ipairs(items) do if item.block_id==args.block_id then table.remove(items,i); return {} end end
        return nil, 'terminal gone'
    elseif action == 'raft_open' then return {} end
    error(action)
end
rex.block.call = function(_, method, args)
    assert(method=='format' and args.format=='text')
    return { content='> ' .. args.block_id .. '\nStarting development server...\nReady on http://localhost:3000\n\n12:02:10 GET / 200\n12:02:14 GET /api/status 200\n\nWaiting for file changes.\n' }
end
rex.session.focus_block = function(args) operations[#operations+1]='focus:'..args.block_id; return {} end

local real_open = io.open
local scenarios = {
    search={keys='/slot 3\r\r', expected='raft_list, raft_open:block:b'},
    cancel={keys='xnq', expected='raft_list, focus:block:original'},
    close={keys='xyq', expected='raft_list, raft_close:block:a, raft_list, focus:block:original'},
    unicode={keys='/日本語\r\r', expected='raft_list, raft_open:block:d'},
    escape={keys=string.char(27), expected='raft_list, focus:block:original'},
}
local scenario = assert(scenarios[os.getenv('RAFT_TEST_CASE')])
local position, timeouts = 1, 0
local function read(n)
    if position > #scenario.keys then
        timeouts = timeouts + 1
        assert(timeouts <= 1, 'UI exhausted its keys without exiting')
        return nil
    end
    local value = scenario.keys:sub(position, position + n - 1)
    position = position + #value
    return value
end
local close_called = false
local raw = false
local display = {}
io.write = function(...)
    for _, value in ipairs({...}) do display[#display+1] = tostring(value) end
end
io.flush = function() end
io.open = function(path, mode)
    if path == '/dev/tty' then
        return {
            setvbuf=function() end,
            read=function(_, n)
                return read(n)
            end,
            close=function() end,
        }
    end
    return real_open(path, mode)
end
rex.exec = function(argv)
    assert(argv[1]=='stty' and argv[2]=='-f' and argv[3]=='/dev/tty')
    if argv[4]=='-g' then return {ok=true, stdout='saved-settings'} end
    if argv[4]=='size' then return {ok=true, stdout='26 100'} end
    if argv[4]=='raw' then raw=true; return {ok=true, stdout=''} end
    assert(argv[4]=='saved-settings'); close_called=true; raw=false
    return {ok=true, stdout=''}
end
io.read = function() error('UI entered its error handler: '..table.concat(display)) end
dofile(assert(os.getenv('RAFT_ROOT')) .. '/raft/manager.lua')
assert(not raw and close_called, 'terminal cleanup skipped')
assert(table.concat(display):find('Scratch terminals',1,true), 'UI was not rendered')
assert(table.concat(display):find('Ready on http://localhost:3000',1,true), 'preview missing')
assert(table.concat(display):find('SLOT',1,true), 'slot column missing')
assert(table.concat(operations, ', ')==scenario.expected, table.concat(operations, ', '))
print('PASS UI cleanup; operations: '..table.concat(operations, ', '))
