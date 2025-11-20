local arg = {...}
if arg[1] == 'init' then
    lc.checkname = ''
    lc.optsdef.get('baseurl').required = true
    table.insert(lc.optsdef, { short = 'pn', long = 'pve-node',
        help = 'PVE node name' })
    return true
end

if not lc.opts.pve_node then lc.opts.pve_node = 'localhost' end

local url = '/api2/json/nodes/'..lc.opts.pve_node..'/disks/list'
query(ctx.zcurl, { url = build_url(url) }, 'json')

for _,d in ipairs(ctx.zcurl.response.body_decoded.data) do
    if not d.devpath then goto continue; end
    table.insert(ctx.perfdata, {
        label = d.devpath,
        name = 'wearout.'..(d.devpath:gsub('^/dev/', ''))..'.perc',
        value = d.wearout and (100 - d.wearout) or nil,
        uom = '%',
        warning = tonumber(lc.opts.warning[1]),
        critical = tonumber(lc.opts.critical[1]),
    })
    ::continue::
end

lc.exit_code = lp.compute_perfdata(ctx.perfdata)

-- default sort by wearout percent
table.sort(ctx.perfdata, function (a, b)
    if not a.value then return false end
    if not b.value then return true end
    return a.value > b.value
end)

lc.exit_message = lp.format_output(ctx.perfdata)..'|'..
    lp.format_perfdata(ctx.perfdata, true)
