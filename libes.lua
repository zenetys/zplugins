-- Copyright Julien Thomas < julthomas @ free.fr >
-- Copyright Zenetys < jthomas @ zenetys.com >
-- Author: Julien Thomas
-- Licence: MIT

local lu = require 'libutil'
local cjson = require 'cjson.safe'
local ZCurl = require 'libzcurl'
require 'libzcurlexec'

function perr(fmt, ...)
    io.stderr:write(fmt:format(table.unpack({...}))..'\n')
end

local es = {}

function es.period_from_to(params, defaults)
    for _,o in ipairs({ {params, 'params'}, {defaults, 'defaults'} }) do
        if o[1].period then
            o[1].period = tonumber(o[1].period)
            if not o[1].period then return nil, o[2]..': number required (s)' end
        end
        for _,t in ipairs({ 'from', 'to' }) do
            if o[1][t] then
                o[1][t..'_ts'] = lu.date2ts(o[1][t])
                if not o[1][t..'_ts'] then return nil, o[2]..'.'..t..
                    ': ts (s) or date (rfc3339) required' end
                o[1][t] = nil
            end
        end
    end

    if params.from_ts and params.to_ts and params.period then
        return nil, 'period and from/to mutually exclusive'
    end

    function pft(o)
        if o.from_ts and o.to_ts then
            o.period = o.to_ts - o.from_ts
        elseif o.from_ts and o.period then
            o.to_ts = o.from_ts + o.period
        elseif o.to_ts and o.period then
            o.from_ts = o.to_ts - o.period
        else
            return false
        end
        return o
    end

    if not pft(params) then
        pft_defaults = pft(defaults)
        if params.from_ts and defaults.period then
            params.period = defaults.period
            params.to_ts = params.from_ts + defaults.period
        elseif params.to_ts and defaults.period then
            params.period = defaults.period
            params.from_ts = params.to_ts - defaults.period
        elseif params.period and defaults.to_ts then
            params.from_ts = defaults.to_ts - params.period
            params.to_ts = defaults.to_ts
        elseif pft_defaults then
            for k,v in pairs(pft_defaults) do params[k] = v end
        else
            return nil, 'bad period/from/to combination'
        end
    end

    if params.from_ts >= params.to_ts then return nil, 'to must be > from' end
    if params.period == 0 then return nil, 'period must be > 0' end

    params.from_rfc3339 = lu.ts2rfc3339(params.from_ts)
    params.to_rfc3339 = lu.ts2rfc3339(params.to_ts)
    return params
end

function array2filter(operator, field, array)
    if #array == 0 then return '' end
    local out = field..':('
    for i,v in ipairs(array) do
        if i > 1 then out = out..' '..operator..' ' end
        out = out..'"'..(tostring(v):gsub('([\\"])', '\\%1'))..'"'
    end
    return out..')'
end

function es.OR(field, array) return array2filter('OR', field, array) end
function es.AND(field, array) return array2filter('AND', field, array) end

function es.env(...)
    return lu.tcopy(table.unpack({...}), { OR = es.OR, AND = es.AND })
end

-- EsHandle

es.EsHandle = {}
es.EsHandle.__index = es.EsHandle

function es.EsHandle.new(options)
    local self = {}
    setmetatable(self, es.EsHandle)
    self.optype = 'create'
    local zcurlopts = {
        timeout = 10,
        ssl_verifypeer = 0,
        ssl_verifyhost = 0,
        followlocation = true,
        failonerror = true,
        cookiefile = '', -- in memory cookies
        writefunction = ZCurl._store_response('body'),
    }
    for k,v in pairs(options) do
        if k:sub(1,5) == 'curl_' then zcurlopts['zcurl_exec_'..k:sub(6)] = v
        elseif k == 'header' then zcurlopts.httpheader = v
        elseif k == 'url' or k == 'indice' or k == 'optype' or k == 'doctype' then self[k] = v
        elseif k == 'api_key' then -- skip
        else zcurlopts[k] = v end
    end
    zcurlopts.httpheader = (zcurlopts.httpheader or {})
    if options.api_key then table.insert(zcurlopts.httpheader, 'authorization: ApiKey '..options.api_key) end

    local err
    self.zcurl, err = ZCurl.new_abstract(zcurlopts)
    if not self.zcurl then return nil, err end
    return self
end

function es.EsHandle:search(query, indice, expand_env)
    if type(query) ~= 'string' then query = cjson.encode(query) end
    if not indice then indice = self.indice end
    local query, err = lu.expand(query, expand_env, 'search',
        function(x) return (tostring(x):gsub('([\\"])', '\\%1')) end)
    if not query then return nil, err end

    local url = self.url..'/'..indice..'/_search'
    local httpheader = lu.acopy(self.zcurl:o('httpheader', {}), { 'content-type: application/json' })
    local verbose = self.zcurl:o('verbose')

    if verbose then perr('## POST %s\n%s', url, query) end
    local ret, err = self.zcurl:perform({ url = url, postfields = query, httpheader = httpheader })
    self.zcurl:resetopts()
    if not ret then return nil, err end

    if verbose then perr('## response\n%s', self.zcurl.response.body) end
    local data, err = cjson.decode(self.zcurl.response.body)
    if not data then return nil, err end
    return data
end

function es.EsHandle:bulk(docs, indice, optype, doctype)
    if #docs == 0 then return true end
    if not indice then indice = self.indice end
    if not optype then optype = self.optype end
    if not doctype then doctype = self.doctype end
    local url = self.url..'/'..indice..'/_bulk'
    local httpheader = self.zcurl:o('httpheader', {})
    table.insert(httpheader, 'content-type: application/x-ndjson')
    local verbose = self.zcurl:o('verbose')

    local post_data = ''
    for _,d in ipairs(docs) do
        if type(d) ~= 'string' then d = cjson.encode(d) end
        post_data = post_data..'{"'..optype..'":{'..
            (doctype and '"_type":"'..doctype..'"' or '')..'}}\n'..d..'\n'
    end
    if verbose then perr('## POST %s\n%s', url, post_data) end
    local ret, err = self.zcurl:perform({ url = url, postfields = post_data, httpheader = httpheader })
    self.zcurl:resetopts()
    if not ret then return nil, err end

    if verbose then perr('## response\n%s', self.zcurl.response.body) end
    local data, err = cjson.decode(self.zcurl.response.body)
    if not data then return nil, err end
    return data
end

function es.EsHandle:esql(query, expand_env, format)
    if not format then format = 'json' end
    if type(query) ~= 'string' then query = cjson.encode(query) end
    local query, err = lu.expand(query, expand_env, 'esql',
        function(x) return (tostring(x):gsub('([\\"])', '\\%1')) end)
    if not query then return nil, err end

    local url = self.url..'/_query?format='..format
    local httpheader = lu.acopy(self.zcurl:o('httpheader', {}), { 'content-type: application/json' })
    local verbose = self.zcurl:o('verbose')

    if verbose then perr('## POST %s\n%s', url, query) end
    local ret, err = self.zcurl:perform({ url = url, postfields = query, httpheader = httpheader })
    self.zcurl:resetopts()
    if not ret then return nil, err end

    local data = self.zcurl.response.body
    if verbose then perr('## response\n%s', data) end
    if format == 'json' then
        data, err = cjson.decode(self.zcurl.response.body)
        if not data then return nil, err end
    end
    return data
end

return es
