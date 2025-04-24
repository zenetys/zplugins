-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Initial author: Julien Thomas
-- Licence: MIT

-- This flag has effect on luasnmp >= 1.0.8.
-- On previous versions of luasnmp, an export MIBS= MIBDIRS= is required
-- to avoid loading the mib files, which considerably speed-up execution.
LUA_SNMP_MIBS = false

local cjson = require 'cjson.safe'
local lfs = require 'lfs'

local lc = {}
local lc_meta = {}

-- Get the basename of a path. Note: this function returns an empty
-- string if the given path ends with a slash.
--
-- @param path Input path.
-- @return Basename of the given path.
--
function lc.basename(path)
	return (path:match('([^/]*)$'));
end

-- Index a string, keeping case: replace any non alphanumeric characters
-- by an underscore.
--
-- @param string The string to index.
-- @return Indexed version of the string.
--
function lc.cindex(string)
    return (string:gsub('[^%w_]', '_'))
end

-- Create a directory, without error if existing and make parent
-- directories as needed, like mkdir -p.
--
-- @param dir Directory to create.
-- @return true on success.
-- @return nil and an error message on failure.
--
function lc.mkdir_p(dir)
    if type(dir) ~= 'string' then
        return nil, 'Bad argument'
    end

    local to_create = dir:sub(1, 1) == '/' and '' or '.'
    local ret, err, code

    for i in dir:gmatch('[^/]+') do
        to_create = to_create..'/'..i
        ret, err, code = lfs.mkdir(to_create)
        if not ret then
            -- we could test for errno EEXIST code 17 but getting mkdir()
            -- errno code (3rd returned value) is only available from
            -- luafilesystem 1.7.0
            if code and code ~= 17 then return nil, err end
            -- anyway skip the error if we see a directory
            ret = lfs.attributes(to_create, 'mode')
            if not ret or ret ~= 'directory' then
                return nil, err
            end
        end
    end
    return true
end

-- Load a JSON data file and parse it into a LUA variable;
--
-- @return The parsed JSON data on success.
-- @return nil and an error message on failure.
--
function lc.load_json(file)
    local fd, err = io.open(file, 'rb')
    if not fd then return nil, err end
    local data, err = fd:read '*a'
    fd:close()
    if data == nil then return nil, err end
    return cjson.decode(data)
end

function lc.save_json(data, file)
    local json, fd, ret, err
    json, err = cjson.encode(data)
    if not json then return nil, err end
    fd, err = io.open(file, 'wb')
    if not fd then return nil, err end
    ret, err = fd:write(json, '\n')
    fd:close()
    if not ret then return nil, err end
    return true
end

-- https://stackoverflow.com/a/43286713
function rawtostring(t)
    local m = getmetatable(t)
    if not m then return tostring(t) end
    local f = m.__tostring
    m.__tostring = nil
    local s = tostring(t)
    m.__tostring = f
    return s
end

-- Dump a variable on stderr. The address of printed tables is cached.
-- Two tables with the same address are only printed once, no matter the
-- level of recursion. However the address won't be available for tables
-- with a custom __tostring method.
--
-- @param object The variable to dump.
-- @param text Text to print to explain what is dumped.
-- @param level Internal recursion level, do not use.
-- @param tseen Internal store of dumped table, do not use.
-- @return nil
--
function lc.pdump(object, text, level, tseen)
    if  level == nil then
        if text ~= nil then
            lc.pdebug('#### '..text)
        end
        if type(print_r) == 'function' then
            print_r(object)
            return
        end
        level = 0
        tseen = {}
    end

    local t = type(object)
    local tt = '#'..t

    if t == 'table' then
        local indent, tstr, taddr = string.rep('  ', level), rawtostring(object)
        if tstr:sub(1, 9) == 'table: 0x' then
            taddr = tstr:sub(8)
            io.stderr:write(tt..':'..taddr)
            if tseen[taddr] then
                io.stderr:write(':skip')
            else
                tseen[taddr] = true
                for k,v in pairs(object) do
                    io.stderr:write('\n'..indent..k..': ')
                    lc.pdump(v, nil, level + 1, tseen)
                end
            end
        else -- should not happend using rawtostring()
            io.stderr:write(tt..':\n'..indent..'__tostring: '..tstr)
        end
    elseif t == 'function' then
        local faddr = tostring(object):sub(11)
        io.stderr:write(tt..':'..faddr)
    elseif t == 'string' then
        tt = tt..':'..#object
        io.stderr:write(object..' '..tt)
    else
        io.stderr:write(tostring(object)..' '..tt)
    end

    if level == 0 then
        io.stderr:write('\n')
    end
