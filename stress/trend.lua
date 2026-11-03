-- trend.lua
-- Robust slopes of a series of memory samples, used by phases.lua and
-- the soak scenario. The memory of a process does not grow smoothly:
-- the heap takes memory from the system in blocks and gives it back
-- later, so a single difference between two samples may fall into such
-- a step. The median of the slopes between all pairs of samples
-- (Theil-Sen estimator) is hardly moved by single spikes and dips, but
-- a lasting step in the middle of a short series still moves it; the
-- median of the slopes of several parts (partSlope) is not moved by one
-- step, while a steady leak moves every part.

local trend = {}

-- Robust slope of the points (xs[k], ys[k]) for k = 1 .. n (default:
-- #xs): the median of the slopes between all pairs. With more than
-- maxPoints points (optional), the points are thinned out evenly first.
-- Returns 0 for fewer than two distinct x values.
function trend.theilSen(xs, ys, n, maxPoints)
   n = n or #xs
   local step = math.max(1, n / (maxPoints or n))
   local px, py = {}, {}
   for k = 1, n, step do
      local index = math.floor(k)
      px[#px + 1], py[#py + 1] = xs[index], ys[index]
   end
   local slopes = {}
   for a = 1, #px - 1 do
      for b = a + 1, #px do
         if px[b] > px[a] then
            slopes[#slopes + 1] = (py[b] - py[a]) / (px[b] - px[a])
         end
      end
   end
   table.sort(slopes)
   local m = #slopes
   if m == 0 then
      return 0
   end
   if m % 2 == 1 then
      return slopes[(m + 1) // 2]
   end
   return (slopes[m // 2] + slopes[m // 2 + 1]) / 2
end

-- Slope of a series that tells a steady growth from a single step: the
-- points 1 .. n are split into 'parts' consecutive parts of about the
-- same size, each gets its robust slope, and the median of these slopes
-- is returned. A step of the heap lies in one part and moves only that
-- part's slope; a leak moves all of them. With fewer than three points
-- per part, the robust slope of all points is returned.
function trend.partSlope(xs, ys, n, parts)
   if n < 3 * parts then
      return trend.theilSen(xs, ys, n)
   end
   local slopes = {}
   for part = 1, parts do
      local first = (part - 1) * n // parts + 1
      local last = part * n // parts
      local px, py = {}, {}
      for k = first, last do
         px[#px + 1], py[#py + 1] = xs[k], ys[k]
      end
      slopes[part] = trend.theilSen(px, py)
   end
   table.sort(slopes)
   if parts % 2 == 1 then
      return slopes[(parts + 1) // 2]
   end
   return (slopes[parts // 2] + slopes[parts // 2 + 1]) / 2
end

return trend
