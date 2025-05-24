-- GUEST-HOSTCPU, guest host cpu usage, cpu_guest_used_perc * numcpu_guest / numcpu_node
-- GUEST-HOSTMEM, guest host mem usage, mem_guest_used_perc * maxmem_guest / maxmem_node
-- GUEST-DISKREAD, rate per second of diskread (cache)
-- GUEST-DISKWRITE, rate per second of diskwrite (cache)

local arg = {...}
if arg[1] == 'init' then
    lc.optsdef.get('baseurl').required = true
    table.insert(lc.optsdef, { short = 'pn', long = 'pve-node',
        help = 'PVE node name' })
    table.insert(lc.optsdef, { short = 'r', long = 'resource',
        required = true,
        call = function (_,v) return (lu.anyof(v, {'hostcpu','hostmem',
            'diskreadrate','diskwriterate'}) and v) end,
        help = 'Resource type: hostcpu, hostmem' })
    table.insert(lc.optsdef, { short = 'to', long = 'top-output',
        call = lc.setter_opt_number,
        help = 'Limit output to given top N' })
    table.insert(lc.optsdef, { short = 'tp', long = 'top-perfdata',
        call = lc.setter_opt_number,
        help = 'Limit perfdata to given top N' })
    table.insert(lc.optsdef, { short = 's', long = 'syslog',
        call = lc.setter_opt_boolean,
        help = 'Pass 1 to enable emitting stats on any resource via syslog' })
    return true
end

function get_resources()
    local output = { nodes = {}, guests = {} }
    local url = '/api2/json/cluster/resources'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,r in ipairs(ctx.zcurl.response.body_decoded.data) do
        if r.type == 'node' then
            output.nodes[tostring(r.node)] = r
        elseif r.template == 0 and (r.type == 'lxc' or r.type == 'qemu') then
            output.guests[tostring(r.vmid)] = r
        end
    end
    return output
end

local resource_meta = {
    hostcpu = { uom = '%', explain = 'perc' },
    hostmem = { uom = '%', explain = 'perc' },
    diskreadrate = { uom = 'Bps', explain = 'byte', checkname = 'diskread' },
    diskwriterate = { uom = 'Bps', explain = 'byte', checkname = 'diskwrite' },
}

lc.checkname = (resource_meta[lc.opts.resource].checkname or lc.opts.resource):upper()
if not lc.opts.syslog then lc.opts.syslog = false end
local resources = get_resources()

local my_node_name = lc.opts.pve_node
if lc.opts.pve_node == 'localhost' then
    local url = '/api2/json/cluster/status'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,e in ipairs(ctx.zcurl.response.body_decoded.data) do
        if e['local'] == 1 then my_node_name = e.name; break end
    end
end

-- diskread and diskwrite are counters and need previous value
local cache
if lc.opts.resource:sub(1, 4) == 'disk' or lc.opts.syslog then
    cache = lc.load_cache()
    lc.save_cache({ ts = lc.now, guests = resources.guests })
    if not cache then
        lc.die_unkn('Data cached, wait for next run')
    end
end

for _,g in pairs(resources.guests) do
    if my_node_name and g.node ~= my_node_name then
        goto continue
    end

    -- add hostcpu, hostmem
    g.hostcpu = g.cpu*100 * g.maxcpu/resources.nodes[g.node].maxcpu
    g.hostmem = g.mem*100/g.maxmem * g.maxmem/resources.nodes[g.node].maxmem
    local vmid_str = tostring(g.vmid)
    if cache and cache.guests[vmid_str] and g.diskread >= cache.guests[vmid_str].diskread then
        g.diskreadrate = (g.diskread - cache.guests[vmid_str].diskread) / (lc.now - cache.ts)
    end
    if cache and cache.guests[vmid_str] and g.diskwrite >= cache.guests[vmid_str].diskwrite then
        g.diskwriterate = (g.diskwrite - cache.guests[vmid_str].diskwrite) / (lc.now - cache.ts)
    end

    table.insert(ctx.perfdata, {
        label = g.name..' ('..g.vmid..')',
        name = lc.opts.resource..'.'..g.name..'.'..resource_meta[lc.opts.resource].explain,
        value = g[lc.opts.resource],
        uom = resource_meta[lc.opts.resource].uom,
        warning = tonumber(lc.opts.warning[1]),
        critical = tonumber(lc.opts.critical[1]),
        _data = g,
    })
    ::continue::
end

lc.exit_code = lp.compute_perfdata(ctx.perfdata)

-- default sort by usage
table.sort(ctx.perfdata, function (a, b)
    if not a.value then return false end
    if not b.value then return true end
    return a.value > b.value
end)

-- emit syslog
if lc.opts.syslog then
    lu.syslog.init('pve-resources')
    for _,p in ipairs(ctx.perfdata) do
        lu.syslog.info(lc.cjson.encode(p._data))
    end
end

lc.exit_message = (lc.opts.top_output and '(top '..lc.opts.top_output..') ' or '')..
    lp.format_output(ctx.perfdata, { limit = lc.opts.top_output })..'|'..
    lp.format_perfdata(ctx.perfdata, { raw = true, limit = lc.opts.top_perfdata })
