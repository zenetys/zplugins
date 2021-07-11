-- Copyright Benoit Dolez < bdolez @ ant-computing.com >
-- Copyright Zenetys < bdolez @ zenetys.com >
-- Initial author: Benoit Dolez
-- Licence: MIT

-- nagios-plugins utils functions to respect :
-- https://nagios-plugins.org/doc/guidelines.html
-- (extract from guidelines)
--
-- performance data:
-- format: 'label'=value[UOM];[warn];[crit];[min];[max][<space>...]
-- 1.  space separated list of label/value pairs
-- 2.  label can contain any characters except the equals sign or
--     single quote (')
-- 3.  the single quotes for the label are optional. Required if spaces
--     are in the label
-- 4.  label length is arbitrary, but ideally the first 19 characters are
--     unique (due to a limitation in RRD). Be aware of a limitation in
--     the amount of data that NRPE returns to Nagios
-- 5.  to specify a quote character, use two single quotes
-- 6.  warn, crit, min or max may be null (for example, if the threshold is
--     not defined or min and max do not apply). Trailing unfilled semicolons
--     can be dropped
-- 7.  min and max are not required if UOM=%
-- 8.  value, min and max in class [-0-9.]. Must all be the same UOM. value
--     may be a literal "U" instead, this would indicate that the actual value
--     couldn't be determined
-- 9.  warn and crit are in the range format (see the Section called Threshold
--     and Ranges). Must be the same UOM
-- 10. UOM (unit of measurement) is one of:
--     1. no unit specified - assume a number (int or float) of things (eg,
--        users, processes, load averages)
--     2. s - seconds (also us, ms)
--     3. % - percentage
--     4. B - bytes (also KB, MB, TB)
--     5. c - a continous counter (such as bytes transmitted on an interface)
--
-- It is up to third party programs to convert the Nagios Plugins performance
-- data into graphs.

local LP = {
    STATE_OK = 0,
    STATE_WARNING = 1,
    STATE_CRITICAL = 2,
    STATE_UNKNOWN = 3,
    STATE_DEPENDENT = 4,
    state = {
        [0] = "OK",
        [1] = "WARNING",
        [2] = "CRITICAL",
        [3] = "UNKNOWN",
        [4] = "DEPENDENT",
    },
}

local STATE_ORDER = { [0] = 0, [1] = 2, [2] = 4, [3] = 3, [4] = 1 }
local STATE_LIST = {
    LP.STATE_CRITICAL,
    LP.STATE_UNKNOWN,
    LP.STATE_DEPENDENT,
    LP.STATE_WARNING,
    LP.STATE_OK,
}

local UOM_PATTERN = "([0-9.]+)([s%%ckmgtpKMGTPBbi]*)"

local UOM_TMULT = {
    [""]   = 1,
    ["c"]  = 1,
    ["k"]  = 1000,
    ["K"]  = 1000,
    ["M"]  = 1000*1000,
    ["G"]  = 1000*1000*1000,
    ["ki"] = 1024,
    ["Bi"] = 1,
    ["Ki"] = 1024,
    ["Mi"] = 1024*1024,
    ["Gi"] = 1024*1024*1024,
    ["b"]  = 1,
    ["B"]  = 1,
    ["kB"] = 1024,
    ["KB"] = 1024,
    ["MB"] = 1024*1024,
    ["GB"] = 1024*1024*1024,
    ["%"]  = 0.01,
    ["s"]  = 1,
    ["ms"] = 0.001,
    ["us"] = 0.000001,
}
local UOM_UNIT = {
    [""] = "",
    ["B"] = "B",
    ["Bi"] = "Bi",
    ["auto"] = "",
    ["si"] = "",
    ["iec"] = "B",
    ["iec-i"] = "Bi",
    ["o"] = "o",
    ["b"] = "b",
    ["be"] = "be",
}
local UOM_RMULT = { [0] = "", "k", "M", "G", "T", "P" }
local UOM_BASE = {
    ["iec"] = 1024,
    ["iec-i"] = 1024,
    ["B"] = 1024,
    ["Bi"] = 1024,
    ["o"] = 1024,
    ["be"] = 1024,
}

-- "1234.56K" => 1234560
-- "1.1.2" => nil
-- 123456.789 => 123456.789
-- "1.2K03" => nil
-- "1.2Ki" => nil

-- coreutils command numfmt
-- https://www.gnu.org/software/coreutils/manual/coreutils.html#numfmt-invocation
function LP.numfmt(n, to, from, base, max)
    if (n == nil) then
        return nil
    end

    if (base == nil) then
        base = 1
    end

    if (from == nil or from == "auto") then
        if (type(n) ~= "number" and type(n) ~= "string") then
            return nil -- error
        elseif (type(n) == "string") then
            -- check for number
            local t = tonumber(n)
            if (t ~= nil) then
                n = t
            else
                local t, uom, percent = LP.numbase(n)

                if (t and uom and percent and max) then
                    -- transform percent to number
                    n = (t*uom*max)
                elseif (t and uom) then
                    n = (t*uom)
                else
                    return nil -- error
                end
            end
        -- else type(n) == number
        end
    end

    if (to == nil or to == "none") then
        return n / base;
    end

    local function fp(v) -- format-precision
        if (v-math.floor(v) == 0) then return "%.f" else return "%.2f" end
    end

    if (to == "%") then
        return string.format(fp(n*100) .. "%%", n*100)
    elseif (to == "c") then
        return string.format("%dc", n)
    elseif (to == "s") then
        if (n > 1) then
            return string.format("%ds", n)
        elseif (n > 0.001) then
            return string.format("%dms", n*1000)
        else
            return string.format("%dus", n*1000*1000)
        end
    elseif (to == "hms") then -- hour/minuts/seconds
        -- FIXME
    elseif (UOM_UNIT[to] ~= nil) then
        local base = (UOM_BASE[to] or 1000)
        local u = 0 ; while n > base do n=n/base ; u=u+1 ; end
        return string.format(fp(n)..UOM_RMULT[u]..UOM_UNIT[to], n)
    else
        return nil -- error
    end

    return n
end

function LP.numbase(n)
    if (type(n) == nil) then
        return nil;
    elseif (type(n) == "number") then
        return 1;
    elseif (type(n) == "string") then
        -- match UOM
        local a = { string.find(n, UOM_PATTERN) }
        -- all the string need to match
        if (a[1] ~= 1 or a[2] ~= string.len(n)) then
            return nil -- error
        end

        -- convert and check for number and UOM
        return tonumber(a[3]), UOM_TMULT[a[4]], (a[4] == '%')
    else
        return nil
    end
end

-- check_range takes a value and a range string, returning successfully if an
-- alert should be raised based on the range.  Range values are inclusive.
-- Values may be integers or floats.
--
-- threshold and ranges :
-- format: [@]start:end
-- 1.  start ≤ end
-- 2.  start and ":" is not required if start=0
-- 3.  if range is of format "start:" and end is not specified, assume end is
--     infinity
-- 4.  to specify negative infinity, use "~"
-- 5.  alert is raised if metric is outside start and end range(inclusive of
--     endpoints)
-- 6.  if range starts with "@", then alert if inside this range(inclusive of
--     endpoints)
--
--   5 1    # yes
--   6 :1   # yes
--   4 1:2  # yes
--   4 @1:4 # yes
--   5 @~:5 # yes
--  -1 @~:3 # yes
--   4 @1   # no
--   8 @:1  # no
--   4 1:   # no
--   3 1:~  # no
--   5 1:8  # no
--   3 1:3  # no
--   6 @1:5 # no
--  -6 @5:  # no

function LP.check_range(v, range, max)
    if (v == nil or range == nil) then
        return nil -- error
    end

    local a = { string.find(range, "(@?)([^:]*)(:?)([^:]*)") }
    if (a[1] ~= 1 or a[2] ~= string.len(range)) then
        return nil -- error
    end

    -- compute value and range
    local v = LP.numfmt(v)
    local max = LP.numfmt(max)
    local st, en

    if (a[5] == ":") then
        st = ((a[4] == "") and 0 or LP.numfmt(a[4], nil, nil, nil, max))
        en = LP.numfmt(a[6], nil, nil, nil, max)
    else
        st = 0
        en = LP.numfmt(a[4], nil, nil, nil, max)
    end

    if (st ~= nil and en ~= nil and en < st) then
        return nil -- error
    end

    -- DEBUG
    -- print(string.format("%s%s in (%s,%s)",
    --       (a[3] == "@" and "inc " or ""), v, st or "~", en or "~"))

    -- check value into range
    if (a[3] == "@") then
        return ((st == nil or st <= v) and (en == nil or v <= en))
    else
        return ((st ~= nil and v < st) or  (en ~= nil and en < v))
    end
end

function LP.compute_perfdata(perfdata)
    local state = LP.STATE_OK
    -- compute status from perfdata array
    for _, p in pairs(perfdata) do
        if (p.value == nil) then
            p.state = LP.STATE_UNKNOWN
        elseif (p.critical and LP.check_range(p.value, p.critical, p.max)) then
            p.state = LP.STATE_CRITICAL
        elseif (p.warning and LP.check_range(p.value, p.warning, p.max)) then
            p.state = LP.STATE_WARNING
        else
            p.state = LP.STATE_OK
        end

        if (STATE_ORDER[p.state] > STATE_ORDER[state]) then
            state = p.state
        end
    end
    return state
end

function LP.format_perfdata(perfdata)
    -- build perfdata from computed array
    local s = ""
    for _, p in pairs(perfdata) do
        local v = LP.numfmt(p.value, p.uom)
        local max = LP.numfmt(p.max)
        local n, b = LP.numbase(v)

        s = s .. "'" .. p.name .. "'=" .. (v or "U") .. ";"
        s = s .. (LP.numfmt(p.warning, nil, nil, b, max) or "") .. ";"
        s = s .. (LP.numfmt(p.critical, nil, nil, b, max) or "") .. ";"
        s = s .. (LP.numfmt(p.min, nil, nil, b) or "") .. ";"
        s = s .. (LP.numfmt(p.max, nil, nil, b) or "") .. " "
    end
    return s
end

function LP.format_output(perfdata)
    -- build auto output from computed array
    local s = ""
    local msg = {}

    for k,v in pairs(STATE_LIST) do
        msg[v] = {}
    end

    for _, p in pairs(perfdata) do
        local v = LP.numfmt(p.value, p.uom)
        local max = LP.numfmt(p.max)

        local m = p.name .. ": " .. (v or 'nil')
        if (max) then
            m = m .. "/" .. LP.numfmt(p.max, p.uom)
        end
        if (p.state ~= LP.STATE_OK) then
            m = "**" .. m .. "**"
        end
        if (p.state == nil) then
            table.insert(msg[LP.STATE_UNKNOWN], m)
        else
            table.insert(msg[p.state], m)
        end
    end

    local output = {}
    for k,v in pairs(STATE_LIST)  do
        if (#msg[v] > 0) then
            table.insert(output, table.concat(msg[v], ", "))
        end
    end

    return table.concat(output, ", ");
end

return LP

--[[
perfdata = {
  {
    name = "test1",
    value = 12,
    warning = "12",
    critical = "16",
    uom = "",
    min = 0,
    max = 100,
  },
  {
    name = "test2",
    value = 8000,
    warning = "23%",
    critical = "79.999%",
    uom = "B",
    min = 0,
    max = "10000",
  },
  {
    name = "test3",
    value = 18,
    warning = "10",
    critical = "15",
    uom = ""
  },
}

state = LP.compute_perfdata(perfdata)
print(LP.format_perfdata(perfdata))
print(LP.format_output(perfdata))
--]]
