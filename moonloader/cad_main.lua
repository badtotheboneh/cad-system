_G.CAD_DIAGNOSTICS = {}
local script_running = true

local websocket_message_dispatcher

function shutdown()
    log('MAIN', log_levels.INFO, "------ CAD System Shutting Down ------")
    script_running = false
    
    if _G.CAD_DIAGNOSTICS and _G.CAD_DIAGNOSTICS.getDeps then
        local deps = _G.CAD_DIAGNOSTICS.getDeps()
        if deps.ui and deps.ui.shutdown then deps.ui.shutdown() end
        if deps.core and deps.core.shutdown then deps.core.shutdown() end
        if deps.websocket and deps.websocket.disconnect then deps.websocket.disconnect() end
    end
    
    log('MAIN', log_levels.INFO, "Shutdown complete.")
end

function script_unload()
    shutdown()
end

function main()
    local script_dir = thisScript().path:match([[^(.*[\/])]])
    package.path = package.path .. ';' .. script_dir .. '?.lua;' .. script_dir .. 'cad_system/?.lua;'
    package.cpath = package.cpath .. ';' .. script_dir .. 'lib/?.dll;'

    local common = require('cad_common_new')
    local log = common.log
    local log_levels = common.log_levels

    log('MAIN', log_levels.INFO, "------ CAD System Initializing ------")
    log('MAIN', log_levels.DEBUG, "Package path updated.")

    log('MAIN', log_levels.INFO, "Loading core libraries...")
    _G.CAD_EVENT_BUS = require('event_bus')
    local copas = require('copas')
    local json = common.json

    local deps = {
        events = _G.CAD_EVENT_BUS,
        copas = copas,
        log = log,
        log_levels = log_levels,
        json = common.json,
        safe_str = common.safe_str,
        cars = common.cars,
        safe_copy = common.safe_copy,
    }

    websocket_message_dispatcher = function(message_string)
        if not message_string or message_string == "" then return end

        local ok, response = pcall(json.decode, message_string)
        if not ok or type(response) ~= 'table' or not response.type then
            log('DISPATCHER', log_levels.WARN, "Invalid or non-JSON message received: " .. tostring(message_string))
            return
        end

        log('DISPATCHER', log_levels.DEBUG, "Dispatching message of type: " .. response.type)

        if response.type == 'rms_response' then
            _G.CAD_EVENT_BUS.trigger('rms:message', response)
        
        elseif response.type == 'data_response' or 
               response.type == 'data_broadcast' or 
               response.type == 'map_update' or
               response.type == 'unit_update' or
               response.type == 'map_response' or
               response.type == 'unitUpdate' or
               response.type == 'callUpdate' or
               response.type == 'incidentUpdate' or
               response.type == 'execute_chat_command' or
               response.type == 'force_radio_channel' or
               response.type == 'auth_response' or
               response.type == 'unit_response' or
               response.type == 'unit' or
               response.type == 'abas_response' or
               response.type == 'calls_response' or
               response.type == 'bolo_response' or
               response.type == 'show_notification' or
               response.type == 'tactical_response'
        then
                    _G.CAD_EVENT_BUS.trigger('core_ui:message', response)

        elseif response.type == 'radio_broadcast' then
            _G.CAD_EVENT_BUS.trigger('phantom_radio_message', response.payload)
        
        elseif response.type == 'radio_response' then
            log('DISPATCHER', log_levels.DEBUG, "Received radio_response acknowledgment.")

    else
        log('DISPATCHER', log_levels.WARN, "Unhandled message type: " .. response.type)
    end
    end

    log('MAIN', log_levels.INFO, "Loading system modules...")
    local modules_to_load = {
        'autoupdate', 'settings', 'websocket', 'core', 'ui', 'radio_parser', 'rms'
    }
    for _, name in ipairs(modules_to_load) do
        log('MAIN', log_levels.DEBUG, "Loading module: " .. name)
        
        local require_name
        if name == 'ui' then
            require_name = 'cadui'
        elseif name == 'radio_parser' then
            require_name = '_cadparserradio'
        else
            require_name = 'cad_' .. name
        end

        local ok, module = pcall(require, require_name)
        if ok then
            deps[name] = module
        else
            log('MAIN', log_levels.ERROR, string.format("Failed to load module '%s': %s", require_name, tostring(module)))
            if name == 'settings' or name == 'websocket' or name == 'ui' or name == 'core' then
                error("A critical module failed to load. Stopping script.")
            end
        end
    end
    log('MAIN', log_levels.INFO, "All available modules loaded.")

    log('MAIN', log_levels.INFO, "Initializing modules with dependencies...")
    if deps.settings and deps.settings.initialize then
        log('MAIN', log_levels.DEBUG, "Initializing module: settings")
        deps.settings.initialize()
    end
    for name, module in pairs(deps) do
        if name ~= 'settings' and name ~= 'core' and name ~= 'radio_parser' and type(module) == 'table' and module.initialize then
            log('MAIN', log_levels.DEBUG, "Initializing module: " .. name)
            module.initialize(deps)
        end
    end
    if deps.core and deps.core.initialize then
        log('MAIN', log_levels.DEBUG, "Initializing module: core")
        deps.core.initialize(deps)
    end
    if deps.radio_parser and deps.radio_parser.initialize then
        log('MAIN', log_levels.DEBUG, "Initializing module: radio_parser")
        local ok, err = pcall(deps.radio_parser.initialize, deps)
        if ok then
            log('MAIN', log_levels.INFO, "Radio parser initialized successfully.")
        else
            log('MAIN', log_levels.ERROR, "Radio parser failed to initialize: " .. tostring(err))
        end
    end
    log('MAIN', log_levels.INFO, "Core modules initialized.")

    log('MAIN', log_levels.INFO, "Registering WebSocket message dispatcher...")
    deps.events.register('websocket_message', websocket_message_dispatcher)

    log('MAIN', log_levels.INFO, "Attempting to connect to WebSocket server...")
    deps.websocket.connect()

    if not deps.core.tryAutoLogin() then
        log('MAIN', log_levels.INFO, "Auto-login failed, manual login required.")
    end

    log('MAIN', log_levels.INFO, "Initialization complete. Starting main loop.")

    _G.CAD_DIAGNOSTICS.getDeps = function() return deps end
    log('MAIN', log_levels.INFO, "Dependencies exposed for diagnostics.")

    local vkeys = require 'vkeys'
    
    local installed_version = "1.0.0"
    if deps.autoupdate then
        local installed_version = deps.autoupdate.version or "1.0.0"
        
        local ver_file = getWorkingDirectory() .. '/config/cad_installed_version.txt'
        local vf = io.open(ver_file, 'r')
        if vf then
          local saved_ver = vf:read('*a'):match('^%s*(.-)%s*$')
          if saved_ver and #saved_ver > 0 then
            installed_version = saved_ver
            os.remove(ver_file)
            deps.autoupdate.set_version(installed_version)
          end
          vf:close()
        end
        
        log('MAIN', log_levels.INFO, "Auto-update module detected, current version: " .. installed_version)
        log('MAIN', log_levels.INFO, "Starting version check.")
        deps.autoupdate.check_version()
    end
    
    local ffi = require('ffi')
    ffi.cdef[[
        typedef struct {
            unsigned int cbSize;
            unsigned int dwTime;
        } LASTINPUTINFO;
        int GetLastInputInfo(LASTINPUTINFO*);
        unsigned int GetTickCount(void);
    ]]
    local user32 = ffi.load('User32.dll')
    local kernel32 = ffi.load('Kernel32.dll')
    local function get_last_input_time()
        local info = ffi.new('LASTINPUTINFO')
        info.cbSize = ffi.sizeof(info)
        if user32.GetLastInputInfo(info) ~= 0 then
            return tonumber(info.dwTime)
        end
        return 0
    end
    local AFK_THRESHOLD_MS = 60 * 1000
    local AFK_CHECK_INTERVAL_MS = 500
    local last_afk_check_tick = 0
    local was_afk = false

    while script_running do
        copas.step(0)
        local now_tick = kernel32.GetTickCount()
        if now_tick - last_afk_check_tick >= AFK_CHECK_INTERVAL_MS then
            last_afk_check_tick = now_tick
            local last_input_time = get_last_input_time()
            local idle_time = 0
            if last_input_time ~= 0 then
                idle_time = now_tick - last_input_time
            end
            local is_afk = idle_time > AFK_THRESHOLD_MS
            if is_afk and not was_afk then
                log('MAIN', log_levels.INFO, "Player went AFK (idle for " .. (idle_time/1000) .. "s)")
            elseif not is_afk and was_afk then
                log('MAIN', log_levels.INFO, "Player returned from AFK (idle was " .. (idle_time/1000) .. "s)")
                if not (deps.websocket and deps.websocket.is_connected and deps.websocket.is_connected()) then
                    log('MAIN', log_levels.WARN, "WebSocket disconnected during AFK; reconnecting...")
                    deps.websocket.connect()
                end
                if deps.core and deps.core.isAuthenticated and deps.core:isAuthenticated() then
                    log('MAIN', log_levels.INFO, "Requesting unit data refresh after AFK")
                    deps.core.fetchUnitData()
                end
            end
            was_afk = is_afk
        end
        if deps.websocket then
            deps.websocket.process_messages()
        end
        
        wait(0)
    end
end