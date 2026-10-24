-- report.lua
-- Prints output lines of the stress test: the text after a prefix
-- (indent and label column) is wrapped at a maximum line width, and
-- continuation lines are indented to the start of the text.

local report = {}

-- Maximum width of an output line. Counted in bytes, so lines with
-- multibyte characters wrap a little early.
report.width = 100

-- Smallest text width, so a long prefix still leaves room for text.
local minTextWidth = 20

-- Wraps text into lines of at most 'width' bytes. Line breaks in the
-- text (e.g. in server error messages) become spaces, white space at the
-- end is dropped. Breaks after "; " if that fills at least half of the
-- line, otherwise at the last space; a word longer than a line stays
-- whole. Returns a list.
local function wrap(text, width)
   text = text:gsub("[ \t]*\r?\n[ \t]*", " "):gsub("%s+$", "")
   local lines = {}
   while #text > width do
      local head = text:sub(1, width + 1)
      -- Position of the last "; " whose ";" still fits on the line.
      local semi = head:match("^.*();% ")
      local cut
      if semi and semi >= width // 2 then
         cut = semi + 1
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

-- Prints text after prefix; lines that do not fit are wrapped and
-- indented to the end of the prefix.
function report.print(prefix, text)
   local width = math.max(report.width - #prefix, minTextWidth)
   local indent = string.rep(" ", #prefix)
   for i, line in ipairs(wrap(tostring(text), width)) do
      print((i == 1 and prefix or indent) .. line)
   end
end

return report
