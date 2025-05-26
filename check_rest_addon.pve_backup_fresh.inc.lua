-- Typical thresholds for daily backups:
-- - warning if backup is > 1.5 days old: --warning-age 129600
-- - critical if backup is > 2.5 days old: --critical-age 216000
-- - warning if verification state != ok and backup is > 1 day old: --warning-verify 86400

local arg = {...}
if arg[1] == 'init' then
    lc.optsdef.get('baseurl').required = true
    table.insert(lc.optsdef, { short = 'pn', long = 'pve-node',
        help = 'PVE node name' })
    table.insert(lc.optsdef, { short = 'pd', long = 'pve-datastore',
        help = 'PVE datastore name' })
    table.insert(lc.optsdef, { short = 'wa', long = 'warning-age',
        call = lc.setter_opt_number,
        help = 'Guest backup warning age (s)' })
    table.insert(lc.optsdef, { short = 'ca', long = 'critical-age',
        call = lc.setter_opt_number,
        help = 'Guest backup critical age (s)' })
    table.insert(lc.optsdef, { short = 'wva', long = 'warning-verify',
        call = lc.setter_opt_number,
        help = 'Guest backup verify warning delay (s), PBS only' })
    table.insert(lc.optsdef, { short = 'cva', long = 'critical-verify',
        call = lc.setter_opt_number,
        help = 'Guest backup verify critical delay (s), PBS only' })
    return true
end

function get_guests(node)
    if not node then return nil end
    local output = {}
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/qemu'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,g in ipairs(ctx.zcurl.response.body_decoded.data) do output[g.vmid] = g.vmid end
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/lxc'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,g in ipairs(ctx.zcurl.response.body_decoded.data) do output[g.vmid] = g.vmid end
    return output
end

function get_backup_guests()
    local output = {}
    -- starting from backup jobs, list backup'ed guests by storage
    local url = '/api2/json/cluster/backup'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    local jobs = ctx.zcurl.response.body_decoded.data
    for _,b in ipairs(jobs) do
        if b.enabled == 0 then goto continue end
        if not output[b.storage] then output[b.storage] = {} end
        url = '/api2/json/cluster/backup/'..b.id..'/included_volumes'
        query(ctx.zcurl, { url = build_url(url) }, 'json')
        if not ctx.zcurl.response.body_decoded.data.children then goto continue end
        for _,v in ipairs(ctx.zcurl.response.body_decoded.data.children) do
             output[b.storage][v.id] = { id = v.id, name = v.name, type = v.type }
        end
        ::continue::
    end
    lc.dump(output, "Backup'ed guests by storage")
    return output
end

function get_ds_last_content(datastore)
    local output = {} -- key: vmid, value = last entry according to ctime
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/storage/'..datastore..'/content/?content=backup'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,e in ipairs(ctx.zcurl.response.body_decoded.data) do
        if not output[e.vmid] or e.ctime > output[e.vmid].ctime then
            output[e.vmid] = e
        end
    end
    lc.dump(output, 'Datastore '..datastore..' last guest backups')
    return output
end

lc.checkname = ''
local filter_guests = get_guests(lc.opts.pve_node)
local backup_guests_by_ds = get_backup_guests()
local content_by_ds = {}
local output = {
    no_backup = {},
    too_old = {},
    age_ok = {},
    late_verify = {},
    verify_ok = {},
    need_verify = {},
    final = {},
}
local total = 0
local total_verify = 0
lc.exit_code = lc.OK

for ds,guests in pairs(backup_guests_by_ds) do
    if lc.opts.pve_datastore and ds ~= lc.opts.pve_datastore then goto continue end

    for _,g in pairs(guests) do
        if filter_guests and not filter_guests[g.id] then goto continue2 end

        local guest_text = g.name..' ('..g.id..')'
        lc.pdebug('Check storage '..ds..', guest '..guest_text)
        total = total + 1

        if not content_by_ds[ds] then
            content_by_ds[ds] = get_ds_last_content(ds)
        end

        if not content_by_ds[ds][g.id] then
            table.insert(output.no_backup, guest_text)
            lc.exit_code = lc.worsen_status(lc.exit_code, lc.CRITICAL)
        else
            if lc.opts.critical_age and content_by_ds[ds][g.id].ctime < (lc.now - lc.opts.critical_age) then
                table.insert(output.too_old, guest_text)
                lc.exit_code = lc.worsen_status(lc.exit_code, lc.CRITICAL)
            elseif lc.opts.warning_age and content_by_ds[ds][g.id].ctime < (lc.now - lc.opts.warning_age) then
                table.insert(output.too_old, guest_text)
                lc.exit_code = lc.worsen_status(lc.exit_code, lc.WARNING)
            else
                table.insert(output.age_ok, guest_text)
            end
            if content_by_ds[ds][g.id].format:sub(1, 4) == 'pbs-' then
                total_verify = total_verify + 1
                if content_by_ds[ds][g.id].verification and
                   content_by_ds[ds][g.id].verification.state and
                   content_by_ds[ds][g.id].verification.state == 'ok' then
                    table.insert(output.verify_ok, guest_text)
                elseif lc.opts.critical_verify and content_by_ds[ds][g.id].ctime < (lc.now - lc.opts.critical_verify) then
                    table.insert(output.late_verify, guest_text)
                    lc.exit_code = lc.worsen_status(lc.exit_code, lc.CRITICAL)
                elseif lc.opts.warning_verify and content_by_ds[ds][g.id].ctime < (lc.now - lc.opts.warning_verify) then
                    table.insert(output.late_verify, guest_text)
                    lc.exit_code = lc.worsen_status(lc.exit_code, lc.WARNING)
                else
                    table.insert(output.need_verify, guest_text)
                end
            end
        end
        ::continue2::
    end
    ::continue::
end

for _,spec in ipairs({ { label = 'No backup', key = 'no_backup' },
                       { label = 'Too old', key = 'too_old' },
                       { label = 'Late verify', key = 'late_verify' } }) do
    if #output[spec.key] > 0 then
        local text = '**'..spec.label..': '..#output[spec.key]..'/'..total..'** = '
        for i,v in ipairs(output[spec.key]) do
            if i > 3 then text = text..', +'..(#output[spec.key]-3); break end
            text = text..(i > 1 and ', ' or '')..v
        end
        table.insert(output.final, text)
    end
end
if #output.age_ok > 0 then
    table.insert(output.final, 'Backup fresh: '..#output.age_ok..'/'..total)
end
if #output.need_verify > 0 then
    table.insert(output.final, 'Need verify: '..#output.need_verify..'/'..total_verify)
end
if #output.verify_ok > 0 then
    table.insert(output.final, 'Verified: '..#output.verify_ok..'/'..total_verify)
end
if #output.final == 0 then
    table.insert(output.final, 'Nothing to check')
end

for k,_ in pairs(output) do
    if k ~= 'final' then
        table.insert(ctx.perfdata, { name = k, value = #output[k], uom = '' })
    end
end

lc.exit_message = table.concat(output.final, ' - ')..'|'..
    lp.format_perfdata(ctx.perfdata, { raw = true })
