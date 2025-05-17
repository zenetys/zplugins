local arg = {...}
if arg[1] == 'init' then
    lc.checkname = ''

    table.insert(lc.optsdef, { short = 'le', long = 'enable-low-threshold',
        help = 'Enable/disable low threshold', call = lc.setter_opt_boolean })
    table.insert(lc.optsdef, { short = 'lf', long = 'low-fixed',
        help = 'Fixed low threshold', call = lc.setter_opt_number })
    table.insert(lc.optsdef, { short = 'ldep', long = 'low-dyn-errpercent',
        help = 'Low dynamic threshold error margin in percent', call = lc.setter_opt_number })
    table.insert(lc.optsdef, { short = 'he', long = 'enable-high-threshold',
        help = 'Enable/disable high threshold', call = lc.setter_opt_boolean })
    table.insert(lc.optsdef, { short = 'hf', long = 'high-fixed',
        help = 'Fixed high threshold', call = lc.setter_opt_number })
    table.insert(lc.optsdef, { short = 'ldep', long = 'high-dyn-errpercent',
        help = 'High dynamic threshold error margin in percent', call = lc.setter_opt_number })
    table.insert(lc.optsdef, { short = 'l', long = 'label',
        help = 'Current value output label' })
    table.insert(lc.optsdef, { short = 'd', long = 'perfdata',
        help = 'Current value perfdata name' })
    table.insert(lc.optsdef, { short = 'T', long = 'cache-ttl',
        help = 'Cache TTL in seconds, 0 for infinite', call = lc.setter_opt_number })
    table.insert(lc.optsdef, { short = 'N', long = 'null-value-state',
        help = 'Null value state, default 3 (UNKNOWN)', call = lc.setter_opt_number })

    default_parameter['p_indice'] = 'logs-*'
    default_parameter['p_date_field'] = '@timestamp'
    default_parameter['p_filter_base'] = '*'
    default_parameter['p_value_field'] = '*'
    default_parameter['p_stats_from'] = 'now-7d/m'
    default_parameter['p_stats_to'] = 'now/m'
    default_parameter['p_stats_date_round'] = '10 minute'
    default_parameter['p_stats_agg_func'] = 'COUNT'
    default_parameter['p_bank_holidays_indice'] = nil
    lc.opts.enable_low_threshold = true
    lc.opts.enable_high_threshold = true
    lc.opts.label = 'value'
    lc.opts.perfdata = 'value'
    lc.opts.cache_ttl = nil -- no cache
    lc.opts.null_value_state = lc.UNKNOWN
    lc.opts.low_dyn_errpercent = 20
    lc.opts.high_dyn_errpercent = 20
    return true
end

local cur_date = os.date('!*t') -- utc
local cur_local_date = os.date('*t')
if not cur_date or not cur_local_date then
    lc.die(lc.UNKNOWN, 'Faled to get current date')
end
local cur_wday = (cur_date.wday-2+7)%7 +1 -- utc mon..sun == 1..7
local cur_hour = cur_date.hour -- utc

-- Query if we are in a bank holiday
if lc.opts.parameter.p_bank_holidays_indice then
    local cur_ts = os.time({
        year = cur_local_date.year,
        month = cur_local_date.month,
        day = cur_local_date.day,
        hour=0, min=0, sec=0,
    })
    local bh_query = { query = 'FROM ${p_bank_holidays_indice} |WHERE ts == '..
        cur_ts..' |KEEP map_wday_utc |LIMIT 1' }
    lc.pdebug('Checking if we are a bank-holiday...')
    local bh_data, err = esh.es1:esql(bh_query, lc.opts.parameter)
    if not bh_data then lc.die(lc.UNKNOWN, 'Bank-holiday query failed: '..err) end
    local bh_map_wday = bh_data.values[1] and tonumber(bh_data.values[1][1])
    lc.pdebug('Map\'ed week-day if bank-holiday: '..tostring(bh_map_wday))
    if bh_map_wday then cur_wday = bh_map_wday end

    lc.opts.parameter.p_bank_holidays_join = 'LOOKUP JOIN ${p_bank_holidays_indice} ON date_utc'
end

-- Fetch current value
local cur_query = { query = [[
FROM ${p_indice}
    | WHERE QSTR("${p_date_field}:[now-10m/m TO now/m] AND (${p_filter_base})")
    | STATS value = ${p_stats_agg_func}(${p_value_field})
]] }
lc.pdebug('Fetching current value...')
local cur_data, err = esh.es1:esql(cur_query, lc.opts.parameter)
if not cur_data then lc.die(lc.UNKNOWN, 'Current value query failed: '..err) end
local cur_value = tonumber(cur_data.values[1][1])
lc.pdebug('Fetching current value took (ms): '..tostring(cur_data.took))
lc.pdebug('Current value: '..tostring(cur_value))
table.insert(perfdata, { name = lc.opts.perfdata, label = lc.opts.label, value = cur_value,
    uom = '', null_state = lc.opts.null_value_state })

