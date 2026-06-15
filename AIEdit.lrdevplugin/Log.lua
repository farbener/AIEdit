-- Log.lua
-- Simple file logger. Writes timestamped lines to a fixed, easy-to-find path:
--   <Documents>/AIEdit_debug.log
-- This file is the primary troubleshooting tool — every step is logged here.
--
-- PUBLIC API
--   Log.reset()          truncate the file (called once at plugin load)
--   Log.write(message)   append a timestamped line

local LrPathUtils = import "LrPathUtils"

local Log = {}

-- Log file goes in the user's Documents folder so it's easy to find.
local docs = LrPathUtils.getStandardFilePath("documents")
local LOG_PATH = LrPathUtils.child(docs, "AIEdit_debug.log")

Log.path = LOG_PATH

local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- Append a line to the log file. Opens/closes each time so nothing is lost on crash.
function Log.write(msg)
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write("[" .. timestamp() .. "] " .. tostring(msg) .. "\n")
        f:close()
    end
end

-- Reset the log (called at the start of each run)
function Log.reset()
    local f = io.open(LOG_PATH, "w")
    if f then
        f:write("[" .. timestamp() .. "] === AI Edit log started ===\n")
        f:close()
    end
end

return Log
