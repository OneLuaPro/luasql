-- state.lua
-- Keeps small pieces of state between runs, e.g. the original value of a
-- server parameter changed by a prep step.
--
-- The files live in a per-user directory, because the scripts may be
-- installed in a location that is not writable for normal users:
--   %LOCALAPPDATA%, $XDG_STATE_HOME, $HOME/.local/state, %TEMP%, %TMP%
-- (first one found), subdirectory luasql-stress.
--
-- File format: one "key=value" per line. The files are parsed, never
-- executed.

local lfs = require("lfs")

local appName = "luasql-stress"
local sep = package.config:sub(1, 1)

local state = {}

local function nonEmpty(value)
   if value ~= nil and value ~= "" then
      return value
   end
   return nil
end

-- Returns the per-user base directory, or nil and an error message.
local function baseDir()
   local dir = nonEmpty(os.getenv("LOCALAPPDATA"))
      or nonEmpty(os.getenv("XDG_STATE_HOME"))
   if not dir then
      local home = nonEmpty(os.getenv("HOME"))
      if home then
         dir = home .. sep .. ".local" .. sep .. "state"
      end
   end
   dir = dir or nonEmpty(os.getenv("TEMP")) or nonEmpty(os.getenv("TMP"))
   if not dir then
      return nil, "no per-user directory found (LOCALAPPDATA,"
         .. " XDG_STATE_HOME, HOME, TEMP, TMP)"
   end
   return dir
end

-- Creates 'path' and all missing parent directories.
-- Returns true, or nil and an error message.
local function makeDirs(path)
   if lfs.attributes(path, "mode") == "directory" then
      return true
   end
   local parent = path:match("^(.*)[/\\][^/\\]+$")
   -- Stop at the root or at a drive letter like "C:".
   if parent and parent ~= "" and not parent:match("^%a:$") then
      local ok, err = makeDirs(parent)
      if not ok then
         return nil, err
      end
   end
   local ok, err = lfs.mkdir(path)
   if not ok and lfs.attributes(path, "mode") ~= "directory" then
      return nil, "cannot create directory " .. path .. ": " .. tostring(err)
   end
   return true
end

-- Returns the state file path for a DBMS and a target database, or nil
-- and an error message. 'target' may hold host, port and name.
function state.filePath(dbms, target)
   local base, err = baseDir()
   if not base then
      return nil, err
   end
   local parts = { dbms }
   for _, field in ipairs({ "host", "port", "name" }) do
      if target[field] ~= nil then
         parts[#parts + 1] = tostring(target[field])
      end
   end
   local fileName = table.concat(parts, "_"):gsub("[^%w_%-%.]", "-")
   return base .. sep .. appName .. sep .. fileName .. ".state"
end

-- Reads a state file. Returns a table with the values, or nil if there
-- is no such file, or nil and an error message if it cannot be parsed.
function state.load(path)
   local file = io.open(path, "r")
   if not file then
      return nil
   end
   local values = {}
   local lineNo = 0
   for line in file:lines() do
      lineNo = lineNo + 1
      if line:match("%S") then
         local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
         if not key then
            file:close()
            return nil, string.format("%s:%d: invalid line", path, lineNo)
         end
         values[key] = value
      end
   end
   file:close()
   return values
end

-- Writes a state file, replacing an existing one.
-- Returns true, or nil and an error message.
function state.save(path, values)
   local ok, err = makeDirs(path:match("^(.*)[/\\]"))
   if not ok then
      return nil, err
   end
   local keys = {}
   for key, value in pairs(values) do
      if type(key) ~= "string" or not key:match("^[%w_]+$") then
         return nil, "invalid state key: " .. tostring(key)
      end
      if tostring(value):find("[\r\n]") then
         return nil, "state value for " .. key .. " contains a line break"
      end
      keys[#keys + 1] = key
   end
   table.sort(keys)

   local file
   file, err = io.open(path, "w")
   if not file then
      return nil, "cannot write " .. path .. ": " .. tostring(err)
   end
   for _, key in ipairs(keys) do
      file:write(key, "=", tostring(values[key]), "\n")
   end
   ok, err = file:close()
   if not ok then
      return nil, "cannot write " .. path .. ": " .. tostring(err)
   end
   return true
end

-- Deletes a state file. A missing file is not an error.
-- Returns true, or nil and an error message.
function state.remove(path)
   local ok, err = os.remove(path)
   if not ok and lfs.attributes(path, "mode") then
      return nil, "cannot delete " .. path .. ": " .. tostring(err)
   end
   return true
end

return state
