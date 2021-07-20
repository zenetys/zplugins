-- data: JSON response table object
-- lc: libcheck table object
-- perfdata: Perfdata table array to fill

-- check data consistency
if not data.entries then
    lc.die(lc.UNKNOWN, "data.entries: not found")
end
if type(data.entries) ~= 'table' then
    lc.die(lc.UNKNOWN, "data.entries: array expected")
end
if type(data.entries[1]) ~= 'table' then
    lc.die(lc.UNKNOWN, "data.entries[1]: table expected")
end
if type(data.entries[1].content) ~= 'table' then
    lc.die(lc.UNKNOWN, "data.entries[1].content: table expected")
end
if type(data.entries[1].content.values) ~= 'table' then
    lc.die(lc.UNKNOWN, "data.entries[1].content.values: table expected")
end

-- sort keys
keys = {}
for k,v in pairs(data.entries[1].content.values) do
    table.insert(keys, k)
end
table.sort(keys)

-- set perfdata
for i,key in ipairs(keys) do
    table.insert(perfdata, {
        name = key,
        value = data.entries[1].content.values[key],
        uom = '%',
        warning = lc.opts.warning[1],
        critical = lc.opts.critical[1],
    })
end
