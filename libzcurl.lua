-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Author: Julien Thomas
-- Licence: MIT

local curl = require 'lcurl'

local ZCurl = {}

function ZCurl:new(curlopts)
    local instance = {}
    self.__index = self
    setmetatable(instance, self)
    instance.default_curlopts = curlopts
    instance.curl = curl.easy(curlopts)
    instance.response = {}
    return instance
end

function ZCurl:resetopts()
    self.curl:reset()
    self:setopts(self.default_curlopts)
end

function ZCurl:setopts(setcurlopts, unsetcurlopts)
    if setcurlopts then
        self.curl:setopt(setcurlopts)
    end
    if unsetcurlopts then
        for i = 1, #unsetcurlopts do
            self.curl:unsetopt(unsetcurlopts[i])
        end
    end
end

function ZCurl:perform(setcurlopts, unsetcurlopts)
    -- reset response buffers
    self.response = {}
    -- update options
    self:setopts(setcurlopts, unsetcurlopts)
    -- call curl
    local success, err = pcall(self.curl.perform, self.curl)
    if success then return true end
    -- build ready to print error message
    local code = self:getinfo(curl.INFO_RESPONSE_CODE)
    local msg = 'cURL failed: '
    if code ~= nil and code > 0 then msg = msg..('HTTP status %d, '):format(code) end
    return false, msg..err:msg()
end

function ZCurl:close()
    self.curl:close()
end

function ZCurl:getinfo(info)
    return self.curl:getinfo(info)
end

-- Usage: set OPT_WRITEFUNCTION to ZCurl._write_quiet
function ZCurl._write_quiet(x)
    return x and x:len() or 0
end

-- Usage: set OPT_WRITEFUNCTION to <instance>:_write_response_buffer('body')
-- Usage: set OPT_HEADERFUNCTION to <instance>:_write_response_buffer('header')
-- Retrieve data from the <instance>.reponse.<name>
-- Note: response buffers are reset on each perform() calls.
function ZCurl:_write_response_buffer(name)
    local this = self;
    return function (x)
        this.response[name] = (this.response[name] or '')..x
        return x and x:len() or 0
    end
end

return ZCurl
