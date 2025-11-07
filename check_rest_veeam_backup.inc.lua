local result
local message

if not data.data then
    lc.die(lc.UNKNOWN, "JSON node 'data' not found")
end

for key,backup in pairs(data.data) do
    if backup.name == lc.opts.parameter.job and backup.result ~= lc.cjson.null then
        result=backup.result.result
        message=backup.result.message

        -- "endTime": "2022-01-29T22:15:14.87+01:00",
        pattern="(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+).*"

        critical_last_backup=tonumber(lc.opts.critical[1])*24*60*60     -- convert '--critical' parameter in seconds

        -- lc.pdump(lc.opts)
        year,month,day,hour,min,sec=backup.endTime:match(pattern)
        -- MON={Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
        -- month=MON[month]

        -- offset=os.time()-os.time(os.date("!*t"))
        offset=0
        timestamp_last_backup=os.time({day=day,month=month,year=year,hour=hour,min=min,sec=sec})+offset

        break
    end
end

if not result then
    lc.die(lc.UNKNOWN, "Could not find last backup endTime")
end

if result == "Success" then
    if os.time()-timestamp_last_backup >= critical_last_backup then
        lc.die(lc.CRITICAL, "Backup too old : " .. day .. "/" .. month .. "/" .. year)
    else
        lc.die(lc.OK, "Last endBackup : " .. day .. "/" .. month .. "/" .. year)
    end
end
if result == "Warning" then
    lc.die(lc.WARNING, " : " .. message .. " / Last endBackup : " .. day .. "/" .. month .. "/" .. year)
else
    lc.die(lc.CRITICAL, " : " .. message .. " / Last endBackup : " .. day .. "/" .. month .. "/" .. year)
end
