local BasePlugin = require "kong.plugins.base_plugin"
local CacheHandler = BasePlugin:extend()
local responses = require "kong.tools.responses"
local req_get_method = ngx.req.get_method

local redis = require "resty.redis"
local header_filter = require "kong.plugins.response-transformer.header_transformer"
local is_json_body = header_filter.is_json_body

local cjson_decode = require("cjson").decode
local cjson_encode = require("cjson").encode

local function cacheable_request(method, uri, conf)
  return true
end

local function get_cache_key(uri, headers, query_params, conf)
  local cache_key = uri
  
  table.sort(query_params)
  for _,param in ipairs(conf.cache_policy.vary_by_query_string_parameters) do
    local query_value = query_params[param]
    if query_value then
      if type(query_value) == "table" then
        table.sort(query_value)
        query_value = table.concat(query_value, ",")
      end
      ngx.log(ngx.NOTICE, "varying cache key by query string ("..param..":"..query_value..")")
      cache_key = cache_key..":"..param.."="..query_value
    end
  end

  table.sort(headers)
  for _,header in ipairs(conf.cache_policy.vary_by_headers) do
    local header_value = headers[header]
    if header_value then
      if type(header_value) == "table" then
        table.sort(header_value)
        header_value = table.concat(header_value, ",")
      end
      ngx.log(ngx.NOTICE, "varying cache key by matched header ("..header..":"..header_value..")")
      cache_key = cache_key..":"..header.."="..header_value
    end
  end
  
  return cache_key
end

local function json_decode(json)
  if json then
    local status, res = pcall(cjson_decode, json)
    if status then
      return res
    end
  end
end

local function json_encode(table)
  if table then
    local status, res = pcall(cjson_encode, table)
    if status then
      return res
    end
  end
end

local function connect_to_redis(conf)
  local red = redis:new()
  
  red:set_timeout(conf.redis_timeout)
  
  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if err then
    return nil, err
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local ok, err = red:auth(conf.redis_password)
    if err then
      return nil, err
    end
  end
  
  return red
end

local function red_set(premature, key, val, conf)
  local red, err = connect_to_redis(conf)
  if err then
      ngx.log(ngx.ERR, "failed to connect to Redis: ", err)
  end

  red:init_pipeline()
  red:set(key, val)
  if conf.cache_policy.duration_in_seconds then
    red:expire(key, conf.cache_policy.duration_in_seconds)
  end
  local results, err = red:commit_pipeline()
  if err then
    ngx.log(ngx.ERR, "failed to commit the pipelined requests: ", err)
  end
end

function CacheHandler:new()
  CacheHandler.super.new(self, "response-cache")
end

function CacheHandler:access(conf)

  ngx.log(ngx.NOTICE, "cache hittgdfhsghdfskjghkjs gs kjhfsgjk hksg dsjkfgjk 1 1 1 1")
  CacheHandler.super.access(self)

  
  ngx.log(ngx.NOTICE, "cache hittgdfhsghdfskjghkjs gs kjhfsgjk hksg dsjkfgjk")
  
  local uri = ngx.var.uri
  if not cacheable_request(req_get_method(), uri, conf) then
    ngx.log(ngx.NOTICE, "not cacheable")
    return
  end
  
  local cache_key = get_cache_key(uri, ngx.req.get_headers(), ngx.req.get_uri_args(), conf)  
  local red, err = connect_to_redis(conf)
  if err then
    ngx.log(ngx.ERR, "failed to connect to Redis: ", err)
    return
  end

  local cached_val, err = red:get(cache_key)
  if cached_val and cached_val ~= ngx.null then
    ngx.log(ngx.NOTICE, "cache hit")
    local val = json_decode(cached_val)
    -- for k,v in pairs(val.headers) do
    --   ngx.req.set_header(k, v)
    -- end
    return responses.send_HTTP_OK(val.content)

  end

  ngx.log(ngx.NOTICE, "cache miss")
  ngx.ctx.response_cache = {
    cache_key = cache_key
  }

end

function CacheHandler:header_filter(conf)
  CacheHandler.super.header_filter(self)

  local ctx = ngx.ctx.response_cache
  if not ctx then
    return
  end

  ctx.headers = ngx.resp.get_headers()
end

function CacheHandler:body_filter(conf)
  CacheHandler.super.body_filter(self)

  local ctx = ngx.ctx.response_cache
  if not ctx then
    return
  end

  local chunk = ngx.arg[1]
  local eof = ngx.arg[2]
  
  local res_body = ctx and ctx.res_body or ""
  res_body = res_body .. (chunk or "")
  ctx.res_body = res_body
  if eof then
    local content = json_decode(ctx.res_body)
    local value = { content = content, headers = ctx.headers }
    local value_json = json_encode(value)
    ngx.timer.at(0, red_set, ctx.cache_key, value_json, conf)
  end
end

return CacheHandler