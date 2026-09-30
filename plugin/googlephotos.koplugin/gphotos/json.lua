--[[--
JSON adapter over dkjson (shipped by KOReader: koreader-base
thirdparty/dkjson, dkjson 2.10, installed as common/dkjson.lua).
Returns value or nil, err. Rejects trailing non-whitespace.
Never evaluates data as code.
--]]
local dkjson = require("dkjson")

local json = {}

--- Marks a table to be encoded as a JSON array (even when empty).
function json.array(t)
    return setmetatable(t or {}, { __jsontype = "array" })
end

function json.encode(v)
    return dkjson.encode(v)
end

function json.decode(s)
    if type(s) ~= "string" then return nil, "json: input is not a string" end
    local ok, v, pos, err = pcall(dkjson.decode, s, 1, nil)
    if not ok then return nil, tostring(v) end
    if err then return nil, err end
    if type(pos) ~= "number" or s:find("[^ \t\r\n]", pos) then
        return nil, "json: trailing data"
    end
    return v
end

return json
