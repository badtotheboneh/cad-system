
local ffi = require('ffi')
local imgui = require('mimgui')

local events, cad_websocket, json, log, log_levels, settings, copas
local heartbeat_thread = nil
local core = {}


core.current_user = nil
core.auth_token = nil
core.current_unit = nil
core.unit_logs = {}

core.system_override_plate = nil

core.session_logs = {}
core.target_unit_logs = {}

core.login_window = {
    username = imgui.new.char[64](),
    password = imgui.new.char[64](),
    error_message = "",
    is_logging_in = false
}

core.abas_data = {
    score = 1.0,
    today_time = 0,
    today_calls = 0
}

function core.fetchAbasData()
    if not core.isAuthenticated() then return end
    cad_websocket.send({
        type = 'abas',
        action = 'get_stats',
        token = core.getToken()
    })
end

function core.fetchUnitData()
    if not core.isAuthenticated() then
        log('CORE', log_levels.WARN, "fetchUnitData call ignored: not authenticated.")
        return
    end
    log('CORE', log_levels.INFO, "Fetching authoritative unit info from server...")
    local request = {
        type = 'unit',
        action = 'fetch_my_unit',
        token = core.getToken()
    }
    cad_websocket.send(request)
end

--[[function core.fetchUnitLogs(unit_id, context)
    if not core.isAuthenticated() then return end
    
    local request = {
        type = 'unit',
        action = 'get_logs',
        token = core.getToken(),
        payload = {
            unit_id = unit_id,
            context = context or 'profile'
        }
    }
    cad_websocket.send(request)
end]]

local function broadcastUnitUpdate()
    if not core.isAuthenticated() or not core.current_unit then
        log('CORE', log_levels.WARN, "broadcastUnitUpdate call ignored: not authenticated or no unit data.")
        return
    end
    
    log('CORE', log_levels.INFO, "Broadcasting local unit info to server for synchronization.")

    local payload_to_send = {}
    
    for key, value in pairs(core.current_unit) do
        payload_to_send[key] = value
    end

    if core.system_override_plate then
        payload_to_send.vehiclePlate = core.system_override_plate
        
        log('CORE', log_levels.INFO, "Packet Intercept: Replaced visual plate with system plate: " .. tostring(core.system_override_plate))
    end

    local request = {
        type = 'unit',
        action = 'form_or_update_crew',
        token = core.getToken(),
        payload = payload_to_send
    }

    if core.current_user and core.current_user.id then
        request.payload.user_id = core.current_user.id
        log('CORE', log_levels.INFO, "Final check: Injected user_id (" .. tostring(core.current_user.id) .. ") into outgoing unit payload.")
    else
        log('CORE', log_levels.WARN, "Final check: Could not inject user_id, core.current_user.id is nil.")
    end

    cad_websocket.send(request)
end

function core.startHeartbeat()
    if heartbeat_thread then return end
    
    heartbeat_thread = copas.addthread(function()
        while true do
            copas.sleep(30)
            
            if core.isAuthenticated() and cad_websocket.is_connected() then
                local request = {
                    type = 'system',
                    action = 'heartbeat',
                    token = core.getToken()
                }

                cad_websocket.send(request) 
            end
        end
    end)
end

local function handle_auth_response(data)
    if data.action == 'login' or data.action == 'login_with_token' then
        core.login_window.is_logging_in = false
        if data.success then
            log('CORE', log_levels.INFO, "Login successful for user: " .. data.user.username)
            core.current_user = data.user
            core.auth_token = data.token
            core.fetchAbasData()
            if data.unit and data.unit.id then

                core.current_unit = data.unit
                

                log('CORE', log_levels.INFO, "Login successful. Fetching logs for Unit ID: " .. tostring(data.unit.id))
                -- core.fetchUnitLogs(data.unit.id, 'profile')
            end
            core.startHeartbeat()

            if data.action == 'login' then
                settings.set("user_settings", "username", ffi.string(core.login_window.username))
                ffi.fill(core.login_window.password, ffi.sizeof(core.login_window.password), 0)
            end

            settings.set("user_settings", "token", core.auth_token)
            settings.set("user_settings", "currentUser", core.current_user)
            settings.save()

            _G.CAD_EVENT_BUS.trigger('auth_login_success')

            if data.user and data.user.subscriptions then
                _G.CAD_EVENT_BUS.trigger('radio:set_subscriptions', data.user.subscriptions)
            end
            _G.CAD_EVENT_BUS.trigger('radio:send_subscriptions')
        else
            core.login_window.error_message = data.error or "Unknown error"
            if data.action == 'login_with_token' then
                log('CORE', log_levels.WARN, "Login with token failed. Clearing session and requiring manual login.")
                core.current_user = nil
                core.auth_token = nil
                _G.CAD_EVENT_BUS.trigger('auth_logout')
            end
        end
    elseif data.action == 'validateToken' then 
        if data.success and data.user then
            log('CORE', log_levels.INFO, "Token validation successful.")

            core.startHeartbeat()

            core.current_user = data.user
            core.auth_token = data.token
            _G.CAD_EVENT_BUS.trigger('auth_login_success')
            if data.user and data.user.subscriptions then
                log('CORE', log_levels.DEBUG, "Received subscriptions from server: " .. json.encode(data.user.subscriptions))
                _G.CAD_EVENT_BUS.trigger('radio:set_subscriptions', data.user.subscriptions)
            else
                log('CORE', log_levels.DEBUG, "No subscriptions received from server for this user.")
            end
        else
            log('CORE', log_levels.WARN, "Token validation failed.")
            core.auth_token = nil
            core.current_user = nil
            settings.set("user_settings", "token", nil)
            settings.set("user_settings", "currentUser", nil)
            settings.save()
        end
    end
