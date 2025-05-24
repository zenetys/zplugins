local arg = {...}
if arg[1] == 'init' then
    lc.checkname = ''
    lc.optsdef.get('baseurl').required = true
    table.insert(lc.optsdef, { short = 'pn', long = 'pve-node',
        help = 'PVE node name' })
    table.insert(lc.optsdef, { short = 'pit', long = 'pve-include-tag',
        call = lc.setter_opt_array,
        help = 'Include guests by tag with lua pattern (array)' })
    table.insert(lc.optsdef, { short = 'pxn', long = 'pve-exclude-name',
        call = lc.setter_opt_array,
        help = 'Exclude guests by vmname with lua pattern (array)' })
    table.insert(lc.optsdef, { short = 'pxi', long = 'pve-exclude-id',
        call = lc.setter_opt_array,
        help = 'Exclude guests by vmid (array)' })
    table.insert(lc.optsdef, { short = 'pxt', long = 'pve-exclude-tag',
        call = lc.setter_opt_array,
        help = 'Exclude guests by tag with lua pattern (array)' })
    return true
end

function get_not_backed_up()
    local url = '/api2/json/cluster/backup-info/not-backed-up'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    return ctx.zcurl.response.body_decoded.data
end

function get_guests()
    local guests = {}
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/qemu'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,g in ipairs(ctx.zcurl.response.body_decoded.data) do
        g.type = 'qemu'
        guests[g.vmid] = g
    end
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/lxc'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,g in ipairs(ctx.zcurl.response.body_decoded.data) do
        g.type = 'lxc'
        guests[g.vmid] = g
    end
    return guests
end

-- reindex vmid exclude list
if lc.opts.pve_exclude_id then
    local x = {}
    for _,v in ipairs(lc.opts.pve_exclude_id) do
        local vmid = tonumber(v)
        x[vmid] = vmid
    end
    lc.opts.pve_exclude_id = x
end

local not_backed_up = get_not_backed_up()
local guests

for i = #not_backed_up, 1, -1 do
    local g = not_backed_up[i]

    -- exclude guests not on requested node
    if lc.opts.pve_node then
        if not guests then guests = get_guests() end
        if not guests[g.vmid] then
            lc.pdebug('Skip '..g.name..' ('..g.vmid..'), not on requested node')
            not_backed_up[i] = nil
            --table.remove(not_backed_up, i)
            goto continue
        end
    end
    -- include based on tag patterns
    if lc.opts.pve_include_tag then
        if not guests then guests = get_guests() end
        if not guests[g.vmid] or not guests[g.vmid].tags or
           not lu.mmatch(guests[g.vmid].tags, lc.opts.pve_include_tag) then
            lc.pdebug('Skip '..g.name..' ('..g.vmid..'), include tag no-match, guest tags <'..
                (guests[g.vmid].tags or '')..'>')
            not_backed_up[i] = nil
            goto continue
        end
    end
    -- exclude based on vmname patterns
    if lc.opts.pve_exclude_name and lu.mmatch(g.name, lc.opts.pve_exclude_name) then
        lc.pdebug('Skip '..g.name..' ('..g.vmid..'), exclude name match')
        not_backed_up[i] = nil
        goto continue
    end
    -- exclude based on vmid list
    if lc.opts.pve_exclude_id and lc.opts.pve_exclude_id[g.vmid] then
        lc.pdebug('Skip '..g.name..' ('..g.vmid..'), exclude vmid match')
        not_backed_up[i] = nil
        goto continue
    end
    -- exclude based on tag patterns
    if lc.opts.pve_exclude_tag then
        if not guests then guests = get_guests() end
        if guests[g.vmid] and guests[g.vmid].tags and
           lu.mmatch(guests[g.vmid].tags, lc.opts.pve_exclude_tag) then
            lc.pdebug('Skip '..g.name..' ('..g.vmid..'), exclude tag match, guest tags <'..
                (guests[g.vmid].tags or '')..'>')
            not_backed_up[i] = nil
            goto continue
        end
    end
    lc.pdebug('Keep '..g.name..' ('..g.vmid..')')
    ::continue::
end

local not_backed_up_text = {}
for i,g in pairs(not_backed_up) do
    table.insert(not_backed_up_text, g.name..' ('..g.vmid..')')
end
table.sort(not_backed_up_text)

table.insert(ctx.perfdata, {
    name = 'backup.missing',
    value = #not_backed_up_text,
    uom = ''
})

if #not_backed_up_text == 0 then
    lc.exit_code = lc.OK
    lc.exit_message = 'No missing backup found'
else
    lc.exit_code = lc.CRITICAL
    lc.exit_message = 'Missing backup'..(#not_backed_up_text > 1 and 's' or '')..
        ': '..table.concat(not_backed_up_text, ', ')
end

lc.exit_message = lc.exit_message..'|'..lp.format_perfdata(ctx.perfdata, true)
