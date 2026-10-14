---------------------------------------------------------------------
-- ADO driver implemented using LuaCOM
---------------------------------------------------------------------

require"luacom"
-- Lua strings are UTF-8; luacom defaults to the ANSI code page
luacom.SetCodepage(65001)

---------------------------------------------------------------------
-- luasql table name
---------------------------------------------------------------------
local luasql = {}

local Private = {}

local ADOTypes = {}

do
  local conn = luacom.CreateObject("ADODB.Connection")
  local typeinfo = luacom.GetTypeInfo(conn)
  local typelib = typeinfo:GetTypeLib()
  local enums = typelib:ExportEnumerations()
  for k, v in pairs(enums.DataTypeEnum) do
    ADOTypes[k] = v
    ADOTypes[v] = k
  end
end

-- one metatable per object, so that __tostring can report the state of that object
local function newmeta(kind, is_closed)
  return {
    __metatable = "LuaSQL: you're not allowed to get this metatable",
    __close = function(obj) obj:close() end,
    __tostring = function(obj)
      if is_closed() then
        return "ADO " .. kind .. " (closed)"
      end
      return string.format("ADO %s (%p)", kind, obj)
    end,
  }
end

luasql._COPYRIGHT = "Copyright (C) 2003-2006 Kepler Project"
luasql._DESCRIPTION = "LuaSQL is a simple interface from Lua to a DBMS"
luasql._VERSION = "LuaSQL 2.8.1"

---------------------------------------------------------------------
-- function that returns an ADO environment
---------------------------------------------------------------------
-- strip luacom's "COM exception:(file,line):" prefix from error messages
local function clean(msg)
  return (tostring(msg):gsub("^COM exception:%b():%s*", ""))
end

function luasql.ado()
    local isClosed  = false
    local openConns = {}
    openConns.n     = 0

    local env = {}

    setmetatable(env, newmeta("environment", function() return isClosed end))

    env.ADOTypes = ADOTypes

    local function closeConn(con)

        if not openConns[con] then
            return false
        end

        openConns[con] = nil
        openConns.n = openConns.n - 1

        return true
    end

    function env:close()
        if not self then error("You must provide a self parameter") end

        if isClosed or openConns.n ~= 0 then
            return false
        end

        isClosed = true

        return true
    end

    function env:connect(sourcestr, user, pass, opts)
        if not self then error("You must provide a self parameter") end

        if isClosed then
            error("Environment closed")
        end

        if type(sourcestr) ~= "string" then
            error("Sourcename must be a string")
        end

        local conn = luacom.CreateObject("ADODB.Connection")
	if type(opts) ~= "number" then opts = -1 end  -- adConnectUnspecified
	local ok, errmsg = pcall(conn.Open, conn, sourcestr, user or "", pass or "", opts)

        if not ok then
	    return nil, clean(errmsg)
        end

        if conn.State == 0 then
            return nil, "Invalid sourcename"
        end

        openConns[conn] = true
        openConns.n = openConns.n + 1

        local ok, errmsg = pcall(conn.BeginTrans, conn)

        return Private.createConnection(conn, closeConn)
    end

    return env
end


