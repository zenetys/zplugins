-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Author: Julien Thomas
-- Licence: MIT

local util = {}

function util.get_my_hostname()
    local f = io.open('/etc/hostname', 'rb')
    if not f then return nil end
    local h = f:read '*a'
    f:close()
    if not h then return nil end
    local h = h:match('^(%w[%w-]*).*')
    if not h then return nil end
    return h
end

util.hostname = util.get_my_hostname()
util.progname = arg[0]:match('[^/]*$')

-- luaposix

local posix
local posix_load_err

function util.posix_load(is_fatal)
    if not posix and not posix_load_err then -- skip if already failed
        local success, ret = pcall(function() return require('posix') end)
        if success then posix = ret; posix_load_err = nil
        else posix_load_err = ret end
    end
    if not posix and is_fatal then error(posix_load_err) end
    return posix, posix_load_err
end

-- syslog

local syslog_facility
local syslog_ident
local syslog_fd
local syslog_saddr
local syslog_init_err

util.syslog = {}

function util.syslog.init(ident, facility, addr, port)
    if not util.posix_load() then return nil, posix_load_err end
    if syslog_fd then posix.close(syslog_fd); syslog_fd = nil end

    syslog_ident = ident or util.progname
    syslog_facility = facility or 1
    addr = (addr and tostring(addr) or '/dev/log')
    port = port or 514
    if addr:sub(1,1) == '/' then
        syslog_saddr = { family = posix.AF_UNIX, path = addr }
    elseif addr:match('^[%x:]+$') then
        syslog_saddr = { family = posix.AF_INET6, addr = addr, port = port }
    elseif addr:match('^[%d.]+$') then
        syslog_saddr = { family = posix.AF_INET, addr = addr, port = port }
    else
        syslog_saddr = nil
        syslog_fd = false
        syslog_init_err = 'invalid address'
    end

    if syslog_saddr then
        syslog_fd, syslog_init_err = posix.socket(syslog_saddr.family, posix.SOCK_DGRAM, 0)
        if not syslog_fd then syslog_fd = false end
    end
    return syslog_fd, syslog_init_err
end

function util.syslog.log(severity, message)
    if not syslog_fd and (syslog_fd == false or not util.syslog.init()) then
        return nil, syslog_init_err
    end
    local with_hostname = (syslog_saddr.family ~= posix.AF_UNIX and util.hostname)
    message = '<'..((syslog_facility << 3) + severity)..'>'..
        (with_hostname and util.hostname..' ' or '')..
        syslog_ident..': '..tostring(message)
    return posix.sendto(syslog_fd, message, syslog_saddr)
end

local syslog = util.syslog.log
for i,s in ipairs({'emerg','alert','crit','err','warning','notice','info', 'debug'}) do
    util.syslog[s] = function(message) return util.syslog.log(i-1, message) end
end

-- other utilities

function util.perr(fmt, ...)
    io.stderr:write(fmt:format(table.unpack({...}))..'\n')
end

function util.expand(template, vars, lua_explain, modfn)
    if not modfn then modfn = function (x) return x end end
    local ret, err
    function _replace_var(x)
        local k = x:sub(3, -2)
        local kk, alt = k:match('^([^:]+):%-(.*)')
        return vars[kk] or alt or vars[k] or ''
    end
    function _replace_lua(x)
        local k = x:sub(3, -2)
        ret, err = util.lua('return '..k, (lua_explain or 'expand'), nil, '', vars)
        return ret
    end
    local out, count
    for _,s in ipairs({
        -- process ${var} before %{lua}
        { pattern = '$%b{}', fn = _replace_var },
        { pattern = '%%%b{}', fn = _replace_lua },
    }) do
        fn = function (x) return modfn(s.fn(x)) end
        repeat template, count = template:gsub(s.pattern, fn) until count == 0
        if err then return nil, err end
    end
    return template
end

function util.lua(fn_code, explain, expect_type, null_value, env_limited)
    local fn, err = load(fn_code, nil, nil, env_limited)
    explain = explain and ' ('..explain..')' or ''
    if not fn then
        return null_value, 'Compile error'..explain..': '..err
    end
    local success, value = pcall(fn)
    if not success then
        return null_value, 'Eval error'..explain..': '..(value:gsub('.*]:1: ', ''))
    end
    local got_type = type(value)
    if expected_type and got_type ~= expect_type then
        return null_value, 'Type error'..explain..': Expected '..expect_type..', got '..got_type
    end
    return value == nil and null_value or value
end

function util.getpath(object, path, explain, expect_type, null_value)
    return util.lua('return o.'..path, explain, expect_type, null_value, { o = object })
end

-- Code from lua-users.org wiki, "Copy Table" sample code, function
-- deepcopy(), source http://lua-users.org/wiki/CopyTable
function util.deepcopy(orig, --[[ internal ]] _copies)
    _copies = _copies or {}
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        if _copies[orig] then
            copy = _copies[orig]
        else
            copy = {}
            _copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
                copy[util.deepcopy(orig_key, _copies)] = util.deepcopy(orig_value, _copies)
            end
            setmetatable(copy, util.deepcopy(getmetatable(orig), _copies))
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

function _tcopy(is_array, ...)
    local copy = {}
    local args = {...}
    for _,t in ipairs(args) do
        if type(t) == 'table' then
            if is_array then for _,v in ipairs(t) do table.insert(copy, v) end
            else for k,v in pairs(t) do copy[k] = v end end
        end
    end
    return copy
end
function util.acopy(...) return _tcopy(true, table.unpack({...})) end
function util.tcopy(...) return _tcopy(false, table.unpack({...})) end

function util.date2ts(input, want_ms)
    -- assume it is already a timestamp if number
    local ts = tonumber(input)
    if ts then return ts end
    -- date in rfc3339 format
    local y,m,d,H,M,S,ms,rest = input:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)(.*)')
    if y then
        ts = os.time({ year = y, month = m, day = d, hour = H, min = M, sec = S, isdst = false })
        local zs,zh,zm
        if rest == 'Z' then zs,zh,zm = '+',0,0
        else zs,zh,zm = rest:match('^([+-])(%d%d):?(%d+)') end
        if zs then
            local tz_offset = ts - os.time(os.date('!*t', ts))
            if ms ~= '' then ts = tonumber(ts..'.'..ms) end
            return (ts - ((zs == '+' and 1 or -1) * (3600*tonumber(zh) + 60*tonumber(zm))) + tz_offset) *
                (want_ms and 1000 or 1)
        end
    end
    return nil
end

function util.ts2rfc3339(input, is_ms)
    input = tonumber(input)
    if not input then return nil end
    local ms = ''
    if not is_ms and tostring(input):match('%.') then
        input = math.floor(input*1000 + 0.5)
        is_ms = true
    end
    if is_ms then
        ms = ('.%03d'):format(('%.f'):format(math.fmod(input, 1000)))
        input = math.floor(input / 1000)
    end
    return (os.date('%Y-%m-%dT%H:%M:%S'..ms..'%z', input)
                :gsub('(..)$', ':%1'))
end

function util.sh(x)
    return "'"..tostring(x):gsub("'", "'\\''").."'"
end

function util.fbind(fn, ...)
    local base_args = {...}
    return function (...)
        local args = {}
        for _,a in ipairs(base_args) do table.insert(args, a) end
        for _,a in ipairs({...}) do table.insert(args, a) end
        return fn(table.unpack(args))
    end
end

return util