end

-- Wrapper to pdump() that does nothing if debug is off.
--
-- @param object The variable to dump.
-- @return nil
--
function lc.dump(object, text)
    if lc.opts.debug == true then
        lc.pdump(object, text)
    end
end

-- Print a message on stderr.
--
-- @param message The message to print.
-- @return nil
--
function lc.perr(message)
    io.stderr:write(tostring(message)..'\n')
end

-- Print a message on stderr. The message is prefixed by a debug
-- marker and followed by a newline character.
--
-- @param message The message to print.
-- @return nil
--
function lc.pdebug(message)
    io.stderr:write('DEBUG: '..tostring(message)..'\n')
end

-- Wrapper to pdebug() that does nothing if debug is off.
--
-- @param message The message to print.
-- @return nil
--
function lc.debug(message)
    if lc.opts.debug == true then
        lc.pdebug(message)
    end
end

-- Default exit handler function of the on_exit_handlers array. Other
-- custom exit handlers can be registered by inserting callbacks or
-- function references to the on_exit_handlers array.
--
-- @return false to break execution of the exit handlers sequence.
--      In that case program still terminates.
--
function default_on_exit()
    local output = ''

    if lc.checkname and #lc.checkname > 0 then
        output = output..lc.checkname..' '
    end
    output = output..lc.status_text[lc.exit_code]..': '..
        (lc.exit_message and lc.exit_message or 'No output defined')
    print(output)

    lc.dump(lc.opts, 'Dump opts')
end

-- Finalizer method that runs registered custom exit handlers in sequence.
-- If an exit handler returns false, the remaining ones are not executed.
--
-- @return nil, program terminates.
--
function lc_meta.__gc()
    if lc._gc_has_run then return end
    lc._gc_has_run = true

    lc.debug('Run exit handlers...')
    if lc.exit_code == nil then lc.exit_code = 0 end
    for k,v in ipairs(lc.on_exit_handlers) do
        if v() == false then break end
    end

    os.exit(lc.exit_code, true)
end

-- Terminates the program with custom exit code and message.
-- On exit handlers are executed.
--
-- @param code Exit status code.
-- @param code Exit messgae.
-- @return nil, program terminates.
--
function lc.die(code, message)
    lc.exit_code = code
    lc.exit_message = message
    lc_meta.__gc()
end

-- Convenience wrappers to lc.die()
function lc.die_unkn(...) lc.die(lc.UNKNOWN, ...) end
function lc.die_crit(...) lc.die(lc.CRITICAL, ...) end
function lc.die_warn(...) lc.die(lc.WARNING, ...) end
function lc.die_ok(...) lc.die(lc.OK, ...) end

