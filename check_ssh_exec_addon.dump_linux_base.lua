local arg = {...}
if arg[1] == 'init' then return true end

local problems = {}

if data['/proc/mounts'] then
    readonly = {}
    fstype = { ext2 = 1, ext3 = 1, ext4 = 1, vfat = 1, xfs = 1 }
    for _,line in ipairs(data['/proc/mounts']) do
        local p = { line:match('^([^%s]+) ([^%s]+) ([^%s]+) ([^%s]+) ([^%s]+) ([^%s]+)$') }
        if #p == 0 then goto continue end
        if p[3]:match('ext') or p[3]:match('fat') or p[3]:match('xfs') then
            for i in (p[4]..','):gmatch('([^,]*),') do
                if i == 'ro' then table.insert(readonly, p[2]) end
            end
        end
        ::continue::
    end
    if #readonly > 0 then
        table.insert(problems, 'Read-only FS: '..table.concat(readonly, ', '))
    end
end

if #problems == 0 then
    lc.exit_code = lc.OK
    lc.exit_message = 'No problem detected'
    if data['hostname'] and data['hostname'][1] then
        lc.exit_message = lc.exit_message..' on '..data['hostname'][1]
    end
else
    lc.exit_code = lc.CRITICAL
    lc.exit_message = table.concat(problems, ' - ')
end
