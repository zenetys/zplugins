-- Usage examples:
-- check_rest_addon -a check_rest_addon.rdap_expiration.inc.lua -d zenetys.com -w 15: -c 7:
-- check_rest_addon -a check_rest_addon.rdap_expiration.inc.lua -d logvault.io -w 15: -c 7: \
--     -B https://rdap.gandi.net

local arg = {...}
if arg[1] == 'init' then
    lc.checkname = 'RDAP'
    lc.opts.follow = true
    lc.opts.perfdata_time = 0
    table.insert(lc.optsdef, { short = 'i', long = 'domain',
        help = 'Domain to check', required = true })
    return true
end

local tz = require('tz')

if not lc.opts.baseurl then
    -- per-TLD radap servers: https://data.iana.org/rdap/dns.json
    lc.opts.baseurl = 'https://rdap-bootstrap.arin.net/bootstrap'
end

query(ctx.zcurl, { url = build_url('/domain/'..lc.opts.domain) }, 'json')
local data = ctx.zcurl.response.body_decoded
if type(data) ~= 'table' then lc.die_unkn('Invalid data, not a table (.)') end
if type(data.events) ~= 'table' then lc.die_unkn('Invalid data, not a table (.events)') end

local exp_date = nil
for _,e in ipairs(data.events) do
    if e.eventAction:lower():match('expiration') then
        exp_date = e.eventDate
        break
    end
end

if not exp_date then lc.die_unkn('Could not find expiration date') end
local _, exp_cap = lu.mmatch(exp_date, {
    '^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z$',
    '^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(%.%d+)Z$',
})
if #exp_cap == 0 then lc.die_unkn('Invalid expiration date format') end
local exp_ts = tz.time({ year = tonumber(exp_cap[1]), month = tonumber(exp_cap[2]),
    day = tonumber(exp_cap[3]), hour = tonumber(exp_cap[4]), min = tonumber(exp_cap[5]),
    sec = tonumber(exp_cap[6]) }, 'UTC')

table.insert(ctx.perfdata, {
    foutput = function (p)
        local e = (p.state > 0 or p.value < 0) and '**' or ''
        local out = lc.opts.domain..' '
        if p.value < 0 then out = out..e..'expired'..e..' on '..exp_date
        else out = out..'has '..e..math.floor(p.value)..'d left'..e..', expires '..exp_date end
        return out
    end,
    name = 'days_to_expiration',
    value = (exp_ts-os.time())/86400,
    uom = '',
    warning = lc.opts.warning[1],
    critical = lc.opts.critical[1],
})
