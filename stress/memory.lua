-- memory.lua
-- Memory of this process for leak checks over a long time (soak). On
-- Windows the private bytes (K32GetProcessMemoryInfo through ffi): unlike
-- the working set, which luv reports as rss, Windows does not trim them,
-- so they do not drop and jump back. Elsewhere, or without ffi, the rss
-- from luv.
--
-- memory.label  what processKb measures ("private bytes" or "rss"), nil
--               if nothing can be measured
-- memory.processKb()  the current value in KB, or nil

local memory = {}

-- Returns a reader of the private bytes on Windows, or nil.
local function privateBytesReader()
   if package.config:sub(1, 1) ~= "\\" then
      return nil
   end
   local hasFfi, ffi = pcall(require, "ffi")
   if not hasFfi then
      return nil
   end
   -- PROCESS_MEMORY_COUNTERS_EX; SIZE_T is 64 bits wide on x64.
   pcall(ffi.cdef, [[
      typedef struct {
         uint32_t cb;
         uint32_t PageFaultCount;
         uint64_t PeakWorkingSetSize;
         uint64_t WorkingSetSize;
         uint64_t QuotaPeakPagedPoolUsage;
         uint64_t QuotaPagedPoolUsage;
         uint64_t QuotaPeakNonPagedPoolUsage;
         uint64_t QuotaNonPagedPoolUsage;
         uint64_t PagefileUsage;
         uint64_t PeakPagefileUsage;
         uint64_t PrivateUsage;
      } StressMemCounters;
      void *GetCurrentProcess(void);
      int K32GetProcessMemoryInfo(void *process,
                                  StressMemCounters *counters,
                                  uint32_t cb);
   ]])
   local ok, reader = pcall(function()
      local size = ffi.sizeof("StressMemCounters")
      local buffer = ffi.new("StressMemCounters[1]")
      local process = ffi.C.GetCurrentProcess()
      local function read()
         buffer[0].cb = size
         if ffi.C.K32GetProcessMemoryInfo(process, buffer, size) == 0 then
            return nil
         end
         return tonumber(buffer[0].PrivateUsage) / 1024
      end
      -- Only a reader that works now is used.
      assert(read())
      return read
   end)
   return ok and reader or nil
end

-- Returns a reader of the rss from luv, or nil.
local function rssReader()
   local hasUv, uv = pcall(require, "luv")
   if not hasUv then
      return nil
   end
   return function()
      return uv.resident_set_memory() / 1024
   end
end

local reader = privateBytesReader()
if reader then
   memory.label = "private bytes"
else
   reader = rssReader()
   memory.label = reader and "rss" or nil
end

function memory.processKb()
   return reader and reader() or nil
end

return memory
