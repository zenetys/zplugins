-- parse lines from <data> array

local arg = {...}
if arg[1] == 'init' then return true end

local state = 0
local section = nil
local prev_line = nil
for _,line in ipairs(data) do
    if line:sub(-1) == '\r' then line = line:sub(1, -2) end
    local mark = { line:match('^<<< (.+) >>>$') }
    if #mark > 0 and (not section or prev_line == '') then
        section = mark[1]
        lc.debug('new section: '..section)
    elseif section and #line > 0 then
        if not data[section] then data[section] = {} end
        table.insert(data[section], line)
        lc.debug('add to section: '..section..', line: '..line)
    end
    prev_line = line
end
