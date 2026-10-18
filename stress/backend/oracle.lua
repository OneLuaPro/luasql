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
   -- Used by scenarios.
   singleRowQuery = "SELECT 1 FROM dual",
   multiRowQuery = "SELECT level FROM dual CONNECT BY level <= 10",
   sessionIdQuery = "SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual",
   -- Runs on the admin connection, %d is the session id of the test
   -- connection. Counts the cursors that count against open_cursors.
   openCursorsQuery = "SELECT s.value FROM v$sesstat s"
      .. " JOIN v$statname n ON n.statistic# = s.statistic#"
      .. " WHERE n.name = 'opened cursors current' AND s.sid = %d",
}