---------------------------------------------------------------------
-- creates an ADO connection
---------------------------------------------------------------------
function Private.createConnection(conObj, closeFunc)

    local openCursors = {}
    openCursors.n = 0
    local isClosed = false

    local con = {}

    setmetatable(con, newmeta("connection", function() return isClosed end))

    local autocommit = true

    local function closeCursor(cursor)

        if not openCursors[cursor] then
            return false
        end

        openCursors[cursor] = nil
        openCursors.n = openCursors.n - 1
    end

    function con:close()
        if not self then error("You must provide a self parameter") end

        if isClosed or openCursors.n ~= 0 then
            return false
        end

        isClosed = true
        local cond, err = pcall(conObj.RollbackTrans, conObj)
        conObj:Close()
        closeFunc(conObj)

        return true
    end

    function con:commit()
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Connection closed")
        end

        local cond, err = pcall(conObj.CommitTrans, conObj)
        if not cond then
            return false, clean(err)
        end

        local cond, err = pcall(conObj.BeginTrans, conObj)
        if not cond then
            return false, clean(err)
        end

        return true
    end

    function con:execute(sql)
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Connection closed")
        end

        local cond, res, upcount = pcall(conObj.Execute, conObj, sql)
        if not cond then
	    return nil, clean(res)
        end

        if not upcount then upcount = 0 end
	upcount = math.tointeger(upcount) or upcount

        if autocommit then
          local cond, err = con:commit()
          if not cond then
            return nil, err
          end
        end

        if res and res.State ~= 0  then
            res = Private.createCursor(res, con, closeCursor)
            openCursors[res] = true
            openCursors.n = openCursors.n + 1
        else
            res = upcount
        end

        return res
    end

    function con:rollback()
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Connection closed")
        end

        local cond, err = pcall(conObj.RollbackTrans, conObj)
        if not cond then
            return false, clean(err)
        end

        local cond, err = pcall(conObj.BeginTrans, conObj)
        if not cond then
            return false, clean(err)
        end

        return true
    end

    function con:setautocommit(bool)
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Connection closed")
        end

        local cond, err = pcall(conObj.CommitTrans, conObj)
        if not cond then
            return false, clean(err)
        end

        autocommit = bool

        local cond, err = pcall(conObj.BeginTrans, conObj)
        if not cond then
            return false, clean(err)
        end

        return true
    end

    return con
end

---------------------------------------------------------------------
-- creates an ADO cursor (recordset)
---------------------------------------------------------------------
function Private.createCursor(rs, con, closeFunc)

    local isClosed = false
    local cursor = rs
    local res = {}
    local col_names = nil
    local col_types = nil

    setmetatable(res, newmeta("cursor", function() return isClosed end))

    function res:close()
        if not self then error("You must provide a self parameter") end

        if isClosed then
            return false
        end

        rs:Close()
        closeFunc(res, con)

        isClosed = true

        return true
    end

    function res:fetch(tb, modestring)
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Cursor closed")
        end

        local arg_tb = tb

	if cursor.EOF then
	   res:close()
	   return nil
	end

        if tb == nil or type(tb) ~= "table" then
            tb = {}
        end

        if modestring == nil or type(modestring) ~= "string" then
            modestring = "n"
        end

	local ncols = cursor.Fields.Count
        for i = 0, cursor.Fields.Count-1 do
          local fields = cursor.Fields
          local cond, field = pcall(fields.Item, fields, i)
          if not cond then
            return nil, field
          end
          if modestring == "n" or modestring == "an" or modestring == "na" then
            tb[i+1] = field.Value
          end
          if modestring == "a" or modestring == "an" or modestring == "na" then
            tb[field.Name] = field.Value
          end
        end
        local cond, err = pcall(cursor.MoveNext, cursor)
        if not cond then
            return nil, err
        end

        if modestring == "n" and not arg_tb then
	   return table.unpack(tb, 1, ncols)
        else
          return tb
        end
    end

    function res:getcolnames()
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Cursor closed")
        end

        if col_names then return col_names end

        col_names = {}
        local tb = col_names

        for i = 0, cursor.Fields.Count-1 do
          local fields = cursor.Fields
          local cond, field = pcall(fields.Item, fields, i)
          if not cond then
            return nil, field
          end
          tb[i+1] = field.Name
        end

        return tb
    end

    function res:getcoltypes()
        if not self then error("You must provide a self parameter") end

        if isClosed then
          error("Cursor closed")
        end

        if col_types then return col_types end

        col_types = {}
        local tb = col_types

        for i = 0, cursor.Fields.Count-1 do
          local fields = cursor.Fields
          local cond, field = pcall(fields.Item, fields, i)
          if not cond then
            return nil, field
          end
          tb[i+1] = ADOTypes[field.Type]
        end

        return tb
    end

    return res
end

return luasql
