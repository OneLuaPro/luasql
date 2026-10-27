-- laneconn.lua
-- Opens a test connection inside a lane (Lua Lanes). A lane is a Lua
-- state of its own and LuaSQL objects cannot be passed to it, so the
-- lane loads the driver itself and reads the connection settings from
-- the environment variables, as the runner does (settings.lua). A
-- scenario hands a lane only ctx.laneSpec: the DBMS name and the module
-- paths, no credentials.

local settings = require("settings")

local laneconn = {}

-- Opens an environment and a test connection, switched to exact numbers
-- if the driver can. Returns a table with driver, backend, env and conn,
-- or nil and an error message.
function laneconn.open(dbms)
   local config, err = settings.loadModule("config", dbms)
   if not config then
      return nil, err
   end
   local backend
   backend, err = settings.loadModule("backend", dbms)
   if not backend then
      return nil, err
   end
   local values
   values, err = settings.read(config)
   if not values then
      return nil, err
   end
   local ok, driver = pcall(require, config.driverModule)
   if not ok then
      return nil, string.format("cannot load driver %s: %s",
                                config.driverModule, tostring(driver))
   end
   local env
   env, err = driver[config.driverName]()
   if not env then
      return nil, "cannot create environment: " .. tostring(err)
   end
   local conn
   conn, err = settings.connect(env, backend, values.test, "lane test")
   if not conn then
      env:close()
      return nil, err
   end
   local mode
   mode, err = settings.useExactNumbers(conn)
   if not mode then
      conn:close()
      env:close()
      return nil, err
   end
   return { driver = driver, backend = backend, env = env, conn = conn }
end

-- Closes the connection and the environment of laneconn.open. Returns
-- true, or nil and an error message.
function laneconn.close(link)
   local ok, err = link.conn:close()
   if not ok then
      return nil, "close connection: " .. tostring(err)
   end
   ok, err = link.env:close()
   if not ok then
      return nil, "close environment: " .. tostring(err)
   end
   return true
end

return laneconn
