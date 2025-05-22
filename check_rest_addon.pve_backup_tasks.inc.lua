-- This check queries node's vzdump tasks history between <pve-period> and
-- now. Tasks logs get parsed to find out the *last* backup status of guests.
-- If <pve-scheduled> is enabled, guests without scheduled backup are ignored.
-- Note: there is no link between a backup job and the resulting task which
-- carries each backup result.

local tz = require('tz')

local arg = {...}
if arg[1] == 'init' then
    lc.checkname = ''
    lc.optsdef.get('baseurl').required = true
    table.insert(lc.optsdef, { short = 'pn', long = 'pve-node',
        help = 'PVE node name' })
    table.insert(lc.optsdef, { short = 'pp', long = 'pve-period',
        help = 'PVE period (s) from now', call = lc.setter_opt_number })
    table.insert(lc.optsdef, { short = 'ps', long = 'pve-scheduled',
        help = 'Ignore guests without scheduled backup', call = lc.setter_opt_boolean })
    return true
end

function get_vms_scheduled_for_backup()
    local output = {}
    local url = '/api2/json/cluster/backup'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    for _,job in pairs(ctx.zcurl.response.body_decoded.data) do
        if job.enabled ~= 1 then goto continue end
        url = '/api2/json/cluster/backup/'..job.id..'/included_volumes'
        query(ctx.zcurl, { url = build_url(url) }, 'json')
        for _,vm in pairs(ctx.zcurl.response.body_decoded.data.children) do
            output[vm.id] = vm.name
        end
        ::continue::
    end
    return output
end

function get_timezone()
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/time'
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    return ctx.zcurl.response.body_decoded.data.timezone
end

function get_tasks()
    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/tasks'..
        '?source=all'..
        '&typefilter=vzdump'..
        '&since='..(lc.now-lc.opts.pve_period)..
        '&until='..lc.now
    query(ctx.zcurl, { url = build_url(url) }, 'json')
    return ctx.zcurl.response.body_decoded.data
end

function parse_task_log(task, timezone)
    local output = { backups = {} }
    if not task or not task.upid then return output end

    local url = '/api2/json/nodes/'..lc.opts.pve_node..'/tasks/'..task.upid..'/log?limit=0'
    query(ctx.zcurl, { url = build_url(url) }, 'json')

    local cap, n
    local entry = {}
    for _,l in ipairs(ctx.zcurl.response.body_decoded.data) do
        l = l.t

        if not output.storage then
            cap = { l:match('starting new backup job: .* --storage ([^%s]+)') }
            if #cap > 0 then output.storage = cap[1] end
        elseif not entry.vmid then
            cap = { l:match('Starting Backup of VM (%d+)') }
            if #cap > 0 then entry.vmid = tonumber(cap[1]) end
        else
            cap = { l:match("Backup started at (%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)") }
            if #cap > 0 then
                entry.starttime = tz.time({ year = tonumber(cap[1]), month = tonumber(cap[2]),
                    day = tonumber(cap[3]), hour = tonumber(cap[4]), min = tonumber(cap[5]),
                    sec = tonumber(cap[6]) }, timezone)
                goto continue
            end

            _, cap = lu.mmatch(l, { 'VM Name: (.+)', 'CT Name: (.+)' })
            if #cap > 0 then
                entry.vmname = cap[1]
                goto continue
            end

            cap = { l:match("include disk %b'' %b'' ([%d.]+[^%s]*)") }
            if #cap > 0 then
                entry.disk_size = (entry.disk_size or 0) + lu.human2num(cap[1], 1024)
                goto continue
            end

            cap = { l:match('backup mode: (.+)') }
            if #cap > 0 then
                entry.mode = cap[1]
                goto continue
            end

            cap = { l:match('bandwidth limit: ([%d.]+%s*[^/]*)/s') }
            if #cap > 0 then
                entry.bwlimit = lu.human2num(cap[1], 1024)
                goto continue
            end

            cap = { l:match("creating .* archive '([^']+)'") }
            if #cap > 0 then
                entry.archive = cap[1]
                goto continue
            end

            cap = { l:match('No space left on device') }
            if #cap > 0 then
                output.space_error = true
                goto continue
            end

            cap = { l:match('backup is sparse: ([%d.]+%s*[^%s]*) %(([%d.]+)%%%) total zero data') }
            if #cap > 0 then
                entry.sparse_size = lu.human2num(cap[1], 1024)
                entry.sparse_perc = tonumber(cap[2])
                goto continue
            end

            cap = { l:match('transferred ([%d.]+%s*[^%s]*) in (%d+) seconds %(([%d.]+%s*[^/]*)/s%)') }
            if #cap > 0 then
                entry.xfer_size = lu.human2num(cap[1], 1024)
                entry.xfer_time = tonumber(cap[2])
                entry.xfer_speed = lu.human2num(cap[3], 1024)
                goto continue
            end

            n, cap = lu.mmatch(l, { 'Finished Backup of VM '..entry.vmid..' %((%d+):(%d+):(%d+)%)',
                'Backup of VM '..entry.vmid..' failed' })
            if n then
                if n == 1 then entry.success, entry.duration = true, cap[1]*3600+cap[2]*60+cap[3]
                else entry.success, entry.duration = false, nil end
                goto continue
            end

            n, cap = lu.mmatch(l, { 'Failed at (%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)',
                'Backup finished at (%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)' })
            if #cap > 0 then
                entry.endtime = tz.time({ year = tonumber(cap[1]), month = tonumber(cap[2]),
                    day = tonumber(cap[3]), hour = tonumber(cap[4]), min = tonumber(cap[5]),
                    sec = tonumber(cap[6]) }, timezone)
                if not entry.duration and entry.starttime then
                    entry.duration = entry.endtime-entry.starttime
                end
                entry.task = task.upid
                entry.node = task.node
                entry.storage = output.storage
                table.insert(output.backups, entry)
                entry = {}
                goto continue
            end
        end
        ::continue::
    end
    return output
