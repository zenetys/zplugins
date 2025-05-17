local arg = {...}
if arg[1] == 'init' then
    lc.checkname = ''
    default_parameter['p_filter'] = 'TRUE' -- es|ql
    default_parameter['p_period'] = '10 min' -- es|ql
    return true
end

local query = { query = [[
FROM logs-rsyslog.pstats-zlc
    | WHERE @timestamp > NOW() - ${p_period} AND @timestamp <= NOW() AND
        ${p_filter} AND
        ((rsyslog.origin == "core.queue" AND rsyslog.discarded_total > 0) OR
         (rsyslog.origin == "imjournal" AND rsyslog.discarded > 0))
    | STATS discarded = COALESCE(SUM(rsyslog.discarded_full),0) +
            COALESCE(SUM(rsyslog.discarded),0)
        BY host.name, rsyslog.origin, rsyslog.name
    | SORT discarded DESC
    | LIMIT 1000
]] }
lc.pdebug('Fetching data...')
local data, err = esh.es1:esql(query, lc.opts.parameter)
if not data then lc.die(lc.UNKNOWN, 'Query failed: '..err) end
lc.pdebug('Query took (ms): '..tostring(data.took))
if data.is_partial then lc.die(lc.UNKNOWN, 'Query returned partial data') end
lc.dump(data, 'Dump data')

table.insert(perfdata, {
    name = 'rsyslog.discarded',
    label = 'rsyslog.discarded on last '..lc.opts.parameter.p_period,
    value = 0,
    uom = '',
    warning = lc.opts.warning and lc.opts.warning[1],
    critical = lc.opts.critical and lc.opts.critical[1],
})

output_options.append = ''
for _,v in ipairs(data.values) do
    perfdata[1].value = perfdata[1].value + v[1]
    output_options.append = output_options.append..
        (#output_options.append > 0 and ', ' or ' - ')..
        v[2]..' '..v[4]..': '..v[1]
end