-- Compute the path of the cache directory and create it. On failure, this
-- function make the program die with an UNKNOWN status.
--
-- @return true on success, program dies on failure.
--
function lc.init_cache()
    if not lc.opts.cachebase then
        lc.opts.cachebase = os.getenv('CACHEBASE')
        if not lc.opts.cachebase then
            lc.opts.cachebase = os.getenv('HOME')
            if not lc.opts.cachebase then
                lc.opts.cachebase = '/tmp'
            end
            lc.opts.cachebase = lc.opts.cachebase..'/.libcheck'
        end
    end

    if not lc.opts.cacheid then
        lc.opts.cacheid = lc.cindex(table.concat(arg, '_'))
    end

    lc.cachedir = lc.opts.cachebase ..
        '/'..lc.progname ..
        '/'..lc.opts.cacheid

    local ret, err = lc.mkdir_p(lc.cachedir)
    if ret then return true end
    lc.perr('init_cache: '..err)
    lc.die(lc.UNKNOWN, 'Cache init failed - '..err)
end

-- Load a JSON file from the cache directory. The parsed data must be
-- a table object to be valid. On failure, this function make the program
-- die with an UNKNOWN status.
--
-- @return Parsed table object on success, an empty table if the cache
--      file does not exit, program dies on failure.
--
function lc.load_cache(name)
    local ret, err_load, err_rm
    if not name then name = 'CACHE' end
    if not lc.cachedir then lc.init_cache() end
    local file = lc.cachedir..'/'..name
    if not lfs.attributes(file, 'mode') then return {} end
    ret, err_load = lc.load_json(file)
    if type(ret) == 'table' then
        return ret
    elseif ret ~= nil then
        err_load = 'Invalid data, table object required'
    end
    lc.perr('load_cache: '..name..': '..err_load)
    ret, err_rm = os.remove(file)
    if ret then
        lc.perr('load_cache: '..name..': File removed')
    else
        lc.perr('load_cache: '..name..': File remove failed')
        lc.perr('load_cache: '..name..': '..err_rm)
    end
    lc.die(lc.UNKNOWN, 'Cache load failed - '..name..': '..err_load)
end

-- Save data to a JSON file in the cache directory. The data to save must
-- be a table object. On failure, this function make the program die with
-- an UNKNOWN status.
--
-- @return nil, program dies on failure.
--
function lc.save_cache(data, name)
    local file, ret, err
    if not name then name = 'CACHE' end
    if type(data) ~= 'table' then
        err = 'Invalid data, table object required'
        lc.perr('save_cache: '..name..': '..err)
        lc.die(lc.UNKNOWN, 'Cache save failed - '..name..': '..err)
    end
    if not lc.cachedir then lc.init_cache() end
    file = lc.cachedir..'/'..name
    ret, err = lc.save_json(data, file)
    if not ret then
        lc.perr('save_cache: '..name..': '..err)
        lc.die(lc.UNKNOWN, 'Cache save failed - '..name..': '..err)
    end
end

-- Print usage help message on stdout and exit.
--
-- @return nil, program terminates.
--
function lc.exit_usage()
    print('Monitoring plugin '..lc.progname)
    if lc.shortdescr then print(lc.shortdescr) end
    print('\nAvailable options:')
    for k,v in pairs(lc.optsdef) do
        local left, flags = '', ''
        if v.short then
            left = left..'-'..v.short
        end
        if v.long then
            if #left > 0 then left = left..', ' end
            left = left..'--'..v.long
        end
        flags = flags..(v.arg ~= false and 'V' or ' ')
        flags = flags..(v.required and 'R' or ' ')
        print(string.format('  %-27s %-5s %s', left, flags, v.help))
    end
    print('\nV: options requires a value argument\nR: options is mandatory')
    if lc.usage_notes then print('\n'..lc.usage_notes) end
    os.exit(0, false)
end

function lc.setter_opt_snmp_protocol(opt, value)
    if value == '1' then return snmp.SNMPv1
    elseif value == '2' or value:lower() == '2c' then return snmp.SNMPv2c
    elseif value == '3' then return snmp.SNMPv3 end
    return nil
end

function lc.setter_opt_number(opt, value)
    return tonumber(value)
end

function lc.setter_opt_percent_as_number(opt, value)
    if string.sub(value, -1) == '%' then value = string.sub(value, 1, -2) end
    return tonumber(value)
end

