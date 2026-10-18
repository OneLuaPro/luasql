-- backend/oracle.lua
-- Oracle specific functions for the stress test runner.

-- Builds an EZConnect string: host:port/service
local function sourceName(settings)
   return string.format("%s:%d/%s", settings.host, settings.port, settings.name)
end

return {
   sourceName = sourceName,
   -- Readable by every user, no extra privileges needed.
   versionQuery = "SELECT product || ' ' || version_full"
      .. " FROM product_component_version WHERE ROWNUM = 1",
}
