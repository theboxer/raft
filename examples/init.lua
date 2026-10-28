-- Add this to your Rex init.lua. Adjust raft_dir to your checkout location.
local raft_dir = os.getenv("RAFT_ROOT") or (os.getenv("HOME") .. "/.config/rex/raft")
dofile(raft_dir .. "/raft.lua").setup {
    scope = "session",
    sessions = {
        sentinel = "tab",
        -- spindle = "pane",
    },
    bounds = { 0.1, 0.1, 0.8, 0.8 },
}

rex.bind("ctrl+s>f", "raft_toggle")
rex.bind("ctrl+s>q", "raft_hide")
rex.bind("ctrl+s>shift+f", "raft_manage")
for slot = 1, 9 do
    rex.bind("ctrl+s>ctrl+f>" .. slot, "raft_toggle", { slot = slot })
end

-- Alternatively, bind an individual slot:
-- rex.bind("ctrl+s>alt+2", "raft_toggle", { slot = 2 })