function lc.setter_opt_boolean(opt, value)
    if value == '' or value == '0' then return false end
    return true
end

function lc.setter_opt_iboolean(opt, value)
    if value == '' or value == '0' then return 0 end
    return 1
end

function lc.setter_opt_array(opt, value)
    if type(lc.opts[opt.key]) ~= 'table' then lc.opts[opt.key] = {} end
    -- value:gmatch('[^,]*') wont work on lua < 5.3.3
    for i in (value..','):gmatch('([^,]*),') do table.insert(lc.opts[opt.key], i) end
    return lc.opts[opt.key]
end

function lc.setter_opt_kv(opt, value)
    if type(lc.opts[opt.key]) ~= 'table' then lc.opts[opt.key] = {} end
    -- value:gmatch('[^,]*') wont work on lua < 5.3.3
    for i in (value..','):gmatch('([^,]*),') do
        -- key is kv[3], value is kv[4]
        local kv = { i:find('([%w_%-%.]+)=(.*)') }
        if kv[1] ~= nil then lc.opts[opt.key][kv[3]] = kv[4] end
    end
    return lc.opts[opt.key]
end

function lc.init_type_snmp()
    lc.snmp = require 'snmp'

    table.insert(lc.optsdef,
        { short = 'H', long = 'hostname', required = true,
          help = 'Hostname or IP address' })
    table.insert(lc.optsdef,
        { short = 'p', long = 'port',
          call = lc.setter_opt_number,
          help = 'SNMP port number' })
    table.insert(lc.optsdef,
        { short = 'P', long = 'protocol',
          call = lc.setter_opt_snmp_protocol,
          help = 'SNMP protocol version: 1|2c|3' })
    table.insert(lc.optsdef,
        { short = 'C', long = 'community',
          help = 'SNMP community' })
    table.insert(lc.optsdef,
        { short = 'e', long = 'retries',
          call = lc.setter_opt_number,
          help = 'Number of retries in SNMP requests' })
    table.insert(lc.optsdef,
        { short = 't', long = 'timeout',
          call = lc.setter_opt_number,
          help = 'Seconds before connection times out' })
    table.insert(lc.optsdef,
        { short = 'U', long = 'secname',
          help = 'SNMP v3 username' })
    table.insert(lc.optsdef,
        { short = 'L', long = 'seclevel',
          help = 'SNMP v3 security level' })
    table.insert(lc.optsdef,
        { short = 'a', long = 'authproto',
          help = 'SNMP v3 authentification protocol: MD5|SHA' })
    table.insert(lc.optsdef,
        { short = 'A', long = 'authpassword',
          help = 'SNMP v3 authentification password' })
    table.insert(lc.optsdef,
        { short = 'x', long = 'privproto',
          help = 'SNMP v3 privacy protocol: MD5|SHA' })
    table.insert(lc.optsdef,
        { short = 'X', long = 'privpassword',
          help = 'SNMP v3 privacy password' })
end

