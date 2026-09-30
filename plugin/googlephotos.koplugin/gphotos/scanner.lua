--[[--
Folder scanner: lists uploadable images in one directory (non-recursive).
Symlinks are skipped using lfs.symlinkattributes (never followed), as are
hidden files, non-regular files, unsupported types and oversize files.
--]]

local Photos = require("gphotos/photos")

local Scanner = {}

Scanner.MAX_BYTES = 200 * 1024 * 1024 -- Google Photos photo size limit

function Scanner._entry(path, name, a)
    if not a or a.mode ~= "file" or name:sub(1, 1) == "." then return nil, "not a regular file" end
    if not Photos.mime_for(name) then return nil, "unsupported file type" end
    if (a.size or 0) <= 0 or a.size > Scanner.MAX_BYTES then return nil, "empty or too large" end
    return {
        path = path, name = name, size = a.size, mtime = a.modification or 0,
        key = path .. "|" .. a.size .. "|" .. (a.modification or 0),
    }
end

--- Validates one exact file (never follows symlinks, parent must be a real directory).
-- Returns a one-element file list or nil, reason.
function Scanner.single(lfs, path)
    local dir, name = tostring(path or ""):match("^(.*)/([^/]+)$")
    if not dir or dir == "" then return nil, "invalid path" end
    local dattr = lfs.symlinkattributes(dir)
    if not dattr or dattr.mode ~= "directory" then return nil, "folder missing or symlinked" end
    local f, err = Scanner._entry(path, name, lfs.symlinkattributes(path))
    if not f then return nil, err end
    return { f }
end

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
            local f = Scanner._entry(path, name, a)
            if f then
                files[#files + 1] = f
            elseif not a or a.mode ~= "directory" then
                if a then skipped = skipped + 1 end
            end
        end
    end
    table.sort(files, function(x, y) return x.name < y.name end)
    return files, skipped
end

return Scanner
