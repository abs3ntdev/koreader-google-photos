--[[--
Atomic JSON file storage.

write_json: write "<path>.tmp" -> check write/flush -> fsync (KOReader
ffi/util.fsyncOpenedFile when available; failure aborts) -> check close ->
os.rename over target -> fsync directory (best effort). Any failure returns
nil,err BEFORE the rename, so callers (e.g. pairing ack) never proceed on a
non-durable write.

Permissions: chmod 0600 is attempted via ffi. Result is reported as
`perms_ok`; on FAT/vfat/exFAT reader storage POSIX modes are not honoured and
the file is effectively readable by anyone with access to the device.
Reads never execute file content (JSON only).
--]]

local json = require("gphotos/json")

local Storage = {}

-- Injectable for tests: { fsync = fn(file)->ok,err, fsync_dir = fn(path), chmod = fn(path, mode)->ok }
Storage.sys = nil

local function default_sys()
    local sys = {}
    local ok, ffiUtil = pcall(require, "ffi/util")
    if ok and type(ffiUtil) == "table" and ffiUtil.fsyncOpenedFile then
        sys.fsync = function(f) return ffiUtil.fsyncOpenedFile(f) end
        sys.fsync_dir = function(p) return ffiUtil.fsyncDirectory(p) end
    end
    local fok, ffi = pcall(require, "ffi")
    if fok then
        pcall(ffi.cdef, "int chmod(const char *path, unsigned int mode);")
        if pcall(function() return ffi.C.chmod end) then
            sys.chmod = function(path, mode) return ffi.C.chmod(path, mode) == 0 end
        end
    end
    return sys
end

local function sys()
    if not Storage.sys then Storage.sys = default_sys() end
    return Storage.sys
end

--- Atomically writes `data` as JSON. Returns true, perms_ok or nil, err.
function Storage.write_json(path, data)
    local ok, encoded = pcall(json.encode, data)
    if not ok or type(encoded) ~= "string" then return nil, "encode failed: " .. tostring(encoded) end
    local s = sys()
    local tmp = path .. ".tmp"
    os.remove(tmp)
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local perms_ok = s.chmod and s.chmod(tmp, 384) or false -- 0600 before content
    local function fail(e)
        pcall(f.close, f)
        os.remove(tmp)
        return nil, tostring(e)
    end
    local wok, werr = f:write(encoded)
    if not wok then return fail(werr) end
    local fok, ferr = f:flush()
    if not fok then return fail(ferr) end
    if s.fsync then
        local sok, serr = s.fsync(f)
        if not sok then return fail("fsync: " .. tostring(serr)) end
    end
    local cok, cerr = f:close()
    if not cok then os.remove(tmp); return nil, tostring(cerr) end
    local rok, rerr = os.rename(tmp, path)
    if not rok then os.remove(tmp); return nil, rerr end
    if s.fsync_dir then
        -- Rename is visible but may not survive a crash: report non-durable so
        -- callers (pairing ack) do not proceed; they retry the whole write.
        local dok, dres, derr = pcall(s.fsync_dir, path)
        if not dok or not dres then return nil, "directory fsync: " .. tostring(derr or dres) end
    end
    if s.chmod then perms_ok = s.chmod(path, 384) and perms_ok end
    return true, perms_ok
end

--- Reads a JSON table. Returns table, or nil + "missing" (ENOENT only) | error string.
function Storage.read_json(path)
    local f, err, errno = io.open(path, "rb")
    if not f then
        if errno == 2 then return nil, "missing" end
        return nil, "read error: " .. tostring(err)
    end
    local content, rerr = f:read("*a")
    f:close()
    if not content then return nil, "read error: " .. tostring(rerr) end
    local v, derr = json.decode(content)
    if type(v) ~= "table" then return nil, "corrupt: " .. tostring(derr) end
    return v
end

return Storage
