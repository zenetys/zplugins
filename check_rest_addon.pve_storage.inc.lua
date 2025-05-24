local arg = {...}
if arg[1] == 'init' then
    lc.checkname = ''
    lc.optsdef.get('baseurl').required = true
    table.insert(lc.optsdef, { short = 'pn', long = 'pve-node',
        help = 'PVE node name' })
    table.insert(lc.optsdef, { short = 'pin', long = 'pve-include-name',
        call = lc.setter_opt_array,
        help = 'Include storage by name with lua pattern (array)' })
    table.insert(lc.optsdef, { short = 'pxn', long = 'pve-exclude-name',
        call = lc.setter_opt_array,
        help = 'Exclude storage by name with lua pattern (array)' })
    table.insert(lc.optsdef, { short = 'pxt', long = 'pve-exclude-type',
        call = lc.setter_opt_array,
        help = 'Exclude storage by type with lua pattern (array)' })
    table.insert(lc.optsdef, { short = 's', long = 'syslog',
        call = lc.setter_opt_boolean,
        help = 'Pass 1 to enable emitting stats via syslog' })
    return true
end

if not lc.opts.pve_node then lc.opts.pve_node = 'localhost' end
if not lc.opts.syslog then lc.opts.syslog = false end

local my_node_name = lc.opts.pve_node
if lc.opts.syslog then
    lu.syslog.init('pve-storage')
    if lc.opts.pve_node == 'localhost' then
        local url = '/api2/json/cluster/status'
        query(ctx.zcurl, { url = build_url(url) }, 'json')
        for _,e in ipairs(ctx.zcurl.response.body_decoded.data) do
            if e['local'] == 1 then my_node_name = e.name; break end
        end
    end
end

local url = '/api2/json/nodes/'..lc.opts.pve_node..'/storage'
query(ctx.zcurl, { url = build_url(url) }, 'json')

local inactive_storages = {}
for _,s in ipairs(ctx.zcurl.response.body_decoded.data) do
    if s.enabled == 0 then goto continue end
    if lc.opts.pve_include_name and
       not lu.mmatch(s.storage, lc.opts.pve_include_name) then
        goto continue
    end
    if lc.opts.pve_exclude_name and
       lu.mmatch(s.storage, lc.opts.pve_exclude_name) then
        goto continue
    end
    if lc.opts.pve_exclude_type and
       lu.mmatch(s.type, lc.opts.pve_exclude_type) then
        goto continue
    end

    s.node = my_node_name
    table.insert(ctx.perfdata, {
        label = s.storage,
        name = 'usage.'..s.storage..'.perc',
        value = s.used_fraction and s.used_fraction*100,
        uom = '%',
        warning = tonumber(lc.opts.warning[1]),
        critical = tonumber(lc.opts.critical[1]),
        _data = s,
    })
    if s.active == 0 then
        table.insert(inactive_storages, #ctx.perfdata)
    end

    ::continue::
end

lc.exit_code = lp.compute_perfdata(ctx.perfdata)
for _,i in ipairs(inactive_storages) do
    ctx.perfdata[i].extra = ' INACTIVE'
    ctx.perfdata[i].state = lc.CRITICAL
    lc.exit_code = lc.worsen_status(lc.exit_code, lc.CRITICAL) 
end

-- default sort by usage
table.sort(ctx.perfdata, function (a, b)
    if not a.value then return false end
    if not b.value then return true end
    return a.value > b.value
end)

-- emit syslog
if lc.opts.syslog then
    for _,p in ipairs(ctx.perfdata) do
        lu.syslog.info(lc.cjson.encode(p._data))
    end
end

lc.exit_message = lp.format_output(ctx.perfdata)..'|'..
    lp.format_perfdata(ctx.perfdata, true)
