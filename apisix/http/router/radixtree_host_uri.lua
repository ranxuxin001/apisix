--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local require = require
local router = require("apisix.utils.router")
local core = require("apisix.core")
local event = require("apisix.core.event")
local get_services = require("apisix.http.service").services
local service_fetch = require("apisix.http.service").get
local ar = require("apisix.router")
local table = require("apisix.core.table")
local json = require("apisix.core.json")
local rdx = require("resty.radixtree")
local ipairs = ipairs
local type = type
local tab_insert = table.insert
local loadstring = loadstring
local pairs = pairs
local cached_router_version
local cached_service_version
local host_router
local only_uri_router


local _M = {version = 0.1}


local function push_host_router(route, host_routes, only_uri_routes)
    if route == nil or (type(route) ~= "table" or  route.value == nil) then
        return
    end

    local filter_fun, err
    if route.value.filter_func then
        filter_fun, err = loadstring(
                                "return " .. route.value.filter_func,
                                "router#" .. route.value.id)
        if not filter_fun then
            core.log.error("failed to load filter function: ", err,
                            " route id: ", route.value.id)
            return
        end

        filter_fun = filter_fun()
    end

    local hosts = route.value.hosts
    if not hosts then
        if route.value.host then
            hosts = {route.value.host}
        elseif route.value.service_id then
            local service = service_fetch(route.value.service_id)
            if not service then
                core.log.error("failed to fetch service configuration by ",
                                "id: ", route.value.service_id)
                -- we keep the behavior that missing service won't affect the route matching
            else
                hosts = service.value.hosts
            end
        end
    end

    local radixtree_route = {
        id = route.value.id,
        paths = route.value.uris or route.value.uri,
        methods = route.value.methods,
        priority = route.value.priority,
        remote_addrs = route.value.remote_addrs
                       or route.value.remote_addr,
        vars = route.value.vars,
        filter_fun = filter_fun,
        handler = function (api_ctx, match_opts)
            api_ctx.matched_params = nil
            api_ctx.matched_route = route
            api_ctx.curr_req_matched = match_opts.matched
            api_ctx.real_curr_req_matched_path = match_opts.matched._path
        end
    }

    if hosts == nil then
        core.table.insert(only_uri_routes, radixtree_route)
        return
    end

    local rev = {}
    for i, h in ipairs(hosts) do
        tab_insert(rev, h:reverse())
    end

    core.table.insert(host_routes, {
        rev = rev,
        route = radixtree_route
    })
end


local function create_radixtree_router(routes)
    local host_routes = {}
    local only_uri_routes = {}
    host_router = nil
    routes = routes or {}

    for _, route in ipairs(routes) do
        local status = core.table.try_read_attr(route, "value", "status")
        -- check the status
        if not status or status == 1 then
            push_host_router(route, host_routes, only_uri_routes)
        end
    end

    local host_router_routes = {}
    for i, hr in ipairs(host_routes) do
        local sub_router = router.new(hr["route"])

        core.table.insert(host_router_routes, {
            id = hr["route"]["id"],
            paths = hr["rev"],
            filter_fun = function(vars, opts, ...)
                return sub_router:dispatch(vars.uri, opts, ...)
            end,
            handler = function (api_ctx, match_opts)
                api_ctx.real_curr_req_matched_host = match_opts.matched._path
            end
        })
    end

    event.push(event.CONST.BUILD_ROUTER, routes)

    if #host_router_routes > 0 then
        host_router = router.new(host_router_routes)
    end

    -- create router: only_uri_router
    only_uri_router = router.new(only_uri_routes)
    return true
end


