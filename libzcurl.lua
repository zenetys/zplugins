-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Author: Julien Thomas
-- Licence: MIT

local curl = require 'lcurl.safe'
local lu = require 'libutil'

local curlinfo_allowed = {
    INFO_APPCONNECT_TIME = true,
    INFO_CONNECT_TIME = true,
    INFO_CONTENT_LENGTH_DOWNLOAD = true,
    INFO_CONTENT_LENGTH_UPLOAD = true,
    INFO_CONTENT_TYPE = true,
    INFO_COOKIELIST = true,
    INFO_EFFECTIVE_URL = true,
    INFO_HEADER_SIZE = true,
    INFO_HTTP_VERSION = true,
    INFO_LOCAL_IP = true,
    INFO_NAMELOOKUP_TIME = true,
    INFO_NUM_CONNECTS = true,
    INFO_PRIMARY_IP = true,
    INFO_PRIMARY_PORT = true,
    INFO_PROTOCOL = true,
    INFO_REDIRECT_COUNT = true,
    INFO_REDIRECT_TIME = true,
    INFO_REDIRECT_URL = true,
    INFO_REQUEST_SIZE = true,
    INFO_SCHEME = true,
    INFO_SIZE_DOWNLOAD = true,
    INFO_SIZE_UPLOAD = true,
    INFO_SPEED_DOWNLOAD = true,
    INFO_SPEED_UPLOAD = true,
    INFO_STARTTRANSFER_TIME = true,
    INFO_RESPONSE_CODE = true,
    INFO_TOTAL_TIME = true,
}

local ZCurl = {}
ZCurl.__index = ZCurl

ZCurl.curlopts_function = {}
ZCurl.curlinfo_enabled = {}
for k,v in pairs(curl) do
    if k:sub(1, 4) == 'OPT_' and k:sub(-8) == 'FUNCTION' then
        local opt_id = math.floor(v)
        local opt_name = k:sub(5):lower()
        ZCurl.curlopts_function[opt_id] = true
        ZCurl.curlopts_function[opt_name] = true
    elseif k:sub(1, 5) == 'INFO_' then
        ZCurl.curlinfo_enabled[k] = curlinfo_allowed[k] or false
    end
end


function ZCurl.new(curlopts)
    local instance = {}
    setmetatable(instance, ZCurl)

    instance.default_curlopts = curlopts
    instance.current_curlopts = nil
    instance.response = nil
    instance.info = nil

    local err
    instance.curl, err = curl.easy()
    if not instance.curl then return nil, err end
    return instance:resetopts()
end

function ZCurl:o(opt, nil_value)
    if type(opt) == 'string' and opt:sub(1,6) ~= 'zcurl_' then
        local v = self.current_curlopts[curl['OPT_'..opt:upper()]]
        if v then return v end
    end
    return self.current_curlopts[opt] or nil_value
end

function ZCurl:resetopts()
    ret, err = self.curl:reset()
    if not ret then return nil, tostring(err) end
    self.current_curlopts = {}
    return self:setopts(self.default_curlopts)
end

function ZCurl:setopts(setcurlopts, unsetcurlopts)
    if setcurlopts then
        for o,v in pairs(setcurlopts) do
            if ZCurl.curlopts_function[o] and type(v) == 'function' then
                v = lu.fbind(v, self)
            end
            ret, err = self.curl:setopt({ [o] = v })
            if not ret then return nil, tostring(err) end
            self.current_curlopts[o] = v
        end
    end
    if unsetcurlopts then
        for _,o in ipairs(unsetcurlopts) do
            ret, err = self.curl:unsetopt(o)
            if not ret then return nil, tostring(err) end
            self.current_curlopts[o] = nil
        end
    end
    return self
end

function ZCurl:perform(setcurlopts, unsetcurlopts)
    local pret, ret, err
    -- reset response and info storage
    self.response = {}
    self.info = {}
    -- update options
    ret, err = self:setopts(setcurlopts, unsetcurlopts)
    if not ret then return nil, tostring(err) end
    -- run request, note pcall protects from lua-curl error, eg: lua error
    -- in a setopt_*function callback
    pret, ret, err = pcall(self.curl.perform, self.curl)
    if not pret then err = ret; ret = nil end
    -- fill info data
    for k,v in pairs(ZCurl.curlinfo_enabled) do
        if v then self.info[k:sub(6):lower()] = self:getinfo(curl[k]) end
    end
    if ret then return self end
    return nil, (self.info.response_code and self.info.response_code > 0
        and ('HTTP status %d, '):format(self.info.response_code) or '')..
        tostring(err)
end

function ZCurl:close()
    self.curl:close()
end

function ZCurl:getinfo(info)
    return self.curl:getinfo(info)
end

function ZCurl._store_response(name)
    return function (self, x)
        if name then self.response[name] = (self.response[name] or '')..x end
        return x and x:len() or 0
    end
end

-- ZCurl* modules advertise themself with ZCurl.register_abstract().
-- ZCurl.new_abstract() will instanciate the first module whose condition succeeds.
local abstract_modules = {}
function ZCurl.register_abstract(class, condition_fn)
    table.insert(abstract_modules, { class = class, condition_fn = condition_fn })
end
function ZCurl.new_abstract(...)
    local args = {...}
    for _,m in ipairs(abstract_modules) do
        if m.condition_fn(table.unpack(args)) then
            return m.class.new(table.unpack(args))
        end
    end
    return ZCurl.new(table.unpack(args))
end

return ZCurl