end

local function handle_unit_response(data)
    if data.success and data.payload then
        log('CORE', log_levels.INFO, "Unit operation successful.")
        core.current_unit = data.payload
        settings.saveUnitInfo(core.current_unit)
        settings.save()
        _G.CAD_EVENT_BUS.trigger('cad:unit_updated', data.payload)
        if core.current_unit and core.current_unit.id then
            log('CORE', log_levels.INFO, "Auto-fetching logs for unit ID: " .. core.current_unit.id)
            -- core.fetchUnitLogs(core.current_unit.id, 'profile')
        end
    elseif data.success then
        log('CORE', log_levels.WARN, "Unit operation successful but received no payload.")
    else
        log('CORE', log_levels.ERROR, "Unit operation failed: " .. (data.error or "Unknown error"))
        _G.CAD_EVENT_BUS.trigger('cad:unit_error', data.error)
    end
end

local function handle_websocket_message(data)
    if not data or not data.type then return end

    if data.type == 'auth_response' then
        handle_auth_response(data)

    elseif data.type == 'unit_response' then
        handle_unit_response(data)
        

    elseif data.type == 'unit' then

        --[[if data.action == 'logs_response' or data.action == 'get_logs' then
            if data.success then
                core.unit_logs = data.payload or {}
                core.session_logs = data.payload or {} 
                log('CORE', log_levels.INFO, "Logs received and updated. Count: " .. #core.unit_logs)
            else
                log('CORE', log_levels.ERROR, "Server returned error for logs: " .. (data.error or "Unknown"))
            end]]
        if data.action == 'unit_data_sync' then
            log('CORE', log_levels.INFO, "Received UNIT SYNC data.")
            
            local new_unit_data = data.data or data.payload 
            local sync_locked = false
            if _G.cadui_module and _G.cadui_module.isUnitConfigSyncLocked then
                sync_locked = _G.cadui_module.isUnitConfigSyncLocked()
            elseif cadui_module and cadui_module.isUnitConfigSyncLocked then
                sync_locked = cadui_module.isUnitConfigSyncLocked()
            end

            if sync_locked then
                log('CORE', log_levels.INFO, "Skipping UNIT SYNC apply: local status is Out of Service.")
                return
            end

            core.current_unit = new_unit_data

            local ui = _G.cadui_module
            

            if cadui_module and cadui_module.syncInputBuffers then
                cadui_module.syncInputBuffers(new_unit_data)
                log('CORE', log_levels.INFO, "Called syncInputBuffers")
            elseif _G.cadui_module and _G.cadui_module.syncInputBuffers then
                _G.cadui_module.syncInputBuffers(new_unit_data)
                log('CORE', log_levels.INFO, "Called _G.cadui_module.syncInputBuffers")
            else
                log('CORE', log_levels.ERROR, "CRITICAL: Could not find cadui_module!")
            end

        else
            log('CORE', log_levels.INFO, "Received unit action: " .. tostring(data.action))
        end
        elseif data.action == 'left_unit_success' then
            log('CORE', log_levels.INFO, "Successfully left unit. Clearing data.")
            

            if cadui_module and cadui_module.clearInterface then
                cadui_module.clearInterface()
            elseif _G.cadui_module and _G.cadui_module.clearInterface then
                _G.cadui_module.clearInterface()
            end
            

            core.current_unit = nil
            settings.saveUnitInfo()
elseif data.type == 'abas_response' then
        if data.payload then
            local stats = data.payload
            

            if not core.abas_data then core.abas_data = {} end
            

            core.abas_data.score = stats.abas or 1.0
            
            if stats.today then
                core.abas_data.today_time = stats.today.seconds_on_duty or 0
                core.abas_data.today_calls = stats.today.calls_responded or 0
            end
            

            core.abas_data.shift_start = stats.shift_start or "--:--"

            

            log('CORE', log_levels.INFO, string.format("ABAS Updated. Score: %s, Time: %s, Start: %s", 
                tostring(core.abas_data.score), 
                tostring(core.abas_data.today_time),
                tostring(core.abas_data.shift_start)
            ))
        end
    elseif data.type == 'calls_response' then
        if data.success and data.action == 'create' then
            log('CORE', log_levels.INFO, data.message or "Call created") 
        elseif not data.success then
            log('CORE', log_levels.ERROR, data.error or "Error creating call")
        end

    elseif data.type == 'bolo_response' then
        if data.success then
             log('CORE', log_levels.INFO, "BOLO action success.")
        end

    elseif data.type == 'show_notification' then
        if data.payload then
            _G.CAD_EVENT_BUS.trigger('ui:show_notification', data.payload)
        end
    end
end

function core.shutdown()
    log('CORE', log_levels.INFO, "Shutting down core module...")
    core.current_user = nil
    core.auth_token = nil
    core.current_unit = nil
end

function core.login(username, password)
    if not cad_websocket.is_connected() then
        core.login_window.error_message = "Not connected"
        return
    end
    log('CORE', log_levels.INFO, "Attempting login...")
    core.login_window.is_logging_in = true
    cad_websocket.send({ type = "auth", action = "login", username = username, password = password })
end

function core.logout()
    log('CORE', log_levels.INFO, "Logging out.")
    core.current_user = nil
    core.auth_token = nil
    core.current_unit = nil
    settings.set("user_settings", "token", nil)
    settings.set("user_settings", "currentUser", nil)
    settings.save()
    _G.CAD_EVENT_BUS.trigger('auth_logout')
end

function core.isAuthenticated() return core.current_user and core.auth_token end
function core.isUnitActive() return core.current_unit and (core.current_unit.is_active == 1 or core.current_unit.is_active == true) end
function core.getToken() return core.auth_token end

function core.loadAuthData()
    log('CORE', log_levels.INFO, "Loading auth data from settings...")
    local loaded_username = settings.get("user_settings", "username", "")
    ffi.copy(core.login_window.username, loaded_username)
    core.auth_token = settings.get("user_settings", "token", nil)
    if core.auth_token then
        log('CORE', log_levels.INFO, "Found stored auth token.")
    end
end

function core.tryAutoLogin()
    log('CORE', log_levels.INFO, "Checking for stored token for auto-login...")
    core.auth_token = settings.get("user_settings", "token", nil)
    core.current_user = settings.get("user_settings", "currentUser", nil)

    if core.auth_token and core.current_user then
        log('CORE', log_levels.INFO, "Found stored token and user data. Auto-login will proceed upon connection.")
        core.auto_login_pending = true
        return true
    else
        log('CORE', log_levels.INFO, "No stored token or user data found. Manual login required.")
        return false
    end
end



local function handle_data_error(err_data)
    if err_data and err_data.error and type(err_data.error) == 'string' and err_data.error:find("Invalid or expired token") then
        log('CORE', log_levels.WARN, "Server rejected token. Forcing logout.")
        core.logout()
    end
end

local function handleAddCall(callData)
    log('CORE', log_levels.DEBUG, "DEBUG: handleAddCall triggered at the very top.")
    if not core.isAuthenticated() then
        log('CORE', log_levels.WARN, "handleAddCall ignored: user not authenticated.")
        return
    end

    log('CORE', log_levels.INFO, "handleAddCall event received. Sending to server.")

    local request = {
        type = 'calls',
        action = 'create',
        token = core.getToken(),
        payload = {
            call_id = callData.server_call_id,
            server_call_id = callData.server_call_id,
            summary = callData.summary,
            location = callData.location,
            incident_details = callData.incident_details,
            caller_name = callData.caller_name,
            phone_number = callData.phone_number
        } 
    }
    
    cad_websocket.send(request)
end

local function handleAddBolo(boloData)
    log('CORE', log_levels.DEBUG, "DEBUG: handleAddBolo triggered at the very top.")
    if not core.isAuthenticated() then
        log('CORE', log_levels.WARN, "handleAddBolo ignored: user not authenticated.")
        return
    end

    log('CORE', log_levels.INFO, "handleAddBolo event received. Sending to server.")

    local request = {
        type = 'bolos',
        action = 'create',
        token = core.getToken(),
        payload = boloData
    }
    
    cad_websocket.send(request)
end



function core.initialize(deps)
    cad_websocket = deps.websocket
    json = deps.json
    log = deps.log
    log_levels = deps.log_levels
    settings = deps.settings
    copas = deps.copas
    
    core.loadAuthData()

    _G.CAD_EVENT_BUS.register('core_ui:message', handle_websocket_message)
    _G.CAD_EVENT_BUS.register('cad:data_error', handle_data_error)
    _G.CAD_EVENT_BUS.register('cad:addCall', handleAddCall)
    _G.CAD_EVENT_BUS.register('cad:addBolo', handleAddBolo)

    _G.CAD_EVENT_BUS.register('websocket_connected', function()
        if core.auto_login_pending then
            log('CORE', log_levels.INFO, "WebSocket connected, attempting auto-login with token.")
            core.auto_login_pending = false
            if core.auth_token then
                core.startHeartbeat()
                cad_websocket.send({
                    type = "auth",
                    action = "login_with_token",
                    token = core.auth_token
                })
            else
                log('CORE', log_levels.WARN, "Auto-login pending but no token found.")
            end
        end
    end)

    log('CORE', log_levels.INFO, "Module initialized.")
end

return core