-- Fetch stats for dynamic thresholds
local stats_query = { query = [[
FROM ${p_indice}
    | WHERE QSTR("${p_date_field}:[${p_stats_from} TO ${p_stats_to}] AND (${p_filter_base})")
    | EVAL date_rounded = DATE_TRUNC(${p_stats_date_round}, @timestamp)
    | EVAL date_utc = DATE_FORMAT("yyyy-MM-dd'T'HH'Z'", date_rounded)
    | ${p_bank_holidays_join:-EVAL map_wday_utc = NULL, map_hour_utc = NULL}
    | EVAL date_group = COALESCE(map_wday_utc, DATE_EXTRACT("day_of_week", date_rounded))*100 +
        COALESCE(map_hour_utc, DATE_EXTRACT("hour_of_day", date_rounded))
    | STATS value = ${p_stats_agg_func}(${p_value_field}) BY date_group, date_rounded
    | STATS p95 = PERCENTILE(value, 95) BY date_group
    | SORT date_group
// [1] [2]
// p95 date_group
]] }
local stats_data = nil
if lc.opts.cache_ttl then
    stats_data = lc.load_cache(nil, lc.opts.cache_ttl)
end
if type(stats_data) ~= 'table' then
    lc.pdebug('Fetching stats...')
    local err; stats_data, err = esh.es1:esql(stats_query, lc.opts.parameter)
    if not stats_data then lc.die(lc.UNKNOWN, 'Stats query failed: '..err) end
    lc.pdebug('Fetch stats took (ms): '..tostring(stats_data.took))
    if stats_data.is_partial then lc.die(lc.UNKNOWN, 'Stats query partial data') end
    lc.save_cache(stats_data)
end

-- Index stats by date group, eg: 114 for monday (1) hour 14
local stats_by_date_group = {}
for i,v in ipairs(stats_data and stats_data.values or {}) do
    stats_by_date_group[tostring(v[2])] = { p95 = v[1], date_group = v[2] }
end
lc.dump(stats_by_date_group, 'Dump stats by date group')

function prev(ref_wday, ref_hour)
    local prev_hour = (ref_hour-1+24)%24
    local prev_wday = (prev_hour == 23) and (ref_wday-2+7)%7+1 or ref_wday
    return prev_wday, prev_hour
end

function next(ref_wday, ref_hour)
    local next_hour = (ref_hour+1)%24
    local next_wday = (next_hour == 0) and (ref_wday+1)%7 or ref_wday
    return next_wday, next_hour
end

function min(stats, metric, doMax)
    local x = nil
    for _,i in ipairs(stats) do
        if not i[metric] then return nil end
        if not x then x = i[metric]
        elseif (not doMax and i[metric] < x) or
               (doMax and i[metric] > x) then
            x = i[metric]
        end
    end
    return x
end

function max(stats, metric)
    return min(stats, metric, true)
end

local prev_wday, prev_hour = prev(cur_wday, cur_hour)
local next_wday, next_hour = next(cur_wday, cur_hour)
local stats_adj = {
    stats_by_date_group[tostring(prev_wday*100+prev_hour)] or {},
    stats_by_date_group[tostring(cur_wday*100+cur_hour)] or {},
    stats_by_date_group[tostring(next_wday*100+next_hour)] or {},
}
stats_adj.min_p95 = min(stats_adj, 'p95')
stats_adj.max_p95 = max(stats_adj, 'p95')
stats_adj.diff_p95 = (stats_adj.min_p95 and stats_adj.max_p95) and (stats_adj.max_p95 - stats_adj.min_p95)
stats_adj.dyn_threshold = {}
if stats_adj.min_p95 and stats_adj.diff_p95 then
    stats_adj.dyn_threshold.low = math.max(0, stats_adj.min_p95 - stats_adj.diff_p95)
    stats_adj.dyn_threshold.low = stats_adj.dyn_threshold.low -
        (lc.opts.low_dyn_errpercent or 0)*stats_adj.dyn_threshold.low/100
end
if stats_adj.max_p95 and stats_adj.diff_p95 then
    stats_adj.dyn_threshold.high = stats_adj.max_p95 + stats_adj.diff_p95
    stats_adj.dyn_threshold.high = stats_adj.dyn_threshold.high +
        (lc.opts.high_dyn_errpercent or 0)*stats_adj.dyn_threshold.high/100
end
lc.dump(stats_adj, 'Dump adjacent stats')

table.insert(perfdata, { name = 'cur.95p', value = stats_adj[2].p95, uom = '', null_state = lc.OK })
table.insert(perfdata, { name = 'adj.diff_95p', value = stats_adj.diff_p95, uom = '', null_state = lc.OK })
table.insert(perfdata, { name = 'low_dynamic', value = stats_adj.dyn_threshold.low, uom = '', null_state = lc.OK })
table.insert(perfdata, { name = 'high_dynamic', value = stats_adj.dyn_threshold.high, uom = '', null_state = lc.OK })
table.insert(perfdata, { name = 'low_fixed', value = lc.opts.low_fixed, uom = '', null_state = lc.OK })
table.insert(perfdata, { name = 'high_fixed', value = lc.opts.high_fixed, uom = '', null_state = lc.OK })
local low_threshold = stats_adj.dyn_threshold.low
local high_threshold = stats_adj.dyn_threshold.high
if lc.opts.low_fixed and (not low_threshold or lc.opts.low_fixed > low_threshold) then
    low_threshold = lc.opts.low_fixed
end
if lc.opts.high_fixed and (not high_threshold or lc.opts.high_fixed < high_threshold) then
    high_threshold = lc.opts.high_fixed
end
lc.pdebug('low threshold applied: '..tostring(low_threshold))
lc.pdebug('high threshold applied: '..tostring(high_threshold))
perfdata[1].critical = ((lc.opts.enable_low_threshold and low_threshold) and low_threshold or '~')
    ..':'..((lc.opts.enable_high_threshold and high_threshold) and high_threshold or '~')
