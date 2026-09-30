--[[--
Folder scanner: lists uploadable images in one directory (non-recursive).
Symlinks are skipped using lfs.symlinkattributes (never followed), as are
hidden files, non-regular files, unsupported types and oversize files.
--]]

local Photos = require("gphotos/photos")

local Scanner = {}

Scanner.MAX_BYTES = 200 * 1024 * 1024 -- Google Photos photo size limit

--- Returns sorted list of { path, name, size, mtime, key } and skipped count.
function Scanner.scan(lfs, dir)
    dir = dir:gsub("/+$", "")
    local dattr = lfs.symlinkattributes(dir)
    if not dattr or dattr.mode ~= "directory" then
        return nil, "not a directory (symlinked folders are not followed)"
    end
    local files, skipped = {}, 0
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then return nil, tostring(iter) end
    for name in iter, state do
        if name ~= "." and name ~= ".." then
            local path = dir .. "/" .. name
            local a = lfs.symlinkattributes(path)
            if not a or a.mode ~= "file" or name:sub(1, 1) == "." then
                if a and a.mode ~= "directory" then skipped = skipped + 1 end
            elseif not Photos.mime_for(name) or (a.size or 0) <= 0 or a.size > Scanner.MAX_BYTES then
                skipped = skipped + 1
            else
                files[#files + 1] = {
                    path = path, name = name, size = a.size, mtime = a.modification or 0,
                    key = path .. "|" .. a.size .. "|" .. (a.modification or 0),
                }
            end
        end
    end
    table.sort(files, function(x, y) return x.name < y.name end)
    return files, skipped
end

return Scanner
