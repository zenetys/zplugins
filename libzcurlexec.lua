-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Author: Julien Thomas
-- Licence: MIT

local lu = require 'libutil'
local ZCurl = require 'libzcurl'

local ZCurlExec = {}
ZCurlExec.__index = ZCurlExec
-- inherit ZCurl
setmetatable(ZCurlExec, ZCurl)
-- advertise to ZCurl.new_abstract()
ZCurl.register_abstract(ZCurlExec, function(...)
    local args = {...}
    return type(args[1]) == 'table' and args[1].zcurl_exec_bin
end)

function ZCurlExec.new(curlopts)
    local instance = {}
    setmetatable(instance, ZCurlExec)

    instance.default_curlopts = curlopts
    instance.current_curlopts = nil
    instance.response = nil
    instance.info = nil
    instance:resetopts()
    return instance
end

function ZCurlExec:resetopts()
    self.current_curlopts = {}
    return self:setopts(self.default_curlopts)
end

function ZCurlExec:setopts(setcurlopts, unsetcurlopts)
    if setcurlopts then
        for o,v in pairs(setcurlopts) do
            if ZCurl.curlopts_function[o] then v = lu.fbind(v, self) end
            self.current_curlopts[o] = v
        end
    end
    if unsetcurlopts then
        for _,o in ipairs(unsetcurlopts) do
            self.current_curlopts[o] = nil
        end
    end
end

function build_cmd(self)
    local bin, arg, fmt, cmd = '', '', (self:o('zcurl_exec_fmt') or '${bin} ${arg}'), ''

    if self:o('timeout') then bin = bin..' timeout '..lu.sh(('%d'):format(self:o('timeout')*2)) end
    for _,v in ipairs(self:o('zcurl_exec_bin') or { 'curl' }) do bin = bin..' '..lu.sh(v) end

    arg = arg..' --silent --show-error --url '..lu.sh(self:o('url'))
    if self:o('followlocation') then arg = arg..' --location' end
    if self:o('followlocation') then arg = arg..' --location' end
    if self:o('ssl_verifypeer') == 0 and self:o('ssl_verifyhost') == 0 then arg = arg..' --insecure' end
    if self:o('postfields') then arg = arg..' --data-binary @-' end
    if self:o('customrequest') then arg = arg..' --request '..lu.sh(self:o('customrequest')) end
    if self:o('cookiefile') then arg = arg..' --cookie '..lu.sh(self:o('cookiefile')) end
    if self:o('cookiejar') then arg = arg..' --cookie-jar '..lu.sh(self:o('cookiejar')) end
    if self:o('verbose') then arg = arg..' --verbose' end
    if self:o('connecttimeout') then arg = arg..' --connect-timeout '..lu.sh(self:o('connecttimeout')) end
    if self:o('timeout') then arg = arg..' --max-time '..lu.sh(self:o('timeout')) end
    if self:o('username') and self:o('password') then
        arg = arg..' --user '..lu.sh(self:o('username'))..':'..lu.sh(self:o('password'))
    end
    if self:o('netrc') and self:o('netrc') > 0 then
        arg = arg..' --netrc'
        if self:o('netrc') == 1 then arg = arg..' --netrc-optional' end
    end
    if self:o('netrc_file') then arg = arg..' --netrc-file '..lu.sh(self:o('netrc_file')) end
    if self:o('failonerror') then arg = arg..' --fail' end
    if self:o('httpheader') then for _,h in ipairs(self:o('httpheader')) do arg = arg..' --header '..lu.sh(h) end end
    if self:o('zcurl_exec_arg') then for _,v in ipairs(self:o('zcurl_exec_arg')) do arg = arg..' '..lu.sh(v) end end

    if self:o('postfields') then cmd = cmd..' echo '..lu.sh(self:o('postfields'))..' |' end
    cmd = cmd..lu.expand(fmt, { bin = bin, arg = arg, sh = lu.sh }, 'zcurl exec format')
    return cmd
end

function ZCurlExec:perform(setcurlopts, unsetcurlopts)
    -- reset response and info storage
    self.response = {}
    self.info = {}
    -- update options
    self:setopts(setcurlopts, unsetcurlopts)
    -- run request
    local cmd = build_cmd(self)
    if self:o('verbose') then io.stderr:write('ZCurlExec: '..cmd..'\n') end
    local pipe = io.popen(cmd, 'r')
    local output = pipe:read('*all')
    local rc = { pipe:close() }
    if rc[3] ~= 0 then
        return nil, ((output and #output > 0) and (output:gsub('\n.*$', ''))
            or 'Exec failed status '..rc[3])
    end
    local wrfn = self:o('writefunction')
    if wrfn then
        if type(wrfn) ~= 'function' then
            return nil, 'unsupported writefunction type'
        end
        pcall(wrfn, output)
    end
    return self
end

function ZCurlExec:close()
    -- not supported
end

function ZCurlExec:getinfo(info)
    -- not supported
end

return ZCurlExec