-- Parse command line arguments against the optsdef array and put results
-- in the opts table. On failure, this function make the program die with
-- an UNKNOWN status.
--
-- @return nil, parsed options are set in the opts table, program
--      dies on failure.
--
function lc.init_opts()
    if lc.progtype == 'snmp' then lc.init_type_snmp() end

    table.insert(lc.optsdef,
        { long = 'cachebase',
          help = 'Set the root directory of the cache' })
    table.insert(lc.optsdef,
        { short = 'I', long = 'cacheid',
          call = function (o,v) return (v:gsub('[^%w/_]', '_')) end,
          help = 'Set the ID of the cache' })
    table.insert(lc.optsdef,
        { short = 'h', long = 'help', arg = false,
          call = lc.exit_usage,
          help = 'Display this help' })
    table.insert(lc.optsdef,
        { short = 'D', long = 'debug', arg = false,
          help = 'Enable debug' })

    local arg2opt = {}
    local i = 1

    for k, v in ipairs(lc.optsdef) do
        for _,o in ipairs({ 'long', 'short' }) do
            if v[o] then
                arg2opt[v[o]] = v
                if not v.key then v.key = lc.cindex(v[o]) end
            end
        end
    end

    while i <= #arg do
        local optarg = arg[i]
        local optkey = optarg:gsub('^-*', '')
        local optdef, optvalue, optignore

        if optarg == '--' then i = i + 1; break
        elseif arg2opt[optkey] then optdef = arg2opt[optkey]
        else lc.die(lc.UNKNOWN, 'Invalid option '..optarg) end

        -- arg enabled by default
        if optdef.arg ~= false then
            i = i + 1
            if arg[i] == '$' or (arg[i] == '' and optdef.emptynil ~= false) then
                optignore = true
            else
                optvalue = arg[i]
            end
        else
            optvalue = true
        end
        if not optignore then
            if optdef.call then optvalue = optdef.call(optdef, optvalue) end
            if not optvalue then lc.die(lc.UNKNOWN, 'Invalid value for option '..optarg) end
            lc.opts[optdef.key] = optvalue
        end
        i = i + 1
    end

    for k, v in ipairs(lc.optsdef) do
        if v.required and lc.opts[v.key] == nil then
            local optmsg = nil
            if v.short then optmsg = '-'..v.short end
            if v.long then optmsg = (optmsg and optmsg..', ' or '')..'--'..v.long end
            lc.die(lc.UNKNOWN, 'Missing value for option '..optmsg)
        end
    end
end

function lc.snmpopen(local_opts)
    local opts = { peer = lc.opts.hostname }
    if lc.opts.port then opts.port = lc.opts.port end
    if lc.opts.protocol then opts.version = lc.opts.protocol end
    if lc.opts.community then opts.community = lc.opts.community end
    if lc.opts.retries then opts.retries = lc.opts.retries end
    if lc.opts.timeout then opts.timeout = lc.opts.timeout end
    if lc.opts.secname then opts.user = lc.opts.secname end
    if lc.opts.seclevel then opts.securityLevel = lc.opts.seclevel end
    if lc.opts.authproto then opts.authType = lc.opts.authproto end
    if lc.opts.authpassword then opts.autPassphrase = lc.opts.authpassword end
    if lc.opts.privproto then opts.privType = lc.opts.privproto end
    if lc.opts.privpassword then opts.privPassphrase = lc.opts.privpassword end
    if local_opts then
        for k, v in pairs(local_opts) do opts[k] = v end
    end

    local sess, err = snmp.open(opts);
    if not sess then lc.die(lc.UNKNOWN, 'SNMP session failed - '..err) end
    table.insert(lc.on_exit_handlers, 1, function () sess:close() end)
    return sess
end

function lc.snmpwalk(sess, oid)
    lc.debug('snmpwalk: oid '..oid)
    local data, err = sess:walk(oid);

    if not data then
        err = 'snmpwalk: '..err
        lc.debug(err)
        return nil, err
    end

    lc.dump(data, 'Dump snmpwalk result')
    for k, v in ipairs(data) do
        if not v.value then
            err = 'snmpwalk: no value at '..v.oid
            lc.debug(err)
            return nil, err
        end
    end

    return data
end