local function incremental_operate_radixtree(routes)
    if ar.need_create_radixtree then
        core.log.notice("create object of radixtree host uri after load_full_data or init.", #routes)
        create_radixtree_router(routes)
        ar.need_create_radixtree = false
        table.clear(ar.sync_tb)
        return
    end

    local op, route, last_route
    local router_opts = {
        no_param_match = true
    }

    event.push(event.CONST.BUILD_ROUTER, routes)
    for k, _ in pairs(ar.sync_tb) do
        op = ar.sync_tb[k]["op"]
        route = ar.sync_tb[k]["outer_routeoute"]
        last_route = ar.sync_tb[k]["last_route"]
        local host_routes = {}
        local only_uri_routes = {}
        local last_host_routes = {}
        local last_only_uri_routes = {}
        local outer_route, last_outer_route = {paths={}}, {paths={}}
        local inner_route, last_inner_route = {}, {}
        local sub_router

        push_host_router(route, host_routes, only_uri_routes)
        push_host_router(last_route, last_host_routes, last_only_uri_routes)

        if #host_routes > 0 or #last_host_routes > 0 then
            if route then
                if #host_routes > 0 then
                    inner_route = host_routes[1]["route"]
                end

                if #last_host_routes > 0 then
                    last_inner_route = last_host_routes[1]["route"]
                    last_outer_route = {
                        id = last_route.value.id,
                        paths = last_host_routes[1]["rev"],
                    }
                end

                sub_router = router.new(inner_route)

                outer_route =  {
                    id = route.value.id,
                    paths = host_routes[1]["rev"],
                    filter_fun = function(vars, opts, ...)
                        return sub_router:dispatch(vars.uri, opts, ...)
                    end,
                    handler = function (api_ctx, match_opts)
                        api_ctx.real_curr_req_matched_host = match_opts.matched._path
                    end
                }
            end

            core.log.notice("update routes watched from etcd into radixtree.", json.encode(route))
            local err = host_router:update_route(last_outer_route, outer_route, router_opts)
            if err ~= nil then
                core.log.error("update a route into radixtree failed.", json.encode(route), err)
                return
            end
        else
            local cur_tmp = only_uri_routes[1] or {paths = {}}
            local last_tmp = last_only_uri_routes[1] or {paths = {}}

            core.log.notice("update routes watched from etcd into radixtree.", json.encode(route))
            local err = only_uri_router:update_route(last_tmp, cur_tmp, router_opts)
            if err ~= nil then
                core.log.error("update a route into radixtree failed.", json.encode(route), err)
                return
            end
        end

        ar.sync_tb[k] = nil
    end
end


    local match_opts = {}
function _M.match(api_ctx)
    local user_routes = _M.user_routes
    local _, service_version = get_services()
    if not cached_router_version or cached_router_version ~= user_routes.conf_version
        or not cached_service_version or cached_service_version ~= service_version
    then
        --create_radixtree_router(user_routes.values)
        incremental_operate_radixtree(user_routes.values)
        cached_router_version = user_routes.conf_version
        cached_service_version = service_version
    end

    return _M.matching(api_ctx)
end


function _M.matching(api_ctx)
    core.log.info("route match mode: radixtree_host_uri")

    core.table.clear(match_opts)
    match_opts.method = api_ctx.var.request_method
    match_opts.remote_addr = api_ctx.var.remote_addr
    match_opts.vars = api_ctx.var
    match_opts.host = api_ctx.var.host
    match_opts.matched = core.tablepool.fetch("matched_route_record", 0, 4)

    if host_router then
        local host_uri = api_ctx.var.host
        local ok = host_router:dispatch(host_uri:reverse(), match_opts, api_ctx, match_opts)
        if ok then
            if api_ctx.real_curr_req_matched_path then
                api_ctx.curr_req_matched._path = api_ctx.real_curr_req_matched_path
                api_ctx.real_curr_req_matched_path = nil
            end
            if api_ctx.real_curr_req_matched_host then
                api_ctx.curr_req_matched._host = api_ctx.real_curr_req_matched_host:reverse()
                api_ctx.real_curr_req_matched_host = nil
            end
            return true
        end
    end

    local ok = only_uri_router:dispatch(api_ctx.var.uri, match_opts, api_ctx, match_opts)
    return ok
end


return _M
