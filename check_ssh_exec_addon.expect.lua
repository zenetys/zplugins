local arg = {...}
if arg[1] == 'init' then
    _ENV.lu = require 'libutil'
    table.insert(lc.optsdef, { long = 'expr-critical', help = 'CRITICAL expression' })
    table.insert(lc.optsdef, { long = 'expr-warning', help = 'WARNING expression' })
    table.insert(lc.optsdef, { long = 'expr-unknown', help = 'UNKNOWN expression' })
    table.insert(lc.optsdef, { long = 'output-critical', help = 'CRITICAL output template' })
    table.insert(lc.optsdef, { long = 'output-warning', help = 'WARNING output template' })
    table.insert(lc.optsdef, { long = 'output-unknown', help = 'UNKNOWN output template' })
    table.insert(lc.optsdef, { long = 'output-ok', help = 'OK output template' })
    lc.usage_notes = [[
Expression are lua code that is evaluated in order: critical,
warning, unknown. The expression matches if it returns a
true-val, ie. anything else than nil and false. The default
state is ok.
Output templates can be used to build a custom plugin output.
Command output is available through array variable data;
ie. first line is %{data[1]}.
]]
    return true
end

function truncate(data, max)
    data = type(data) == 'table' and table.concat(data, ' ') or tostring(data or '')
    if max and #data > max then data = data:sub(1, max)..'...' end
    return data
end

-- default state
local opts_key_output = 'output_ok'
lc.exit_code = lc.OK

for _,v in ipairs({'critical','warning','unknown'}) do
    local opts_key_expr = 'expr_'..v
    local lc_key_status = v:upper()
    if lc.opts[opts_key_expr] then
        local ret, err, output
        ret, err = lu.lua(lc.opts[opts_key_expr], 'expr', nil, nil, _ENV)
        if err then lc.die(lc.UNKNOWN, err) end
        if ret then
            lc.exit_code = lc[lc_key_status]
            opts_key_output = 'output_'..v
            break
        end
    end
end

if lc.opts[opts_key_output] then
    lc.exit_message, err = lu.expand(lc.opts[opts_key_output], _ENV, 'output')
    if err then lc.perr(err) end
end

if not lc.exit_message or #lc.exit_message == 0 then
    lc.exit_message = 'Command output: '..truncate(data, 100)
end