function lc.snmpbulkwalk(sess, root_oid, options)
    local out, running = {}, true
    local root_oid_len, oid, data, err, errindex

    if not root_oid then root_oid = '1' end
    if not options then options = {} end
    if options.batch_len == nil then options.batch_len = 20 end

    lc.debug('snmpbulkwalk: oid '..root_oid)

    root_oid_len = snmp.mib.oidlen(root_oid)
    if not root_oid_len then
        err = 'snmpbulkwalk: cannot compute oid length'
        lc.debug(err)
        return nil, err
    end

    oid = root_oid
    while running do
        lc.debug('snmpbulkwalk: getbulk 0, '..options.batch_len..',  '..oid)
        data, err, erri = sess:getbulk(0, options.batch_len, { oid })
        if not data or err then
            err = 'snmpbulkwalk: '..err
            lc.debug(err)
            return nil, err
        end
        if erri then
            err = 'snmpbulkwalk: pdu error at '..data[erri].oid
            lc.debug(err)
            return nil, err
        end

        for k, v in ipairs(data) do
            -- break if we passed the requested tree
            if snmp.mib.oidlen(v.oid) < root_oid_len or
                v.type == snmp.ENDOFMIBVIEW or
                not string.find(v.oid, root_oid)
            then
                running = false
                break
            end

            -- check if oid is increasing
            if not options.no_check_increase and
               snmp.mib.oidcompare(oid, v.oid) >= 0 then
                err = 'snmpbulkwalk: oid not increasing at '..v.oid
                lc.debug(err)
                return nil, err
            end
            -- check for a value
            if not v.value then
                err = 'snmpbulkwalk: no value at '..v.oid
                lc.debug(err)
                return nil, err
            end

            oid = v.oid
            table.insert(out, v)
            if options.on_value then options.on_value(v) end
        end
    end

    lc.dump(out, 'Dump snmpbulkwalk result')
    if #out == 0 then
        err = 'snmpbulkwalk: no data'
        lc.debug(err)
        return nil, err
    end

    return out
end

-- Note type oids vs type allow_fail
function lc.snmpget(sess, oids, allow_fail)
    if type(oids) == 'string'
    then lc.debug('snmpget: oid '..oids)
    else lc.debug('snmpget: oids '..table.concat(oids, ' ')) end

    local data, err = sess:get(oids);
    if not data then
        err = 'snmpget: '..err
        lc.debug(err)
        return nil, err
    end

    lc.dump(data, 'Dump snmpget result')
    if type(oids) == 'string' then
        if not data.value and allow_fail ~= true then
            err = 'snmpget: no value at '..data.oid
            lc.debug(err)
            return nil, err
        end
    else
        for k, v in ipairs(data) do
            if not v.value and (not allow_fail or not allow_fail[k]) then
                err = 'snmpget: no value at '..v.oid
                lc.debug(err)
                return nil, err
            end
        end
    end

    return data
end

function lc.oid2string(oid, first_is_length)
    local out, is_first, i = '', true
    for i in oid:gmatch('[^.]+') do
        if not is_first or not first_is_length then
            out = out..string.format('%c', i)
        end
        is_first = false
    end
    return out
end

function lc.worsen_status(current_status, other_status, _reverse)
    local m = _reverse and -1 or 1
    if lc.status_prio[other_status] * m >
       lc.status_prio[current_status] * m then
        return other_status
    end
    return current_status
end

function lc.improve_status(current_status, other_status)
    return lc.worsen_status(current_status, other_status, true)
end

lc.opts = {
    debug = (os.getenv('DEBUG') == '1'),
    cachebase = nil,
    cacheid = nil
}

lc.OK = 0
lc.WARNING = 1
lc.CRITICAL = 2
lc.UNKNOWN = 3

lc.status_text = {
    [lc.OK] = 'OK',
    [lc.WARNING] = 'WARNING',
    [lc.CRITICAL] = 'CRITICAL',
    [lc.UNKNOWN] = 'UNKNOWN'
}

lc.status_prio = {
    [lc.OK] = 0,
    [lc.WARNING] = 1,
    [lc.CRITICAL] = 3,
    [lc.UNKNOWN] = 2
}

lc.progname = lc.basename(arg[0])
lc.checkname = 'CHECK'
lc.shortdescr = nil
lc.optsdef = {}
lc.exit_code = nil
lc.exit_message = nil
lc.on_exit_handlers = { default_on_exit }

lc.cjson = cjson
lc.lfs = lfs
lc.snmp = nil

setmetatable(lc, lc_meta)

return lc
