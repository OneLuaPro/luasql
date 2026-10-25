-- report.lua
-- Prints output lines of the stress test: the text after a prefix
-- (indent and label column) is wrapped at a maximum line width, and
-- continuation lines are indented to the start of the text.
--
-- Entries can be colored by their kind (see colors below): on Windows
-- through the console API (ffi), elsewhere with ANSI escape sequences
-- when stdout is a terminal (checked with luv, ffi or luaposix). Output
-- into a file or pipe stays plain. NO_COLOR (set, not empty) turns
-- colors off, FORCE_COLOR turns ANSI colors on without the terminal
-- check (not on Windows, whose console shows them as text).

local report = {}

-- Maximum width of an output line. Counted in bytes, so lines with
-- multibyte characters wrap a little early.
report.width = 100

-- True to list passed cases too (stress.lua --verbose); otherwise only
-- failures, limits and skips are listed.
report.verbose = false

-- Smallest text width, so a long prefix still leaves room for text.
local minTextWidth = 20

-- Wraps text into lines of at most 'width' bytes. Line breaks in the
-- text (e.g. in server error messages) become spaces, white space at the
-- end is dropped. Breaks after "; " if that fills at least half of the
-- line, then after ", ", otherwise at the last space; a word longer than
-- a line stays whole. Returns a list.
local function wrap(text, width)
   text = text:gsub("[ \t]*\r?\n[ \t]*", " "):gsub("%s+$", "")
   local lines = {}
   while #text > width do
      local head = text:sub(1, width + 1)
      -- Position of the last "; " or ", " whose ";" or "," still fits
      -- on the line.
      local semi = head:match("^.*();% ")
      local comma = head:match("^.*(),% ")
      local cut
      if semi and semi >= width // 2 then
         cut = semi + 1
      elseif comma and comma >= width // 2 then
         cut = comma + 1
      else
         -- Position of the last space within the first width + 1 bytes.
         cut = head:match("^.*() ")
         if not cut or cut == 1 then
            cut = text:find(" ", width + 2, true)
            if not cut then
               break
            end
         end
      end
      lines[#lines + 1] = text:sub(1, cut - 1)
      text = text:sub(cut + 1)
   end
   lines[#lines + 1] = text
   return lines
end

-- Colors per kind of entry: Windows console attribute (foreground,
-- bright variant) and ANSI code.
local colors = {
   pass = { console = 10, ansi = "32" },    -- green
   fail = { console = 12, ansi = "91" },    -- light red
   limit = { console = 14, ansi = "93" },   -- light yellow
   note = { console = 11, ansi = "96" },    -- light cyan
   skip = { console = 8, ansi = "90" },     -- gray
}

local function envSet(name)
   local value = os.getenv(name)
   return value ~= nil and value ~= ""
end

-- Windows console: returns a function that sets the color of a kind
-- (nil for the original one), or nil if stdout is no console.
local function consoleColorizer()
   local ok, ffi = pcall(require, "ffi")
   if not ok then
      return nil
   end
   -- Another module may have declared these already.
   pcall(ffi.cdef, [[
      typedef struct { short x; short y; } StressCoord;
      typedef struct { short left; short top; short right;
                       short bottom; } StressRect;
      typedef struct {
         StressCoord size;
         StressCoord cursor;
         uint16_t attributes;
         StressRect window;
         StressCoord maxSize;
      } StressScreenInfo;
      void *GetStdHandle(uint32_t nStdHandle);
      int SetConsoleTextAttribute(void *hConsoleOutput, uint16_t wAttributes);
      int GetConsoleScreenBufferInfo(void *hConsoleOutput,
                                     StressScreenInfo *info);
   ]])
   local handleOk, handle = pcall(function()
      return ffi.C.GetStdHandle(0xFFFFFFF5)   -- STD_OUTPUT_HANDLE (-11)
   end)
   if not handleOk then
      return nil
   end
   -- Fails if stdout is redirected into a file or pipe.
   local infoOk, original = pcall(function()
      local info = ffi.new("StressScreenInfo[1]")
      if ffi.C.GetConsoleScreenBufferInfo(handle, info) == 0 then
         return nil
      end
      return info[0].attributes
   end)
   if not infoOk or original == nil then
      return nil
   end
   original = tonumber(original)
   local background = original - original % 16
   return function(kind)
      io.stdout:flush()
      local attributes = original
      if kind then
         attributes = background + colors[kind].console
      end
      ffi.C.SetConsoleTextAttribute(handle, attributes)
   end
end

-- True if stdout is a terminal, as far as one of luv, ffi or luaposix
-- can tell; false if none can.
local function stdoutIsTerminal()
   local uvOk, uv = pcall(require, "luv")
   if uvOk and uv.guess_handle then
      return uv.guess_handle(1) == "tty"
   end
   local ffiOk, ffi = pcall(require, "ffi")
   if ffiOk then
      pcall(ffi.cdef, "int isatty(int fd);")
      local ok, result = pcall(function() return ffi.C.isatty(1) end)
      if ok then
         return result ~= 0
      end
   end
   local posixOk, unistd = pcall(require, "posix.unistd")
   if posixOk and unistd.isatty then
      return unistd.isatty(1) == 1
   end
   return false
end

-- ANSI terminal: returns a function as consoleColorizer does.
local function ansiColorizer()
   if not envSet("FORCE_COLOR") and not stdoutIsTerminal() then
      return nil
   end
   return function(kind)
      io.stdout:write(kind and ("\27[" .. colors[kind].ansi .. "m")
                      or "\27[0m")
   end
end

-- The colorizer of this run, set up on first use; false for none.
local colorizer

local function setColor(kind)
   if colorizer == nil then
      colorizer = false
      if not envSet("NO_COLOR") then
         -- The Windows console shows ANSI sequences as text unless VT
         -- mode is on, so Windows uses the console API only.
         if package.config:sub(1, 1) == "\\" then
            colorizer = consoleColorizer() or false
         else
            colorizer = ansiColorizer() or false
         end
      end
   end
   if colorizer then
      colorizer(kind)
   end
end

-- Writes one line, part1 in color kind (if given), part2 plain.
local function writeLine(part1, part2, kind)
   if kind and part1 ~= "" then
      setColor(kind)
      io.stdout:write(part1)
      setColor(nil)
   else
      io.stdout:write(part1)
   end
   io.stdout:write(part2, "\n")
end

-- Prints text after prefix; lines that do not fit are wrapped and
-- indented to the end of the prefix. kind (optional: "pass", "fail",
-- "limit", "note", "skip") colors the entry: "pass", "fail" and "limit"
-- only the label in the prefix (or the text if the prefix is blank),
-- "note" and "skip" all of it.
function report.print(prefix, text, kind)
   local width = math.max(report.width - #prefix, minTextWidth)
   local indent = string.rep(" ", #prefix)
   local labelOnly = (kind == "pass" or kind == "fail" or kind == "limit")
      and prefix:find("%S") ~= nil
   for i, line in ipairs(wrap(tostring(text), width)) do
      local head = i == 1 and prefix or indent
      if labelOnly then
         -- The label keeps its color, the text stays plain.
         writeLine(head, line, i == 1 and kind or nil)
      else
         writeLine(head .. line, "", kind)
      end
   end
   io.stdout:flush()
end

return report
