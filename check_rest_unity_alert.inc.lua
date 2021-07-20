-- data: JSON response table object
-- lc: libcheck table object
-- perfdata: Perfdata table array to fill

-- Assume request filter:
-- isAcknowledged eq false AND state ne 2

-- check data consistency
if not data.entries then
    lc.die(lc.UNKNOWN, "data.entries: not found")
end
if type(data.entries) ~= 'table' then
    lc.die(lc.UNKNOWN, "data.entries: array expected")
end

-- count alerts by severity
alert2perfdata = {
    [0] = { name = 'emergency', value = 0, uom = '', critical = 0 },
    [1] = { name = 'alert', value = 0, uom = '', critical = 0 },
    [2] = { name = 'critical', value = 0, uom = '', critical = 0 },
    [3] = { name = 'error', value = 0, uom = '', critical = 0 },
    [4] = { name = 'warning', value = 0, uom = '', warning = 0 },
    [5] = { name = 'notice', value = 0, uom = '' },
    [6] = { name = 'info', value = 0, uom = '' },
    [7] = { name = 'debug', value = 0, uom = '' },
    [8] = { name = 'ok', value = 0, uom = '' },
}

for k,v in pairs(data.entries) do
    if type(v) ~= 'table' or
       type(v.content) ~= 'table' or
       type(v.content.severity) ~= 'number' then
        lc.die(lc.UNKNOWN, 'Invalid JSON data structure')
    end

    -- floor because lua/lua-json might represent intergers as float
    severity = math.floor(v.content.severity)
    if alert2perfdata[severity] == nil then
        lc.die(lc.UNKNOWN, 'Unsupported severity in result ('..severity..')')
    end

    -- increment counter
    alert2perfdata[severity].value = alert2perfdata[severity].value + 1
end

-- fill perfdata
for k,v in pairs(alert2perfdata) do
    table.insert(perfdata, v)
end
