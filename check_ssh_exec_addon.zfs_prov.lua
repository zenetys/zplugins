local arg = {...}
if arg[1] == 'init' then return true end

-- parse raw data
local headers = nil
local zpool = {}

for iline,line in ipairs(data) do
    local p = { line:match('^([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)%s+([^%s]+)$') }
    if #p == 0 then goto continue end
    if iline == 1 then headers = p; goto continue end

    local z = { p[1]:match('^([^/]+)/?(.*)') }
    if #z == 0 then goto continue end

    if not zpool[z[1]] then zpool[z[1]] = {} end
    local entry = {}
    for iheader,header in ipairs(headers) do
        if p[iheader] and #p[iheader] > 0 and p[iheader] ~= '-' then
            entry[header] = p[iheader]
        end
    end
    zpool[z[1]][p[1]] = entry
    ::continue::
end

-- compute total and provisioned size by zpool
local zpool_keys = {} -- for zpool traversal sorted by pool name
for p in pairs(zpool) do table.insert(zpool_keys, p) end
table.sort(zpool_keys)
for _,p in ipairs(zpool_keys) do

    local used = tonumber(zpool[p][p].USED)
    local avail = tonumber(zpool[p][p].AVAIL)
    local total = (used and avail) and (used+avail)

    local prov = 0
    for e,zentry in pairs(zpool[p]) do
        -- skip top level zpool entry
        if e == p then goto continue end

        local entry_size = nil
        if zentry.VOLSIZE then
            entry_size = tonumber(zentry.VOLSIZE)
        elseif zentry.REFQUOTA then
            entry_size = tonumber(zentry.REFQUOTA)
        end
        if entry_size then
            prov = prov + entry_size
        end
        ::continue::
    end

    zpool[p]._total = total
    zpool[p]._prov = prov

    table.insert(perfdata, {
        name = p,
        value = zpool[p]._prov,
        max = zpool[p]._total,
        warning = lc.opts.warning and lc.opts.warning[1],
        critical = lc.opts.critical and lc.opts.critical[1],
        uom = 'B',
    })
end

lc.dump(zpool, 'Dump zpool data')