end

if not lc.opts.pve_node or #lc.opts.pve_node == 0 then lc.opts.pve_node = 'localhost' end
if not lc.opts.pve_period then lc.opts.pve_period = 86400*2 end

local vms_scheduled
if lc.opts.pve_scheduled then
    vms_scheduled = get_vms_scheduled_for_backup()
    lc.dump(vms_scheduled, 'Guests with scheduled backup job')
end

local pve_timezone = get_timezone()
lc.debug('Node timezone: '..tostring(pve_timezone))

local tasks = get_tasks()
for _,t in ipairs(tasks) do
    t.log = parse_task_log(t, pve_timezone)
end
lc.dump(tasks, 'Parsed tasks')

-- extract last backup per vmid + storage
local last_by_vmid_storage = {}
local last_backups = {}
local stats_by_storage = {}
for _,t in ipairs(tasks) do
    for _,b in ipairs(t.log.backups) do
        if vms_scheduled and not vms_scheduled[b.vmid] then goto continue end
        if not last_by_vmid_storage[b.vmid] then last_by_vmid_storage[b.vmid] = {} end
        if last_by_vmid_storage[b.vmid][t.log.storage] and
           b.starttime <= last_by_vmid_storage[b.vmid][t.log.storage].starttime then
            goto continue
        end

        last_by_vmid_storage[b.vmid][t.log.storage] = b
        table.insert(last_backups, b)
        if not stats_by_storage[t.log.storage] then
            stats_by_storage[t.log.storage] = { duration = 0, space_error = false, tasks = {}, ntask = 0 }
        end
        stats_by_storage[t.log.storage].duration = stats_by_storage[t.log.storage].duration + b.duration
        if not b.success and t.log.space_error then stats_by_storage[t.log.storage].space_error = true end
        if not stats_by_storage[t.log.storage].tasks[t.upid] then
            stats_by_storage[t.log.storage].ntask = stats_by_storage[t.log.storage].ntask + 1
            stats_by_storage[t.log.storage].tasks[t.upid] = 1
        end
        ::continue::
    end
end
lc.dump(last_by_vmid_storage, 'Last backup per vmid + storage')
lc.dump(stats_by_storage, 'Stats by storage')

-- emit json logs
lu.syslog.init('pve-backup-tasks')
local log_emitted = lc.load_cache('log_emitted') or {}
for vmid,o in pairs(last_by_vmid_storage) do
    for storage,backup in pairs(o) do
        local cache_key = backup.task..','..backup.vmid
        if not log_emitted[cache_key] then
            lu.syslog.info(lc.cjson.encode(backup))
            log_emitted[cache_key] = backup.endtime
        end
    end
end
for k,endtime in pairs(log_emitted) do
    if endtime < lc.now - lc.opts.pve_period*2 then
        log_emitted[k] = nil
    end
end
lc.save_cache(log_emitted, 'log_emitted')

-- total, success, failed backups
local total_backups = 0
local failed_backups = {}
for vmid,_ in pairs(last_by_vmid_storage) do
    for storage,backup in pairs(last_by_vmid_storage[vmid]) do
        total_backups = total_backups + 1
        if not backup.success then table.insert(failed_backups, backup.vmname..' ('..backup.vmid..')') end
    end
end
local success_backups = total_backups - #failed_backups

table.insert(ctx.perfdata, { name = 'backup.failed', value = #failed_backups, uom = '',
    min = 0, max = total_backups })

lc.exit_code = lc.OK
local output_messages = {}

-- last backups success/total
local success_rate_message = 'Last backup'..(total_backups > 1 and 's' or '')..': '..
    success_backups..'/'..total_backups
if #failed_backups > 0 then
    lc.exit_code = lc.worsen_status(lc.exit_code, lc.CRITICAL)
    success_rate_message = '**'..success_rate_message..'**'
end
table.insert(output_messages, success_rate_message)

-- list storage with space error
local space_message = ''
for storage,stats in pairs(stats_by_storage) do
    if stats.space_error then
        lc.exit_code = lc.worsen_status(lc.exit_code, lc.CRITICAL)
        space_message = space_message..(#space_message > 0 and ', ' or '')..storage
    end
end
if #space_message > 0 then
    table.insert(output_messages, '**No space: '..space_message..'**')
end

-- list failed backups
if #failed_backups > 0 then
    table.insert(output_messages, 'Failed: '..table.concat(failed_backups, ', '))
end

-- duration and number of tasks by storage
local duration_message = ''
for storage,stats in pairs(stats_by_storage) do
    duration_message = duration_message..(#duration_message > 0 and ', ' or '')..
        storage..' '..lu.dhms(stats.duration)..' ('..stats.ntask..' task'..(stats.ntask > 1 and 's' or '')..')'
    table.insert(ctx.perfdata, { name = 'time.'..storage, value = stats.duration, uom = 's' })
end
if #duration_message > 0 then
    table.insert(output_messages, 'Time: '..duration_message)
end

lc.exit_message = table.concat(output_messages, ' - ')..'|'..
    lp.format_perfdata(ctx.perfdata, true)
