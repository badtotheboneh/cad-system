local cadui_module = {}
_G.cadui_module = cadui_module

local ffi = require('ffi')
local bit = require('bit')
samp_events = require 'samp.events'
imgui = require 'mimgui'
local memory = require 'memory'
local vkeys = require 'vkeys'
local sampfuncs = require 'sampfuncs' 


profileEditBuffers = {
    full_name = imgui.new.char[64](),
    badge = imgui.new.char[32](),
    phone = imgui.new.char[32]()
}

local profile_buffers_init = false

local fa = {
    ICON_FA_HOUSE = '\xef\x80\x95',                -- f015
    ICON_FA_TABLE_LIST = '\xef\x80\x8b',           -- f00b
    ICON_FA_TRIANGLE_EXCLAMATION = '\xef\x81\xb1', -- f071
    ICON_FA_CAR_SIDE = '\xef\x97\xa4',             -- f5e4
    ICON_FA_ID_CARD = '\xef\x8b\x82',              -- f2c2
    ICON_FA_GEARS = '\xef\x82\x85',                -- f085
    ICON_FA_XMARK = '\xef\x80\x8d',                -- f00d
    ICON_FA_USER_SHIELD = '\xef\x94\x85',          -- f505
    ICON_FA_LOCATION_DOT = '\xef\x8f\x85',         -- f3c5
    ICON_FA_RIGHT_FROM_BRACKET = '\xef\x8b\xb5',   -- f2f5
    ICON_FA_USER = '\xef\x80\x87',                 -- f007
    
    ICON_FA_CIRCLE_QUESTION = '\xef\x81\x99',      -- f059
    ICON_FA_PHONE = '\xef\x82\x95',                -- f095
    ICON_FA_WALKIE_TALKIE = '\xef\x96\x9f',        -- f59f
    ICON_FA_SHIELD_HALVED = '\xef\x8f\xad',        -- f3ed
    ICON_FA_HEART = '\xef\x80\x84',                -- f004

    ICON_FA_CHECK_SQUARE = '\xef\x85\x8a',
    ICON_FA_SQUARE = '\xef\x83\x88',
    
    min_range = 0xe000,
    max_range = 0xf8ff
}
local fonts = {}
local claimed_vehicle = nil
local assigned_vehicle_id = nil

events, core, cad_websocket, json, settings, copas, log, log_levels, safe_str, cars, safe_copy, autoupdate = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
optimistic_accept_assist = nil

fetchMyUnitData, fetchCalls, fetchBolos, fetchUnits = nil, nil, nil, nil


local ThemeManager = {
    color_keys = {
        "Text", "TextDisabled", "WindowBg", "ChildBg", "PopupBg", "Border", "BorderShadow",
        "FrameBg", "FrameBgHovered", "FrameBgActive", "TitleBg", "TitleBgActive", "TitleBgCollapsed",
        "MenuBarBg", "ScrollbarBg", "ScrollbarGrab", "ScrollbarGrabHovered", "ScrollbarGrabActive",
        "CheckMark", "SliderGrab", "SliderGrabActive", "Button", "ButtonHovered", "ButtonActive",
        "Header", "HeaderHovered", "HeaderActive", "Separator", "SeparatorHovered", "SeparatorActive",
        "ResizeGrip", "ResizeGripHovered", "ResizeGripActive", "Tab", "TabHovered", "TabActive",
        "TabUnfocused", "TabUnfocusedActive", "PlotLines", "PlotLinesHovered", "PlotHistogram",
        "PlotHistogramHovered", "TextSelectedBg", "DragDropTarget", "NavHighlight", "NavWindowingHighlight",
        "NavWindowingDimBg", "ModalWindowDimBg"
    },
    current_theme = {},
    color_buffers = {}
}

function ToMSK(date_str)
    if not date_str or date_str == "" then return "N/A" end
    
    local year, month, day, hour, min, sec = date_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    
    if year then
        local ts = os.time({
            year = tonumber(year),
            month = tonumber(month),
            day = tonumber(day),
            hour = tonumber(hour),
            min = tonumber(min),
            sec = tonumber(sec)
        })
        
        ts = ts + (3 * 3600)
        
        return os.date("%Y-%m-%d %H:%M:%S", ts)
    end
    
    return date_str
end

function ThemeManager.initialize()
    log('ThemeManager', log_levels.INFO, 'Initializing themes...')
    local style = imgui.GetStyle()
    local saved_theme = settings.get('theme_settings', 'custom_theme', {})

    for _, key in ipairs(ThemeManager.color_keys) do
        local color_id = imgui.Col[key]
        if color_id then
            local saved_color = saved_theme[key]
            if saved_color and type(saved_color) == 'table' and #saved_color == 4 then
                ThemeManager.current_theme[key] = imgui.ImVec4(saved_color[1], saved_color[2], saved_color[3], saved_color[4])
            else
                ThemeManager.current_theme[key] = style.Colors[color_id]
            end

            local col = ThemeManager.current_theme[key]
            ThemeManager.color_buffers[key] = imgui.new.float[4](col.x, col.y, col.z, col.w)
        end
    end
    ThemeManager.applyCurrentTheme()
end

function ThemeManager.applyCurrentTheme()
    local style = imgui.GetStyle()
    for key, color_vec4 in pairs(ThemeManager.current_theme) do
        local color_id = imgui.Col[key]
        if color_id then
            style.Colors[color_id] = color_vec4
        end
    end
end

function ThemeManager.saveTheme()
    log('ThemeManager', log_levels.INFO, 'Saving custom theme...')
    local theme_to_save = {}
    for key, buffer in pairs(ThemeManager.color_buffers) do
        theme_to_save[key] = {buffer[0], buffer[1], buffer[2], buffer[3]}
        ThemeManager.current_theme[key] = imgui.ImVec4(buffer[0], buffer[1], buffer[2], buffer[3])
    end
    settings.set('theme_settings', 'custom_theme', theme_to_save)
    settings.save()
    ThemeManager.applyCurrentTheme()
    addNotification("Theme Manager", "Тема успешно сохранена.", 5)
end

function ThemeManager.resetTheme()
    log('ThemeManager', log_levels.INFO, 'Resetting theme to default.')
    settings.set('theme_settings', 'custom_theme', {})
    settings.save()

    local default_style = imgui.ImGuiStyle()
    local style = imgui.GetStyle()

    for _, key in ipairs(ThemeManager.color_keys) do
        local color_id = imgui.Col[key]
        if color_id then
            local default_color = default_style.Colors[color_id]
            ThemeManager.current_theme[key] = default_color
            ThemeManager.color_buffers[key][0] = default_color.x
            ThemeManager.color_buffers[key][1] = default_color.y
            ThemeManager.color_buffers[key][2] = default_color.z
            ThemeManager.color_buffers[key][3] = default_color.w
        end
    end
    ThemeManager.applyCurrentTheme()
end

fixed_radio_channels = {
    { id = "r1", name = "A-TAC 1", freq = "912.120" },
    { id = "r2", name = "A-TAC 2", freq = "912.115" },
    { id = "r3", name = "50 EMERGENCY", freq = "912.100" },
    { id = "r4", name = "DISPATCH 11", freq = "912.200" }
}

local radio_subscription_state = { true, true, true, true }
local radio_channels = {} 
local radio_buffers = {}


function saveRadioChannels()
    local to_save = {}
    for i = 1, 5 do
        table.insert(to_save, {
            name = safe_str(radio_buffers[i].name),
            freq = safe_str(radio_buffers[i].freq)
        })
    end
    settings.set('radio_settings', 'channels', to_save)
    settings.save()
end

passwordChangeBuffers = {
    old_password = imgui.new.char[64](),
    new_password = imgui.new.char[64](),
    confirm_password = imgui.new.char[64](),
    status_message = "",
    is_error = false
}

fullNameChangeBuffers = {
    first_name = imgui.new.char[64](),
    last_name = imgui.new.char[64](),
    status_message = "",
    is_error = false
}

local discord_auth = {
    code = imgui.new.char[7](),
    discord_id = nil,
    avatar_url = nil,
    avatar_texture = nil,
    characters = {},
    state = 'login',
    error_message = "",
    is_loading = false
}

registration_buffers = {
    full_name = imgui.new.char[64](),
    badge = imgui.new.char[32](),
    is_loading = false,
    error = ""
}

function trim_ws(value)
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

function split_full_name(full_name)
    local normalized = trim_ws(full_name or ""):gsub("%s+", " ")
    if normalized == "" then return "", "" end
    local first, rest = normalized:match("^(%S+)%s*(.-)$")
    return first or "", rest or ""
end

function fill_full_name_buffers(full_name)
    if not safe_copy then return end
    local first, last = split_full_name(full_name or "")
    safe_copy(fullNameChangeBuffers.first_name, first or "")
    safe_copy(fullNameChangeBuffers.last_name, last or "")
end


local BinderManager = {
    binds = {},
    key_states = {},
    is_binding_key = false,
    current_bind_index = nil,
    key_names_by_code = {},
    last_bind_execution_time = 0,
    bind_debounce_time = 0.2
}

local trigger_notification_action

function BinderManager.keysToString(keys_table)
    if not keys_table or #keys_table == 0 then return "Не назначено" end
    
    local parts = {}
    local modifiers = {}
    local main_keys = {}

    for _, key_code in ipairs(keys_table) do
        local name = BinderManager.key_names_by_code[key_code] or string.format("[0x%X]", key_code)
        if name == "CONTROL" or name == "LCONTROL" or name == "RCONTROL" or name == "SHIFT" or name == "LSHIFT" or name == "RSHIFT" or name == "MENU" or name == "LMENU" or name == "RMENU" then
            if name:find("CONTROL") then name = "CTRL" end
            if name:find("SHIFT") then name = "SHIFT" end
            if name:find("MENU") then name = "ALT" end
            local already_exists = false
            for _, mod in ipairs(modifiers) do
                if mod == name then already_exists = true; break end
            end
            if not already_exists then
                 table.insert(modifiers, name)
            end
        else
            table.insert(main_keys, name)
        end
    end
    
    table.sort(modifiers)
    
    for _, mod_name in ipairs(modifiers) do
        table.insert(parts, mod_name)
    end
    for _, key_name in ipairs(main_keys) do
        table.insert(parts, key_name)
    end

    return table.concat(parts, " + ")
end

local function get_bind_keys_by_id(bind_id)
    if not bind_id or not BinderManager or not BinderManager.binds then return nil end
    for _, bind in ipairs(BinderManager.binds) do
        if bind.id == bind_id then
            return bind.keys
        end
    end
    return nil
end

local system_bind_definitions = {
    { id = "toggle_mdt", title = "Toggle Main Window", default_keys = {vkeys.VK_F2} },
    { id = "toggle_alpr", title = "Toggle ALPR", default_keys = {} },
    { id = "toggle_map", title = "Toggle Map", default_keys = {} },
    { id = "popup_accept", title = "Request Accept", default_keys = {vkeys.VK_Y} },
    { id = "popup_decline", title = "Request Decline", default_keys = {vkeys.VK_N} }
}

function BinderManager.initialize()
    log('BinderManager', log_levels.INFO, 'Initializing binds...')
    
    for name, code in pairs(vkeys) do
        if type(code) == 'number' then
            BinderManager.key_names_by_code[code] = name:gsub("VK_", "")
        end
    end

    BinderManager.binds = settings.get('binder_settings', 'binds', {})
    -- log('BinderManager', log_levels.INFO, 'Loaded binds from config: ' .. json.encode(BinderManager.binds))

    for _, sys_def in ipairs(system_bind_definitions) do
        local found = false
        for _, existing_bind in ipairs(BinderManager.binds) do
            if existing_bind.id == sys_def.id then
                existing_bind.is_system = true
                existing_bind.title = sys_def.title
                found = true
                break
            end
        end
        if not found then
            table.insert(BinderManager.binds, {
                id = sys_def.id,
                title = sys_def.title,
                command = "",
                keys = sys_def.default_keys,
                is_system = true
            })
        end
    end
end

function BinderManager.saveBinds()
    log('BinderManager', log_levels.INFO, 'Saving binds...')
    settings.set('binder_settings', 'binds', BinderManager.binds)
    settings.save()
end

function BinderManager.addBind()
    local new_bind = {
        id = "custom_" .. os.time() .. math.random(100, 999),
        title = "New Bind " .. (#BinderManager.binds + 1),
        command = "/say example",
        keys = {},
        is_system = false
    }
    table.insert(BinderManager.binds, new_bind)
    BinderManager.saveBinds()
end

function BinderManager.removeBind(index)
    if BinderManager.binds[index] and not BinderManager.binds[index].is_system then
        table.remove(BinderManager.binds, index)
        BinderManager.saveBinds()
    end
end

function BinderManager.setKeysForBind(index, keys)
    if BinderManager.binds[index] then
        BinderManager.binds[index].keys = keys
        BinderManager.saveBinds()
        log('BinderManager', log_levels.INFO, string.format("Set keys for bind %s: %s", BinderManager.binds[index].title, table.concat(keys, "+")))
    end
end

function cadui_module.clearInterface()
    log('UI', log_levels.INFO, "Clearing interface buffers...")
    
    core.current_unit = nil
    
    safe_copy(unitInfoBuffers.vehiclePlate, "")
    safe_copy(unitInfoBuffers.notes, "")
    safe_copy(unitInfoBuffers.officer2_name, "")
    safe_copy(unitInfoBuffers.officer2_phone, "")
    safe_copy(unitInfoBuffers.unitID, "")
    
    unitInfoBuffers.division[0] = 0
    unitInfoBuffers.status[0] = 0
    unitInfoBuffers.base_radio_slot[0] = 1

    if vehicleEquipment then
        vehicleEquipment.ar15[0] = false
        vehicleEquipment.ll40mm[0] = false
        vehicleEquipment.beanbag[0] = false
        vehicleEquipment.riot_shield[0] = false
        vehicleEquipment.spikes[0] = false
        vehicleEquipment.narcan[0] = false
        vehicleEquipment.pit_auth[0] = false
        vehicleEquipment.aed[0] = false
    end
end

function BinderManager.executeBind(bind)
    local current_time = os.clock()
    if current_time - BinderManager.last_bind_execution_time < BinderManager.bind_debounce_time then
        return
    end
    BinderManager.last_bind_execution_time = current_time

    if bind.is_system then
        log('BinderManager', log_levels.INFO, string.format("Executing system action: %s", bind.title))
        if bind.id == "toggle_mdt" then
            cadui_module.toggleMDT()
        elseif bind.id == "toggle_alpr" then
            cadui_module.toggleALPR()
        elseif bind.id == "toggle_map" then
            cadui_module.toggleMap()
        elseif bind.id == "popup_accept" then
            if not trigger_notification_action(1) then
                log('BinderManager', log_levels.DEBUG, 'No notification to accept.')
            end
        elseif bind.id == "popup_decline" then
            if not trigger_notification_action(2) then
                log('BinderManager', log_levels.DEBUG, 'No notification to decline.')
            end
        end
    else
        log('BinderManager', log_levels.INFO, string.format("Executing command bind: %s", bind.command))
        local command_to_execute = bind.command
        if command_to_execute and command_to_execute ~= "" then
            if command_to_execute:sub(1, 1) == "/" then
                sampSendChat(command_to_execute)
            else
                sampSay(command_to_execute)
            end
        end
    end
end

function BinderManager.checkHotkeys()
    log('BinderManager', log_levels.DEBUG, 'checkHotkeys called')

    if BinderManager.is_binding_key then return end

    local modifier_keys_map = {
        [vkeys.VK_CONTROL] = true, [vkeys.VK_LCONTROL] = true, [vkeys.VK_RCONTROL] = true,
        [vkeys.VK_SHIFT] = true, [vkeys.VK_LSHIFT] = true, [vkeys.VK_RSHIFT] = true,
        [vkeys.VK_MENU] = true, [vkeys.VK_LMENU] = true, [vkeys.VK_RMENU] = true
    }

    for _, bind in ipairs(BinderManager.binds) do
        if #bind.keys > 0 then
            local trigger_key = nil
            local bind_modifiers = {}

            for _, key_code in ipairs(bind.keys) do
                if modifier_keys_map[key_code] then
                    table.insert(bind_modifiers, key_code)
                else
                    trigger_key = key_code
                end
            end

            if trigger_key then
                local all_modifiers_held = true
                for _, mod_key in ipairs(bind_modifiers) do
                    if not imgui.IsKeyDown(mod_key) then
                        all_modifiers_held = false
                        break
                    end
                end

                if all_modifiers_held and imgui.IsKeyPressed(trigger_key, false) then
                    log('BinderManager', log_levels.INFO, 'Hotkey combination detected, executing bind: ' .. bind.title)
                    BinderManager.executeBind(bind)
                end
            end
        end
    end
end

function BinderManager.handleKeyBindingInput()
    if not BinderManager.is_binding_key or not BinderManager.current_bind_index then return end

    if imgui.IsKeyPressed(vkeys.VK_ESCAPE, false) then
        BinderManager.is_binding_key = false
        BinderManager.current_bind_index = nil
        return
    end

    local modifier_keys_map = {
        [vkeys.VK_CONTROL] = true, [vkeys.VK_LCONTROL] = true, [vkeys.VK_RCONTROL] = true,
        [vkeys.VK_SHIFT] = true, [vkeys.VK_LSHIFT] = true, [vkeys.VK_RSHIFT] = true,
        [vkeys.VK_MENU] = true, [vkeys.VK_LMENU] = true, [vkeys.VK_RMENU] = true
    }
    local ignored_keys = {
        [vkeys.VK_ESCAPE] = true, [vkeys.VK_LBUTTON] = true, [vkeys.VK_RBUTTON] = true,
        [vkeys.VK_MBUTTON] = true, [vkeys.VK_XBUTTON1] = true, [vkeys.VK_XBUTTON2] = true
    }

    local trigger_key_pressed = nil
    for _, key_code in pairs(vkeys) do
        if type(key_code) == 'number' and not modifier_keys_map[key_code] and not ignored_keys[key_code] then
            if imgui.IsKeyPressed(key_code, false) then
                trigger_key_pressed = key_code
                break
            end
        end
    end

    if trigger_key_pressed then
        local final_keys = {}
        if imgui.IsKeyDown(vkeys.VK_CONTROL) then table.insert(final_keys, vkeys.VK_CONTROL) end
        if imgui.IsKeyDown(vkeys.VK_SHIFT) then table.insert(final_keys, vkeys.VK_SHIFT) end
        if imgui.IsKeyDown(vkeys.VK_MENU) then table.insert(final_keys, vkeys.VK_MENU) end

        table.insert(final_keys, trigger_key_pressed)

        BinderManager.setKeysForBind(BinderManager.current_bind_index, final_keys)
        BinderManager.is_binding_key = false
        BinderManager.current_bind_index = nil
    end
end


function cadui_module.syncInputBuffers(unit_data)
    if not unit_data then return end

    if unitInfoBuffers and unitInfoBuffers.status and unitInfoBuffers.status[0] == 4 then
        log('UI', log_levels.INFO, "Skipped UNIT CONFIGURATION sync: local status is Out of Service.")
        return
    end

    log('UI', log_levels.INFO, "Syncing UI buffers... Status: " .. tostring(unit_data.status))

    local off1_name = unit_data.officer1_name
    if off1_name == "None" then off1_name = "" end
    if not is_unit_field_dirty("officer1_name") then
        safe_copy(unitInfoBuffers.officer1_name, off1_name or "")
    end

    local off1_phone = unit_data.officer1_phone
    if off1_phone == "None" then off1_phone = "" end
    if not is_unit_field_dirty("officer1_phone") then
        safe_copy(unitInfoBuffers.officer1_phone, off1_phone or "")
    end

    if not is_unit_field_dirty("notes") then
        safe_copy(unitInfoBuffers.notes, unit_data.notes or "")
    end
    local off2 = unit_data.officer2_name
    if off2 == "None" then off2 = "" end
    if not is_unit_field_dirty("officer2_name") then
        safe_copy(unitInfoBuffers.officer2_name, off2 or "")
    end

    local off2_phone = unit_data.officer2_phone
    if off2_phone == "None" then off2_phone = "" end
    if not is_unit_field_dirty("officer2_phone") then
        safe_copy(unitInfoBuffers.officer2_phone, off2_phone or "")
    end
    
    local plate = unit_data.vehiclePlate
    if plate == "None" then plate = "" end
    if not is_unit_field_dirty("vehiclePlate") then
        safe_copy(unitInfoBuffers.vehiclePlate, plate or "")
    end

    if unit_data.division then
        if not is_unit_field_dirty("division") then
            unitInfoBuffers.division[0] = tonumber(unit_data.division) 
        end
    end
    

    if unit_data.status then
        if not is_unit_field_dirty("status") then
            unitInfoBuffers.status[0] = tonumber(unit_data.status)
        end
    end
    
    if unit_data.shift then
        if not is_unit_field_dirty("shift") then
            unitInfoBuffers.shift[0] = tonumber(unit_data.shift)
        end
    end

    if unit_data.base_radio_slot then
        if not is_unit_field_dirty("base_radio_slot") then
            unitInfoBuffers.base_radio_slot[0] = tonumber(unit_data.base_radio_slot)
        end
    end



    local function to_bool(val) return (val == 1 or val == true or val == "1") end


    if vehicleEquipment then
        vehicleEquipment.ar15[0]        = to_bool(unit_data.ar15)
        vehicleEquipment.ll40mm[0]      = to_bool(unit_data.ll40mm)
        vehicleEquipment.beanbag[0]     = to_bool(unit_data.beanbag)
        vehicleEquipment.riot_shield[0] = to_bool(unit_data.riot_shield)
        vehicleEquipment.spikes[0]      = to_bool(unit_data.spikes)
        vehicleEquipment.narcan[0]      = to_bool(unit_data.narcan)
        vehicleEquipment.pit_auth[0]    = to_bool(unit_data.pit_auth)
        vehicleEquipment.aed[0]         = to_bool(unit_data.aed)
    end
end


binderEditBuffers = {
    selected_index = -1,
    title = imgui.new.char[128](),
    command = imgui.new.char[256]()
}


function loadBindIntoBuffers(index)
    if BinderManager.binds[index] then
        binderEditBuffers.selected_index = index
        safe_copy(binderEditBuffers.title, BinderManager.binds[index].title or "")
        safe_copy(binderEditBuffers.command, BinderManager.binds[index].command or "")
    end
end


local request_callbacks = {}
local request_callbacks_meta = {}
local request_id_counter = 0
local REQUEST_CALLBACK_TIMEOUT_SEC = 60
local request_callbacks_last_cleanup = 0
local force_refresh_state = { in_flight = false, pending = false }
local pending_incident_marker_seed = {
    active = false,
    until_ts = 0,
    reason = nil
}
local arm_pending_incident_marker_seed
local consume_pending_incident_marker_seed

local function cleanup_stale_request_callbacks()
    local now = os.clock()
    if now - request_callbacks_last_cleanup < 1.0 then
        return
    end
    request_callbacks_last_cleanup = now

    for request_id, callback in pairs(request_callbacks) do
        local meta = request_callbacks_meta[request_id]
        if meta and (now - meta.created_at) > REQUEST_CALLBACK_TIMEOUT_SEC then
            request_callbacks[request_id] = nil
            request_callbacks_meta[request_id] = nil
            log('UI', log_levels.DEBUG, string.format(
                "Request timeout: %s/%s (ID: %s)",
                tostring(meta.type), tostring(meta.action), tostring(request_id)
            ))
            pcall(callback, nil, "Request timeout")
        end
    end
end


local function send_ws_request(type, action, payload, callback)
    if not cad_websocket or not cad_websocket.is_connected() then
        log('UI', log_levels.ERROR, "send_ws_request failed: Not connected.")
        if callback then callback(nil, "Not connected") end
        return
    end
    request_id_counter = request_id_counter + 1
    local request_id = "ui_req_" .. request_id_counter
    if callback then
        request_callbacks[request_id] = callback
        request_callbacks_meta[request_id] = {
            type = type,
            action = action,
            created_at = os.clock()
        }
    end
    
    local data_to_send = {
        type = type, action = action,
        request_id = request_id, payload = payload
    }
    local token = core.getToken()
    if token then
        data_to_send.token = token
    end
    log('UI', log_levels.DEBUG, string.format("Sending WS request: %s/%s (ID: %s)", type, action, request_id))
    cad_websocket.send(data_to_send)
end

local function merge_unit_data(local_unit, server_unit)
    for k, v in pairs(server_unit) do
        if v ~= nil and v ~= "" then
            if type(v) ~= "number" or v ~= 0 or (local_unit[k] == nil) then
                local_unit[k] = v
            end
        end
    end
    return local_unit
end

local function is_unit_for_current_user(unit)
    if not unit or not core or not core.current_user or not core.current_user.id then
        return false
    end
    local uid = tostring(core.current_user.id)
    if unit.id and core.current_unit and core.current_unit.id and tostring(unit.id) == tostring(core.current_unit.id) then
        return true
    end
    return tostring(unit.user_id or "") == uid
        or tostring(unit.officer1_userid or "") == uid
        or tostring(unit.officer2_userid or "") == uid
end

local function setRadioChannel(channel)
    log('UI', log_levels.INFO, 'Attempting to set radio channel to: ' .. tostring(channel))
    updateLastRadioSlotUsed(channel, "cad_setRadioChannel")
    sampSendChat('/slot ' .. tostring(channel))
end

function samp_events.onSendCommand(command)
    local raw = tostring(command or "")
    local slot_from_cmd = raw:match("^/?slot%s+(%d+)%s*$") or raw:match("^/?slot%s+(%d+)%s+")
    if slot_from_cmd then
        updateLastRadioSlotUsed(slot_from_cmd, "player_command")
    end
end

function samp_events.onServerMessage(color, text)
    local slot_from_radio = tostring(text or ""):match("%[CH:%s*912,%s*S:%s*(%d+)%]")
    if slot_from_radio then
        updateLastRadioSlotUsed(slot_from_radio, "server_radio_message")
    end
end

local function handle_websocket_message(response)
    if not response or not response.type then
        log('UI', log_levels.WARN, "Received invalid WebSocket message object.")
        return
    end

    if response.request_id and request_callbacks[response.request_id] then
        log('UI', log_levels.DEBUG, "Handling callback for request ID: " .. response.request_id)
        local callback = request_callbacks[response.request_id]
        request_callbacks_meta[response.request_id] = nil
        request_callbacks[response.request_id] = nil
        pcall(callback, response.success and response or nil, not response.success and (response.error or "Unknown error"))
        return
    end

    if response.type == 'data_broadcast' then
        log('UI', log_levels.INFO, string.format("Received broadcast for '%s'.", response.dataType))

        if response.dataType == 'show_notification' and response.payload then
            addNotification(
                response.payload.title,
                response.payload.message,
                response.payload.duration or 10,
                response.payload.actions,
                response.payload.sound_trigger
            )
        elseif response.dataType == 'assist_request' and response.payload then
            events.trigger('cad:assist_request', response.payload)
        elseif response.dataType == 'simplex_request' and response.payload then
            events.trigger('cad:simplex_request', response.payload)
        elseif response.dataType == 'incident_update' and response.payload then
            local updated_incident = response.payload
            local found = false
            for i, incident in ipairs(data_storage.incidents) do
                if incident.id == updated_incident.id then
                    data_storage.incidents[i] = updated_incident
                    found = true
                    log('UI', log_levels.INFO, "Updated incident #" .. updated_incident.id .. " in data storage.")
                    break
                end
            end

            if pending_incident_marker_seed.active then
                if os.clock() <= pending_incident_marker_seed.until_ts and updated_incident.status ~= 'Resolved' and updated_incident.id then
                    local touched = cadui_module.touchIncidentWaypoint(updated_incident.id, "seed_" .. tostring(pending_incident_marker_seed.reason or "incident_update"))
                    if touched then
                        if pending_incident_marker_seed.reason == "create_from_call" then
                            addNotification(
                                "NEW EVENT CREATED",
                                string.format("Incident #%s was created from selected call.", tostring(updated_incident.id)),
                                8,
                                nil,
                                "incident_created"
                            )
                        end
                        consume_pending_incident_marker_seed()
                    end
                elseif os.clock() > pending_incident_marker_seed.until_ts then
                    consume_pending_incident_marker_seed()
                end
            end

            if updated_incident.status == 'Resolved' and updated_incident.id then
                send_map_request('close_dispatch_marker', { dedupe_key = "dispatch:incident_call:" .. tostring(updated_incident.id) })
                if checkpoint_tracker.dedupe_key == ("dispatch:incident_call:" .. tostring(updated_incident.id)) then
                    clear_checkpoint_tracker()
                end
            end
            if not found and updated_incident.status ~= 'Resolved' then
                log('UI', log_levels.INFO, "New incident detected, preparing notification for incident #" .. updated_incident.id)
                table.insert(data_storage.incidents, 1, updated_incident)
                log('UI', log_levels.INFO, "Added new incident #" .. updated_incident.id .. " to data storage.")

                local message = string.format("Location: %s\nDetails: %s",
                    tostring(updated_incident.location or "N/A"),
                    tostring(updated_incident.summary or "No summary")
                )
                local actions = {
            {
                label = "Accept",
                bind_id = "popup_accept",
                callback = function()
                    send_ws_request('tactical', 'accept_assist', { incident_id = updated_incident.id })
                    optimistic_accept_assist(updated_incident.id)
                    cadui_module.touchIncidentWaypoint(updated_incident.id, 'notification_accept')
                    addUnitLogEntry("INCIDENT", "Accepted assist for incident #" .. updated_incident.id .. " via notification.")
                end
            },
            {
                label = "Decline",
                bind_id = "popup_decline",
                callback = function()
                    addUnitLogEntry("INCIDENT", "Declined assist for incident #" .. updated_incident.id .. " via notification.")
                end
            }
                }
                addNotification("New Incident #" .. updated_incident.id, message, 15, actions, "incident_created")
                log('UI', log_levels.INFO, "Notification added for incident #" .. updated_incident.id)
            end
        else
            log('UI', log_levels.INFO, "Requesting full data refresh to sync UI for dataType: " .. tostring(response.dataType))
            forceDataRefresh()
        end
        return
    elseif response.type == 'map_update' then
        handle_map_update(response)
        return
    elseif response.type == 'unit_update' then
        local updated_unit = response.payload
        if not updated_unit or not updated_unit.id or not core or not core.current_user then
            log('UI', log_levels.WARN, 'Received unit_update broadcast with invalid payload or user not logged in.')
            return
        end

        if is_unit_for_current_user(updated_unit) then
            log('UI', log_levels.INFO, 'Received unit_update for our own unit ID: ' .. tostring(updated_unit.unitID or updated_unit.id))
            
            core.current_unit = merge_unit_data(core.current_unit or {}, updated_unit)
            events.trigger('cad:unit_updated', core.current_unit)

            local unit_found_in_storage = false
            for i, unit in ipairs(data_storage.units) do
                if unit.id == updated_unit.id then
                    data_storage.units[i] = merge_unit_data(unit, updated_unit)
                    unit_found_in_storage = true
                    break
                end
            end
            if not unit_found_in_storage then
                table.insert(data_storage.units, updated_unit)
            end
        else
            log('UI', log_levels.DEBUG, 'Received unit_update for another unit ID: ' .. tostring(updated_unit.unitID or updated_unit.id))
            local unit_found = false
            for i, unit in ipairs(data_storage.units) do
                if unit.id == updated_unit.id then
                    data_storage.units[i] = merge_unit_data(unit, updated_unit)
                    unit_found = true
                    break
                end
            end
            if not unit_found then
                table.insert(data_storage.units, updated_unit)
            end
        end
    elseif response.type == 'execute_chat_command' then
        if response.command then
            log('UI', log_levels.INFO, 'Executing command from server: ' .. response.command)
            log('UI', log_levels.CRITICAL, 'DEBUG: sampSendChat command execution was skipped.')
        end
    elseif response.type == 'force_radio_channel' then
        if response.payload and response.payload.channel then
            local channel = tonumber(response.payload.channel)
            if channel then
                UI.unit_mini_hud_last_slot = channel
                setRadioChannel(channel)
                if response.payload.origin == 'simplex' then
                    play_interface_trigger("simplex_accepted")
                end
            end
        end
    end
end

function requestPasswordChange()
    local old_pass = safe_str(passwordChangeBuffers.old_password)
    local new_pass = safe_str(passwordChangeBuffers.new_password)
    local confirm_pass = safe_str(passwordChangeBuffers.confirm_password)

    if old_pass == "" or new_pass == "" then
        passwordChangeBuffers.status_message = "All fields are required."
        passwordChangeBuffers.is_error = true
        return
    end

    if new_pass ~= confirm_pass then
        passwordChangeBuffers.status_message = "New passwords do not match."
        passwordChangeBuffers.is_error = true
        return
    end

    if #new_pass < 6 then
        passwordChangeBuffers.status_message = "Password too short (min 6)."
        passwordChangeBuffers.is_error = true
        return
    end


    local payload = {
        old_password = old_pass,
        new_password = new_pass
    }
    
    passwordChangeBuffers.status_message = "Processing..."
    passwordChangeBuffers.is_error = false

    send_ws_request('auth', 'change_password', payload, function(data, err)
        if err then
            passwordChangeBuffers.status_message = "Error: " .. tostring(err)
            passwordChangeBuffers.is_error = true
        else
            passwordChangeBuffers.status_message = "Password changed successfully!"
            passwordChangeBuffers.is_error = false

            ffi.copy(passwordChangeBuffers.old_password, "")
            ffi.copy(passwordChangeBuffers.new_password, "")
            ffi.copy(passwordChangeBuffers.confirm_password, "")
        end
    end)
end

local alpr_is_wanted_plate = false
alpr_flash_end_time = os.clock() + 5
alpr_last_wanted_plate = ""
alpr_wanted_sound = nil
panic_sound = nil
local alpr_muted = false
local alpr_passive_scan_enabled = true
local alpr_passive_hud_open = imgui.new.bool(true)
local alpr_passive_hud_until = 0
local alpr_passive_hud_timeout_sec = 8

local alpr_hud_style_normal = {
    bg_col = 0xFF151515,
    border_col = 0xFF404040,
    plate_text_col = 0xFF00FF00,
    info_text_col = 0xFFAAAAAA,
    model_text_col = 0xFFAAAAAA
}

local alpr_hud_style_alert = {
    bg_col_base = 0xFF550000,
    border_col = 0xFFFF0000,
    plate_text_col = 0xFFFFFFFF,
    info_text_col = 0xFFFFFFFF,
    model_text_col = 0xFFFFFFFF
}

local function get_data_storage()
    if _G and _G.data_storage then return _G.data_storage end
    if data_storage then return data_storage end
    return nil
end

local function wanted_plate_value(entry)
    if type(entry) ~= "table" then return "" end
    return entry.plate
        or entry.license_plate
        or entry.vehicle_plate
        or entry.plate_number
        or entry.number
        or entry.subject_name
        or ""
end

local function table_count(t)
    if type(t) ~= "table" then return 0 end
    local c = 0
    for _, _ in pairs(t) do c = c + 1 end
    return c
end

local function as_array(t)
    if type(t) ~= "table" then return {} end
    local arr = {}
    for _, v in pairs(t) do
        arr[#arr + 1] = v
    end
    return arr
end
last_map_window_pos = nil

local threads_started = false
local is_first_unit_update_after_login = false

local active_notifications = {}
local notification_sound = nil
local calls_snapshot_ready = false
local known_call_ids = {}

local interface_sound_dir_rel = "moonloader/cad_system/resource/sound/"
local interface_sound_files = {
    dispatch_intro_01 = "DISPATCH_INTRO_01.wav",
    dispatch_intro_02 = "DISPATCH_INTRO_02.wav",
    in_01 = "IN_01.wav",
    in_02 = "IN_02.wav",
    insert_01 = "INSERT_01.wav",
    insert_02 = "INSERT_02.wav",
    insert_03 = "INSERT_03.wav",
    insert_04 = "INSERT_04.wav",
    insert_05 = "INSERT_05.wav",
    insert_06 = "INSERT_06.wav",
    insert_07 = "INSERT_07.wav",
    simplex_accept = "OUTRO_02.wav",
    simplex_decline = "OUTRO_03.wav",
    intro_01 = "INTRO_01.wav",
    intro_02 = "INTRO_02.wav",
    officer_intro_01 = "OFFICER_INTRO_01.wav",
    officer_intro_02 = "OFFICER_INTRO_02.wav",
    outro_01 = "OUTRO_01.wav",
    outro_02 = "OUTRO_02.wav",
    outro_03 = "OUTRO_03.wav",
    panic_button = "PANIC_BUTTON.mp4",
    priority_end = "priority_end.wav",
    priority_middle = "priority_middle.wav",
    priority_start = "priority_start.wav",
    siren_switch = "SirenSwitch.wav",
    siren_toggle = "SirenToggle.wav"
}
interface_sounds = {}
interface_sounds_initialized = false
interface_sounds_last_attempt = 0
interface_sounds_bootstrap_next_ts = 0
local interface_sound_triggers = {
    notification = "insert_07",
    alpr_hit = "outro_01",
    panic_button = "panic_button",
    assist_request = "priority_start",
    simplex_request = "insert_07",
    simplex_accepted = "simplex_accept",
    simplex_declined = "simplex_decline",
    call_created = "dispatch_intro_02",
    incident_created = "insert_02"
}

local function get_interface_sound_path(file_name)
    return string.format("%s/%s%s", getGameDirectory(), interface_sound_dir_rel, file_name)
end

function load_single_interface_sound(sound_id)
    if interface_sounds[sound_id] then
        return true
    end

    local file_name = interface_sound_files[sound_id]
    if not file_name then
        return false
    end

    local path = get_interface_sound_path(file_name)
    if not doesFileExist(path) then
        log('UI', log_levels.WARN, "Interface sound not found at: " .. path)
        return false
    end

    local stream = loadAudioStream(path)
    if not stream then
        log('UI', log_levels.ERROR, "Interface sound failed to load: " .. path)
        return false
    end

    interface_sounds[sound_id] = stream
    log('UI', log_levels.INFO, "Interface sound loaded: " .. tostring(sound_id) .. " -> " .. file_name)
    return true
end

function refresh_interface_sound_aliases()
    alpr_wanted_sound = interface_sounds[interface_sound_triggers.alpr_hit]
    notification_sound = interface_sounds[interface_sound_triggers.notification]
    panic_sound = interface_sounds[interface_sound_triggers.panic_button]
end

function update_interface_sound_init_state(loaded_count)
    local has_notification = interface_sounds[interface_sound_triggers.notification] ~= nil
    local has_alpr = interface_sounds[interface_sound_triggers.alpr_hit] ~= nil
    local has_panic = interface_sounds[interface_sound_triggers.panic_button] ~= nil
    interface_sounds_initialized = has_notification and has_alpr and has_panic
    log(
        'UI',
        log_levels.INFO,
        string.format(
            "Interface sounds bootstrap: +%d loaded. core_ready=%s (notification=%s, alpr=%s, panic=%s)",
            loaded_count or 0,
            tostring(interface_sounds_initialized),
            tostring(has_notification),
            tostring(has_alpr),
            tostring(has_panic)
        )
    )
end

function load_interface_sounds(sound_ids)
    local loaded_count = 0

    if type(sound_ids) ~= "table" then
        sound_ids = {}
    end

    for _, sound_id in ipairs(sound_ids) do
        if load_single_interface_sound(sound_id) then
            loaded_count = loaded_count + 1
        end
    end

    refresh_interface_sound_aliases()
    update_interface_sound_init_state(loaded_count)
end

function ensure_interface_sounds_loaded(force)
    if isSampAvailable and not isSampAvailable() then
        return
    end

    local now = os.clock()
    if not force then
        if interface_sounds_initialized then return end
        if now - interface_sounds_last_attempt < 1.5 then return end
    end
    interface_sounds_last_attempt = now
    load_interface_sounds({
        interface_sound_triggers.notification,
        interface_sound_triggers.alpr_hit,
        interface_sound_triggers.panic_button,
        interface_sound_triggers.simplex_accepted,
        interface_sound_triggers.simplex_declined
    })
end

local function play_interface_sound(sound_id)
    ensure_interface_sounds_loaded(false)

    local stream = interface_sounds[sound_id]
    if not stream then
        local file_name = interface_sound_files[sound_id]
        if file_name then
            if load_single_interface_sound(sound_id) then
                stream = interface_sounds[sound_id]
                refresh_interface_sound_aliases()
            else
                local path = get_interface_sound_path(file_name)
                log('UI', log_levels.WARN, "play_interface_sound: failed lazy-load for sound id " .. tostring(sound_id) .. ": " .. path)
                return false
            end
        end
    end

    if not stream then
        log('UI', log_levels.WARN, "play_interface_sound: unknown or unloaded sound id: " .. tostring(sound_id))
        return false
    end

    local ok_stop = pcall(setAudioStreamState, stream, 0)
    local ok_play = pcall(setAudioStreamState, stream, 1)
    if not ok_stop or not ok_play then
        log('UI', log_levels.WARN, "play_interface_sound: playback failed, reloading stream: " .. tostring(sound_id))
        interface_sounds[sound_id] = nil
        ensure_interface_sounds_loaded(true)
        stream = interface_sounds[sound_id]
        if not stream then
            return false
        end
        pcall(setAudioStreamState, stream, 0)
        pcall(setAudioStreamState, stream, 1)
    end
    return true
end

local function play_interface_trigger(trigger_id)
    local sound_id = interface_sound_triggers[trigger_id]
    if not sound_id then
        log('UI', log_levels.WARN, "play_interface_trigger: unknown trigger id: " .. tostring(trigger_id))
        return false
    end
    return play_interface_sound(sound_id)
end

local function resolve_notification_sound_trigger(title, explicit_trigger)
    if explicit_trigger and interface_sound_triggers[explicit_trigger] then
        return explicit_trigger
    end

    local title_lc = string.lower(tostring(title or ""))
    if title_lc:find("assistance request", 1, true) then
        return "assist_request"
    end
    if title_lc:find("simplex request", 1, true) then
        return "simplex_request"
    end
    if title_lc:find("simplex accepted", 1, true) then
        return "simplex_accepted"
    end
    if title_lc:find("simplex declined", 1, true) then
        return "simplex_declined"
    end
    if title_lc:find("new incident #", 1, true) then
        return "incident_created"
    end
    return "notification"
end

local function make_call_ids_snapshot(calls)
    local snapshot = {}
    if type(calls) ~= "table" then
        return snapshot
    end
    for _, call in ipairs(calls) do
        if call and call.id ~= nil then
            snapshot[tostring(call.id)] = true
        end
    end
    return snapshot
end

local function should_render_passive_alpr_hud()
    if not alpr_passive_scan_enabled then return false end
    if UI and UI.alpr_window and UI.alpr_window[0] then return false end
    if not cadui_module.isPlayerInPatrolCar() then return false end
    return (alpr_hud_data and alpr_hud_data.is_alert) or (os.clock() < alpr_passive_hud_until)
end

local UI = {
    mdt = imgui.new.bool(false),
    bolo_editor = imgui.new.bool(false),
    bolo_creator_window = imgui.new.bool(false),
    alpr_window = imgui.new.bool(false),
    alpr_manager = imgui.new.bool(false),
    alpr_log_window = imgui.new.bool(false),
    login_window = imgui.new.bool(false),
    map_window = imgui.new.bool(false),
    unit_mini_hud = imgui.new.bool(true),
    unit_mini_hud_last_slot = 1,
    unit_mini_hud_pos_x = -1,
    unit_mini_hud_pos_y = -1,
    unit_mini_hud_dragging = false,
    show_simplex_unit_selector = imgui.new.bool(false)
}

function updateLastRadioSlotUsed(slot_value, source)
    local slot_num = tonumber(slot_value)
    if not slot_num or slot_num < 1 then return false end

    UI.unit_mini_hud_last_slot = slot_num
    if core and core.current_unit then
        core.current_unit.current_channel_id = slot_num
        broadcastUnitStatus()
    end
    if settings then
        settings.set('ui_settings', 'last_slot_used', slot_num)
        settings.save()
    end

    if log and log_levels then
        log('UI', log_levels.DEBUG, string.format("Updated last radio slot to %d (%s)", slot_num, tostring(source or "unknown")))
    end
    return true
end

function revertToBaseRadioSlot()
    local unit = core and core.current_unit
    local base_slot
    
    if unit and unit.base_radio_slot and tonumber(unit.base_radio_slot) > 0 then
        base_slot = tonumber(unit.base_radio_slot)
    else
        base_slot = tonumber(unitInfoBuffers.base_radio_slot[0])
    end

    local current_slot = tonumber(UI.unit_mini_hud_last_slot)
    
    log('UI', log_levels.DEBUG, string.format("Revert check: base=%s, current=%s", tostring(base_slot), tostring(current_slot)))
    
    if base_slot and base_slot > 0 and base_slot ~= current_slot then
        log('UI', log_levels.INFO, "Reverting to base radio slot: " .. tostring(base_slot))
        updateLastRadioSlotUsed(base_slot, "auto_reversion")
        sampSendChat("/slot " .. tostring(base_slot))
    end
end

function requestFullNameChange()
    local first_name = trim_ws(safe_str(fullNameChangeBuffers.first_name))
    local last_name = trim_ws(safe_str(fullNameChangeBuffers.last_name))

    if first_name == "" or last_name == "" then
        fullNameChangeBuffers.status_message = "Имя и фамилия обязательны."
        fullNameChangeBuffers.is_error = true
        return
    end

    local full_name = (first_name .. " " .. last_name):gsub("%s+", " ")

    fullNameChangeBuffers.status_message = "Processing..."
    fullNameChangeBuffers.is_error = false

    send_ws_request('auth', 'change_full_name', { full_name = full_name }, function(data, err)
        if err then
            fullNameChangeBuffers.status_message = "Error: " .. tostring(err)
            fullNameChangeBuffers.is_error = true
        else
            fullNameChangeBuffers.status_message = "Имя успешно изменено!"
            fullNameChangeBuffers.is_error = false

            if core and core.current_user then
                core.current_user.full_name = data.full_name or full_name
            end
            if unitInfoBuffers and unitInfoBuffers.officer1_name then
                safe_copy(unitInfoBuffers.officer1_name, data.full_name or full_name)
            end

            fill_full_name_buffers(data.full_name or full_name)
        end
    end)
end

local map_zoom = 1.0
local map_max_zoom = 20.0
local map_min_zoom = 1.0
local map_offset_x = 0.0
local map_offset_y = 0.0

local map_tile_textures = {
    standard = {},
}
map_textures_loaded = false

function load_resource_texture(filename)
    local resource_dir = getGameDirectory() .. "/moonloader/cad_system/resource/"
    local path = resource_dir .. filename
    if doesFileExist(path) then
        local file = _G.io.open(path, "rb")
        if file then
            local data = file:read("*a")
            file:close()
            local texture = imgui.CreateTextureFromFileInMemory(data, #data)
            if texture then
                log('UI', log_levels.INFO, "Texture loaded: " .. filename)
                return texture
            else
                log('UI', log_levels.ERROR, "Failed to create texture: " .. filename)
            end
        else
            log('UI', log_levels.ERROR, "Could not read file: " .. path)
        end
    else
        log('UI', log_levels.WARN, "File not found: " .. path)
    end
    return nil
end

function ensure_map_textures_loaded()
    if map_textures_loaded then return end
    for i = 1, 16 do
        map_tile_textures.standard[i] = load_resource_texture(i .. ".png")
    end
    unit_marker_texture = load_resource_texture("radar_centre.png")
    map_textures_loaded = true
end


loginBuffers = {
    username = imgui.new.char[64](),
    password = imgui.new.char[64](),
    error = "",
    loading = false
}

keyBindBuffers = {
    mdt = imgui.new.char[32](),
    alpr = imgui.new.char[32](),
    map = imgui.new.char[32]()
}

local key_being_bound = nil

alpr_scan_log = {}
local selected_alpr_log_index = nil
alpr_log_comment_buffer = imgui.new.char[256]()
local last_alpr_scan_time = 0

registerBuffers = {
    username = imgui.new.char[64](),
    password = imgui.new.char[64](),
    password_confirm = imgui.new.char[64](),
    full_name = imgui.new.char[128](),
    badge_number = imgui.new.char[32](),
    division = imgui.new.int(0),
    error = "",
    success_message = "",
    loading = false
}

--alpr
local patrol_cars = { 596, 597, 598, 599 }
local distance_car_search = 40.0
alpr_current_scan = { model = "Scanning...", plate = "---", driver = "---", found = false }
drivers = {}

local alpr_debug = {
    enabled = true,
    vehicles_checked = 0,
    vehicles_in_range = 0,
    found_vehicle = false,
    found_distance = 0,
    found_vehicle_id = -1,
    last_log_time = 0,
    pool_size = 0,
    handle_count = 0,
    source = "pool"
}

local alpr_camera_config = {
    front = imgui.new.bool(true),
    rear = imgui.new.bool(true),
    sides = imgui.new.bool(true)
}

local function normalize_plate(s)
    if not s then return "" end
    return tostring(s):gsub("[^%w]", ""):upper()
end

local function is_strict_plate_format(plate_clean)
    if type(plate_clean) ~= "string" then return false end
    return plate_clean:match("^%u%u%d%d%d%d%d%d%u%u$") ~= nil
end

local function text_contains_plate(text, plate_clean)
    if not text or text == "" then return false end
    if not is_strict_plate_format(plate_clean) then return false end
    local normalized_text = normalize_plate(text)
    if normalized_text == "" then return false end
    for token in normalized_text:gmatch("%u%u%d%d%d%d%d%d%u%u") do
        if token == plate_clean then return true end
    end
    return false
end

local function text_contains_plate_loose(text, plate_clean)
    return text_contains_plate(text, plate_clean)
end

local function findBoloByPlate(plate_clean)
    if not is_strict_plate_format(plate_clean) then return nil end
    local ds = get_data_storage()
    if not ds or not ds.bolos then return nil end
    for _, bolo in ipairs(ds.bolos) do
        if bolo then
            if type(bolo) == "string" then
                if text_contains_plate_loose(bolo, plate_clean) then return bolo end
            end
            local btype = tostring(bolo.type or ""):lower()
            local is_vehicle = (btype == "" or btype == "vehicle" or btype:find("vehicle", 1, true) ~= nil)
            if is_vehicle then
                local status = bolo.status or "In Progress"
                if status ~= "Clear" and status ~= "In Custody" then
                    if text_contains_plate(bolo.plate, plate_clean)
                        or text_contains_plate(bolo.license_plate, plate_clean)
                        or text_contains_plate(bolo.vehicle_plate, plate_clean)
                        or text_contains_plate(bolo.plate_number, plate_clean)
                        or text_contains_plate(bolo.number, plate_clean)
                        or text_contains_plate(bolo.subject_name, plate_clean)
                        or text_contains_plate(bolo.description, plate_clean)
                        or text_contains_plate(bolo.crime_summary, plate_clean)
                        or text_contains_plate(bolo.notes, plate_clean)
                        or text_contains_plate_loose(bolo.subject_name, plate_clean)
                        or text_contains_plate_loose(bolo.description, plate_clean)
                        or text_contains_plate_loose(bolo.crime_summary, plate_clean)
                        or text_contains_plate_loose(bolo.notes, plate_clean) then
                        return bolo
                    end
                end
            end
        end
    end
    return nil
end

local function isCameraEnabled(cam_pos)
    if cam_pos == "FWD" then return alpr_camera_config.front[0] end
    if cam_pos == "REAR" then return alpr_camera_config.rear[0] end
    return alpr_camera_config.sides[0]
end


samp_events.onPlayerSync = function(playerId, data)
    if data.vehicleId and data.vehicleId > 0 then
        drivers[data.vehicleId] = { playerId, os.time() }
    end
end

samp_events.onVehicleSync = function(playerId, vehicleId, data)
    drivers[vehicleId] = { playerId, os.time() }
end

function getplate(vehicleId)
    local vehicleId = tonumber(vehicleId)
    if not vehicleId then return "" end
    local handle = sampGetBase() + 0x21A0F8
    handle = memory.getint32(handle, false)
    handle = memory.getint32(handle + 0x3CD, false)
    handle = memory.getint32(handle + 0x1C, false)
    handle = (handle + 0x1134) + (vehicleId * 4)
    handle = memory.getint32(handle, false)
    handle = handle + 0x93
    local str = memory.tostring(handle, 20, false)
    return str
end



function getAngleBetweenPoints(x1, y1, x2, y2)
    local angle = -math.deg(math.atan2(x2 - x1, y2 - y1))
    if angle < 0 then angle = angle + 360.0 end
    return angle
end

function cadui_module.isPlayerInPatrolCar()
    if isCharInAnyCar(PLAYER_PED) then
        local vehicleHandle = storeCarCharIsInNoSave(PLAYER_PED)
        local vehicleModel = getCarModel(vehicleHandle)
        for _, patrolCarModel in ipairs(patrol_cars) do
            if vehicleModel == patrolCarModel then
                return true
            end
        end
    end
    return false
end

function isAirUnitAvailable()
    if data_storage and data_storage.units then
        for _, unit in ipairs(data_storage.units) do
            if unit.unitType and unit.unitType == 12 and unit.is_active then
                return true
            end
        end
    end

    if core and core.current_unit then
        local u = core.current_unit
        if u.unitType and u.unitType == 12 and u.is_active then
            return true
        end
    end

    return false
end

function isTowUnitAvailable()
    if data_storage and data_storage.units then
        for _, unit in ipairs(data_storage.units) do
            if unit.unitType and (unit.unitType == 4 or unit.unitType == 10) and unit.is_active then
                return true
            end
        end
    end
    if core and core.current_unit then
        local u = core.current_unit
        if u.unitType and (u.unitType == 4 or u.unitType == 10) and u.is_active then
            return true
        end
    end
    return false
end



function renderLabeledText(label, text, label_color, text_color)
    label_color = label_color or imgui.ImVec4(0.5, 0.7, 0.9, 1.0)
    text_color = text_color or imgui.ImVec4(0.9, 0.9, 0.9, 1.0)
    imgui.TextColored(label_color, label)
    imgui.SameLine()
    imgui.TextColored(text_color, text)
end

function renderInfoBlock(title, data_table)
    imgui.Text(title)
    imgui.Separator()
    for _, item in ipairs(data_table) do
        if item.label and item.value then
            renderLabeledText(item.label, tostring(item.value), item.label_color, item.value_color)
            if item.separator then
                imgui.Separator()
            end
        end
    end
end

function renderTable(id, columns, data, row_renderer, selection_state)
    imgui.Columns(#columns, id, true)
    for i, col in ipairs(columns) do
        imgui.SetColumnWidth(i - 1, col.width)
    end

    for _, col in ipairs(columns) do
        imgui.Text(col.name)
        imgui.NextColumn()
    end
    imgui.Separator()

    for i, item in ipairs(data) do
        local is_selected = selection_state and selection_state.selected_index == i
        if imgui.Selectable("##row" .. tostring(item.id or i), is_selected, 1, imgui.new('ImVec2', 0, 20)) then
            if selection_state then
                selection_state.selected_index = i
            end
        end
        imgui.SameLine()
        
        row_renderer(item, i)
        imgui.NextColumn()
    end
    imgui.Columns(1)
end

function drawOutlinedText(draw_list, pos, text, text_color, outline_color)
    outline_color = outline_color or 0xFF101010
    draw_list:AddText(imgui.new('ImVec2', pos.x - 1, pos.y), outline_color, text)
    draw_list:AddText(imgui.new('ImVec2', pos.x + 1, pos.y), outline_color, text)
    draw_list:AddText(imgui.new('ImVec2', pos.x, pos.y - 1), outline_color, text)
    draw_list:AddText(imgui.new('ImVec2', pos.x, pos.y + 1), outline_color, text)
    draw_list:AddText(pos, text_color, text)
end




local function getCameraDirection(playerHeading, targetX, targetY, pX, pY)
    local angleToTarget = getAngleBetweenPoints(pX, pY, targetX, targetY)
    local relativeAngle = angleToTarget - playerHeading
    
    while relativeAngle <= -180 do relativeAngle = relativeAngle + 360 end
    while relativeAngle > 180 do relativeAngle = relativeAngle - 360 end
    
    if relativeAngle > -45 and relativeAngle <= 45 then return "FWD"
    elseif relativeAngle > 45 and relativeAngle <= 135 then return "LEFT"
    elseif relativeAngle > -135 and relativeAngle <= -45 then return "RGHT"
    else return "REAR"
    end
end


function updateALPRData()
    local now = os.clock()

    if not alpr_hud_data then
        alpr_hud_data = {
            scan_plate = "---",
            camera_pos = "FWD",
            status = "SCANNING",
            is_alert = false,
            alert_type = ""
        }
    end

    if not alpr_is_wanted_plate then
        alpr_hud_data.is_alert = false
        alpr_hud_data.status = "SCANNING"
        alpr_hud_data.scan_plate = "---"
    end

    alpr_current_scan = { model = "Scanning...", plate = "---", driver = "---", found = false }

    if not isCharInAnyCar(PLAYER_PED) then
        alpr_current_scan.model = "Not in a vehicle."
        alpr_current_scan.plate = "---"
        alpr_current_scan.driver = "---"
        alpr_current_scan.found = false
        alpr_hud_data.status = "OFFLINE"
        alpr_hud_data.scan_plate = "---"
        alpr_hud_data.camera_pos = alpr_last_detected_camera
        alpr_passive_hud_until = 0
        return
    end

    local ok, playerCarHandle, playerCarModel, player_car_id = pcall(function()
        local handle = storeCarCharIsInNoSave(PLAYER_PED)
        local model = getCarModel(handle)
        local _, id = sampGetVehicleIdByCarHandle(handle)
        return handle, model, id
    end)
    if not ok then
        alpr_current_scan.model = "Error getting player vehicle."
        alpr_current_scan.plate = "---"
        alpr_current_scan.driver = "---"
        alpr_current_scan.found = false
        alpr_hud_data.status = "OFFLINE"
        alpr_hud_data.scan_plate = "---"
        alpr_hud_data.camera_pos = alpr_last_detected_camera
        alpr_passive_hud_until = 0
        return
    end

    local isPatrolCar = false
    for _, id in ipairs(patrol_cars) do
        if id == playerCarModel then isPatrolCar = true; break end
    end
    if not isPatrolCar then
        alpr_current_scan.model = "Not in a valid patrol car."
        alpr_current_scan.plate = "---"
        alpr_current_scan.driver = "---"
        alpr_current_scan.found = false
        alpr_hud_data.status = "STANDBY"
        alpr_hud_data.scan_plate = "---"
        alpr_hud_data.camera_pos = alpr_last_detected_camera
        alpr_passive_hud_until = 0
        return
    end

    local target_car_data = { distance = distance_car_search, vehicleId = -1 }
    local pX, pY, pZ = getCharCoordinates(PLAYER_PED)
    local fX, fY, fZ = getOffsetFromCharInWorldCoords(PLAYER_PED, 0.0, 7.0, 0.0)

    alpr_debug.vehicles_checked = 0
    alpr_debug.vehicles_in_range = 0
    alpr_debug.found_vehicle = false
    alpr_debug.found_distance = 0
    alpr_debug.found_vehicle_id = -1
    alpr_debug.handle_count = 0
    alpr_debug.source = "pool"

    local reported_pool_size = -1
    if sampGetVehiclePoolSize then
        reported_pool_size = tonumber(sampGetVehiclePoolSize()) or -1
    end

    local max_vehicle_id = math.max(2999, reported_pool_size)
    alpr_debug.pool_size = reported_pool_size

    for vehicleId = 0, max_vehicle_id do
        local result, vehicleHandle = sampGetCarHandleBySampVehicleId(vehicleId)
        if result and vehicleId ~= player_car_id and doesVehicleExist(vehicleHandle) then
            alpr_debug.vehicles_checked = alpr_debug.vehicles_checked + 1
            local success, data = pcall(function()
                local cX, cY, cZ = getCarCoordinates(vehicleHandle)
                local dist = getDistanceBetweenCoords3d(pX, pY, pZ, cX, cY, cZ)
                return { x=cX, y=cY, z=cZ, distance=dist }
            end)

            if success and data.distance < distance_car_search then
                alpr_debug.vehicles_in_range = alpr_debug.vehicles_in_range + 1
            end

            if success and data.distance < target_car_data.distance then
                local heading = getCharHeading(PLAYER_PED)
                local cam_pos = getCameraDirection(heading, data.x, data.y, pX, pY)
                if isCameraEnabled(cam_pos) then
                    target_car_data.distance = data.distance
                    target_car_data.vehicleId = vehicleId
                    target_car_data.vehicleModel = getCarModel(vehicleHandle)
                    target_car_data.x = data.x
                    target_car_data.y = data.y
                end
            end
        end
    end

    if target_car_data.vehicleId > -1 then
        alpr_debug.found_vehicle = true
        alpr_debug.found_distance = target_car_data.distance
        alpr_debug.found_vehicle_id = target_car_data.vehicleId

        local ok_plate, raw_plate = pcall(getplate, target_car_data.vehicleId)
        raw_plate = ok_plate and tostring(raw_plate or "") or ""
        local plate = raw_plate:gsub("%[", ""):gsub("%]", ""):gsub("^%s*(.-)%s*$", "%1")
        local vehicleModelName = (cars[target_car_data.vehicleModel] or "Unknown Model")
        local driverName = "Unknown"

        if drivers[target_car_data.vehicleId] ~= nil and (os.time() - drivers[target_car_data.vehicleId][2] < 2 or sampIsPlayerPaused(drivers[target_car_data.vehicleId][1])) then
            local driverId = drivers[target_car_data.vehicleId][1]
            if sampIsPlayerConnected(driverId) then
                local ok2 = sampGetCharHandleBySampPlayerId(driverId)
                if ok2 then driverName = sampGetPlayerNickname(driverId) end
            end
        end

        alpr_current_scan = { model = vehicleModelName, plate = plate, driver = driverName, found = true }

        alpr_hud_data.scan_plate = plate
        alpr_hud_data.status = "LOCKED"
        local pHeading = getCharHeading(PLAYER_PED)
        alpr_hud_data.camera_pos = getCameraDirection(pHeading, target_car_data.x, target_car_data.y, pX, pY)
        alpr_last_detected_camera = alpr_hud_data.camera_pos

        if not isCameraEnabled(alpr_hud_data.camera_pos) then
            alpr_current_scan = { model = "Camera disabled", plate = "---", driver = "---", found = false }
            alpr_hud_data.status = "CAMERA OFF"
            alpr_hud_data.scan_plate = "---"
            alpr_hud_data.is_alert = false
            return
        end

        local is_wanted = false
        local is_bolo = false
        local bolo_hit = nil
        local cleaned_plate = normalize_plate(plate)
        local has_valid_plate = is_strict_plate_format(cleaned_plate)

        local ds = get_data_storage()
        if ds and ds.wanted_plates then
            wanted_plates_list = as_array(ds.wanted_plates)
        end

        if has_valid_plate then
            for _, wanted in ipairs(wanted_plates_list or {}) do
                local cleaned_wanted_plate = normalize_plate(wanted_plate_value(wanted))
                if is_strict_plate_format(cleaned_wanted_plate) and cleaned_wanted_plate == cleaned_plate then
                    is_wanted = true
                    log('ALPR', log_levels.INFO, 'MATCH FOUND for plate: ' .. plate)
                    break
                end
            end
        end

        bolo_hit = has_valid_plate and findBoloByPlate(cleaned_plate) or nil
        if bolo_hit then
            is_bolo = true
            log('ALPR', log_levels.INFO, 'BOLO HIT for plate: ' .. plate .. ' (BOLO #' .. tostring(bolo_hit.id or "?") .. ')')
        end

        if is_wanted or is_bolo then
            if not alpr_is_wanted_plate then
                log('ALPR', log_levels.INFO, 'Plate is wanted and was not previously wanted. Playing sound.')
                if not alpr_muted then
                    play_interface_trigger("alpr_hit")
                end
                alpr_flash_end_time = now + 8
            end
            alpr_is_wanted_plate = true
            alpr_hud_data.is_alert = true
            alpr_hud_data.status = "ALARM"
            alpr_passive_hud_until = now + alpr_passive_hud_timeout_sec
            if is_wanted and is_bolo then
                alpr_hud_data.alert_type = "WANTED + BOLO"
            elseif is_wanted then
                alpr_hud_data.alert_type = "WANTED HIT"
            else
                alpr_hud_data.alert_type = "BOLO HIT"
            end
        else
            if alpr_is_wanted_plate and now > alpr_flash_end_time then
                alpr_is_wanted_plate = false
                alpr_hud_data.is_alert = false
            elseif not alpr_is_wanted_plate then
                alpr_hud_data.is_alert = false
            end
        end

        local should_write_history = UI and UI.alpr_window and UI.alpr_window[0]
        local already_logged = false
        for _, entry in ipairs(alpr_scan_log) do
            if entry.plate == plate then already_logged = true; break end
        end

        if should_write_history and plate ~= "" and not already_logged then
            table.insert(alpr_scan_log, 1, {
                model = vehicleModelName, plate = plate, driver = driverName,
                timestamp = os.time(), notes = "",
                cam = alpr_hud_data.camera_pos,
                alert = (is_wanted or is_bolo),
                match = (is_wanted and is_bolo) and "WANTED+BOLO" or (is_wanted and "WANTED" or (is_bolo and "BOLO" or "")),
                bolo_id = bolo_hit and bolo_hit.id or nil
            })
            if #alpr_scan_log > 100 then table.remove(alpr_scan_log) end
        end
    else
        alpr_current_scan.model = "No vehicle detected in range."
        alpr_current_scan.plate = "---"
        alpr_current_scan.driver = "---"
        alpr_current_scan.found = false
        alpr_is_wanted_plate = false
        alpr_hud_data.is_alert = false
        alpr_hud_data.status = "SCANNING"
        alpr_hud_data.scan_plate = "---"
        alpr_hud_data.camera_pos = alpr_last_detected_camera
        if os.clock() > alpr_passive_hud_until then
            alpr_passive_hud_until = 0
        end
    end
end

function forceDataRefresh()
    if not core.isAuthenticated() then return end
    if force_refresh_state.in_flight then
        force_refresh_state.pending = true
        log('UI', log_levels.DEBUG, 'forceDataRefresh skipped: request already in flight, queued one retry.')
        return
    end

    force_refresh_state.in_flight = true
    log('UI', log_levels.INFO, 'Requesting all data from server via forceDataRefresh.')
    if core.fetchAbasData then
        core.fetchAbasData()
    end
    --[[if core.fetchUnitLogs and core.current_unit then
        core.fetchUnitLogs(core.current_unit.id, 'profile')
    end]]
    send_ws_request('data', 'fetch_all', {}, function(data, err)
        force_refresh_state.in_flight = false

        if err then 
            if tostring(err) == "Request timeout" then
                log('UI', log_levels.WARN, 'forceDataRefresh timeout: keeping current cached data.')
            else
                log('UI', log_levels.ERROR, 'forceDataRefresh callback failed: ' .. tostring(err))
                events.trigger('cad:data_error', { error = err })
            end
            if force_refresh_state.pending and core.isAuthenticated() then
                force_refresh_state.pending = false
                forceDataRefresh()
            end
            return
        end
        if data and data.payload then
            log('UI', log_levels.INFO, 'forceDataRefresh callback successful. Triggering event.')
            events.trigger('cad:data_refreshed', data.payload)
        else
            log('UI', log_levels.WARN, 'forceDataRefresh callback: No data or payload received.')
            if data and data.error then
                events.trigger('cad:data_error', { error = data.error })
            end
        end

        if force_refresh_state.pending and core.isAuthenticated() then
            force_refresh_state.pending = false
            forceDataRefresh()
        end
    end)
end

function cadui_module.isUnitConfigSyncLocked()
    return unitInfoBuffers and unitInfoBuffers.status and unitInfoBuffers.status[0] == 4
end

function sendPositionUpdate()
    if not core.isAuthenticated() or not core.current_unit then
        return
    end
    if unitInfoBuffers and unitInfoBuffers.status and unitInfoBuffers.status[0] == 4 then
        return
    end

    local playerPed = PLAYER_PED
    if not (playerPed and doesCharExist(playerPed)) then return end

    if isCharInAnyCar(playerPed) then
        local vehicleHandle = storeCarCharIsInNoSave(playerPed)
        local ok, vehicleId = sampGetVehicleIdByCarHandle(vehicleHandle)
        
        if ok then
            local x, y, z = getCarCoordinates(vehicleHandle)
            local heading = getCarHeading(vehicleHandle)
            local payload = {
                pos_x = x,
                pos_y = y,
                pos_z = z,
                heading = heading,
                vehicleId = vehicleId
            }
            send_ws_request('unit', 'unit_update_position', payload)
        end
    end
end

function broadcastUnitStatus(extra_params)
    if not core.isAuthenticated() then
        log('UI', log_levels.WARN, "broadcastUnitStatus called but user is not authenticated. Aborting.")
        return
    end
    extra_params = extra_params or {}
    updateCurrentLocation()
    local payload = {
        unitID = safe_str(unitInfoBuffers.unitID),
        unitType = unitInfoBuffers.unitType[0],
        officer1_name = safe_str(unitInfoBuffers.officer1_name),
        officer1_phone = safe_str(unitInfoBuffers.officer1_phone),
        officer2_name = safe_str(unitInfoBuffers.officer2_name),
        officer2_phone = safe_str(unitInfoBuffers.officer2_phone),
        status = unitInfoBuffers.status[0],
        vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
        division = unitInfoBuffers.division[0],
        base_radio_slot = unitInfoBuffers.base_radio_slot[0],
        notes = safe_str(unitInfoBuffers.notes),
        location = currentLocation,
        current_channel_id = tonumber(UI.unit_mini_hud_last_slot),
        is_active = (unitInfoBuffers.status[0] ~= 4),
        vehicleId = assigned_vehicle_id, 
        user_id = core.current_user and core.current_user.id or nil
    }
    for k, v in pairs(extra_params) do payload[k] = v end

    local action = 'form_or_update_crew'

    log('UI', log_levels.INFO, "--- BROADCASTING UNIT STATUS ---")
    log('UI', log_levels.INFO, "Action: " .. action)
    log('UI', log_levels.INFO, "Payload: " .. json.encode(payload))

    send_ws_request('unit', action, payload, function(data, err) 
        if err then
            addUnitLogEntry("ERROR", "Failed to broadcast unit status: " .. err)
        elseif data and data.success and data.payload then
            log('UI', log_levels.INFO, "Unit status broadcast successful, payload received.")
            events.trigger('cad:unit_updated', data.payload)
        end
    end)
end

function startBackgroundThreads()
    if threads_started then return end
    threads_started = true
    log('UI', log_levels.INFO, 'Starting background threads (heartbeat and position updates).')

    lua_thread.create(function()
        wait(5000)
        while threads_started do
            if core.isAuthenticated() then
                if is_first_unit_update_after_login then
                    log('UI', log_levels.INFO, 'Skipping first automatic unit broadcast after login.')
                    is_first_unit_update_after_login = false
                else
                    broadcastUnitStatus()
                end
            end
            wait(15000)
        end
    end)

    lua_thread.create(function()
        while threads_started do
            wait(4000)
            if core.isAuthenticated() then
                sendPositionUpdate()
            end
        end
    end)

    lua_thread.create(function()
        local attempts = 0
        while threads_started and not interface_sounds_initialized and attempts < 8 do
            wait(1500)
            ensure_interface_sounds_loaded(true)
            attempts = attempts + 1
        end
        if interface_sounds_initialized then
            log('UI', log_levels.INFO, "Deferred sound bootstrap completed.")
        else
            log('UI', log_levels.WARN, "Deferred sound bootstrap finished with missing streams.")
        end
    end)

end


local radioConfig = {}

local data_storage = {
    calls = {},
    bolos = {},
    units = {},
    incidents = {},
    wanted_plates = {},
    global_event_log = {},
    latest_unit_data = nil
}
_G.data_storage = data_storage

local last_known_call_id = 0
local last_unit_update_timestamp = 0 

local boloTypes = { "Person", "Vehicle", "Other" }
local boloStatuses = { "In Progress", "In Custody", "Clear" }

local boloStatusColors = {
    ["In Progress"] = imgui.ImVec4(1.0, 0.6, 0.0, 1.0), -- Оранжевый
    ["In Custody"]  = imgui.ImVec4(0.2, 0.6, 0.9, 1.0), -- Синий
    ["Clear"]       = imgui.ImVec4(0.2, 0.8, 0.2, 1.0), -- Зеленый
    ["Default"]     = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
}

local newBoloData = {
    id = imgui.new.char[128](),
    type = imgui.new.int(0), 
    subject_name = imgui.new.char[128](),
    last_location = imgui.new.char[128](),
    description = imgui.new.char[512](),
    crime_summary = imgui.new.char[512]()
}

local bolo_note_buffer = imgui.new.char[256]()
local selected_bolo_index = nil 
local new_wanted_plate_buffer = imgui.new.char[32]()
local wanted_plates_list = {}

local boloTypes_c = nil
local boloStatuses_c = nil

local callStatusTypes = { "Pending", "En-route", "Clear" }
local callStatusColors = { Pending = imgui.ImVec4(1.0, 0.8, 0.0, 1.0), ["En-route"] = imgui.ImVec4(0.0, 0.6, 1.0, 1.0), Clear = imgui.ImVec4(0.2, 0.8, 0.2, 1.0) }
local selected_call_index = nil
local selected_unit_index = nil
local incidentStatusTypes = { "Active", "Under Investigation", "Code 4", "Resolved" }
local incidentStatusColors = { Active = imgui.ImVec4(1.0, 0.2, 0.2, 1.0), ["Under Investigation"] = imgui.ImVec4(1.0, 0.6, 0.0, 1.0), ["Code 4"] = imgui.ImVec4(0.2, 0.5, 1.0, 1.0), Resolved = imgui.ImVec4(0.2, 0.8, 0.2, 1.0) }
local selected_incident_index = nil

local function get_current_unit_callsign()
    if core and core.current_unit then
        return core.current_unit.unitID or core.current_unit.unitId
    end
    return nil
end

local function normalize_assigned_units(assigned_units)
    if type(assigned_units) == "string" then
        local ok, decoded = pcall(json.decode, assigned_units)
        if ok and type(decoded) == "table" then
            return decoded
        end
        return {}
    end
    if type(assigned_units) == "table" then
        return assigned_units
    end
    return {}
end

cadui_module.lspd_call_assignments_store = cadui_module.lspd_call_assignments_store or {}

function cadui_module.saveLspdCallAssignmentsStore()
    if not settings then return end
    settings.set('ui_settings', 'lspd_call_assignments', cadui_module.lspd_call_assignments_store)
    settings.save()
end

function cadui_module.isAssigneeInList(list, assignee_label)
    if type(list) ~= "table" then return false end
    local target = tostring(assignee_label)
    for _, existing in ipairs(list) do
        if tostring(existing) == target then
            return true
        end
    end
    return false
end

function cadui_module.addLspdAssignedUnitToCall(call_id, officer_label)
    if not call_id or not officer_label then return false end

    local call_id_str = tostring(call_id)
    local officer_tag = tostring(officer_label)

    local stored = cadui_module.lspd_call_assignments_store[call_id_str]
    if type(stored) ~= "table" then
        stored = {}
    end
    local added_to_store = false
    if not cadui_module.isAssigneeInList(stored, officer_tag) then
        table.insert(stored, officer_tag)
        cadui_module.lspd_call_assignments_store[call_id_str] = stored
        added_to_store = true
    end
    if added_to_store then
        cadui_module.saveLspdCallAssignmentsStore()
    end

    if not data_storage or type(data_storage.calls) ~= "table" then
        return false
    end

    for _, call in ipairs(data_storage.calls) do
        local id_match = tostring(call.id or "") == call_id_str
            or tostring(call.server_call_id or "") == call_id_str
        if id_match then
            local units = call.assigned_units
            if type(units) == "string" then
                local ok, decoded = pcall(json.decode, units)
                units = (ok and type(decoded) == "table") and decoded or {}
            elseif type(units) ~= "table" then
                units = {}
            end

            if not cadui_module.isAssigneeInList(units, officer_tag) then
                table.insert(units, officer_tag)
                call.assigned_units = units
                return true
            else
                call.assigned_units = units
            end
        end
    end

    return false
end

function cadui_module.applyPendingLspdAssignments()
    if not data_storage or type(data_storage.calls) ~= "table" then return end
    if type(cadui_module.lspd_call_assignments_store) ~= "table" then return end

    for _, call in ipairs(data_storage.calls) do
        local call_ids = {
            tostring(call.id or ""),
            tostring(call.server_call_id or "")
        }

        local units = call.assigned_units
        if type(units) == "string" then
            local ok, decoded = pcall(json.decode, units)
            units = (ok and type(decoded) == "table") and decoded or {}
        elseif type(units) ~= "table" then
            units = {}
        end

        for _, cid in ipairs(call_ids) do
            local stored_labels = cadui_module.lspd_call_assignments_store[cid]
            if type(stored_labels) == "table" then
                for _, label in ipairs(stored_labels) do
                    if not cadui_module.isAssigneeInList(units, label) then
                        table.insert(units, label)
                    end
                end
            end
        end

        call.assigned_units = units
    end
end

local function optimistic_update_incident(incident_id, updater)
    if not data_storage or not data_storage.incidents then return end
    for i, inc in ipairs(data_storage.incidents) do
        if inc.id == incident_id then
            updater(inc)
            data_storage.incidents[i] = inc
            return
        end
    end
end

optimistic_accept_assist = function(incident_id)
    local unit_callsign = get_current_unit_callsign()
    if not unit_callsign then return end

    optimistic_update_incident(incident_id, function(inc)
        inc.assigned_units = normalize_assigned_units(inc.assigned_units)
        local exists = false
        for _, u in ipairs(inc.assigned_units) do
            if u == unit_callsign then
                exists = true
                break
            end
        end
        if not exists then
            table.insert(inc.assigned_units, unit_callsign)
        end

        inc.event_log = inc.event_log or {}
        table.insert(inc.event_log, {
            time = os.date("%H:%M"),
            event = "Unit " .. tostring(unit_callsign) .. " joined the incident."
        })
    end)
end

local function optimistic_set_incident_status(incident_id, new_status)
    optimistic_update_incident(incident_id, function(inc)
        inc.status = new_status
        local unit_callsign = get_current_unit_callsign() or "System"
        inc.event_log = inc.event_log or {}
        table.insert(inc.event_log, {
            time = os.date("%H:%M"),
            event = "Status changed to " .. tostring(new_status) .. " by unit " .. tostring(unit_callsign) .. "."
        })
    end)
end
local call_note_buffer = imgui.new.char[256]()
local isEditingUnitInfo = false

local unit_edit_state = {
    dirty = {}
}

local function mark_unit_field_dirty(field)
    unit_edit_state.dirty[field] = true
end

local function clear_unit_dirty_fields()
    unit_edit_state.dirty = {}
end

local function is_unit_field_dirty(field)
    return unit_edit_state.dirty[field] == true
end

unitInfo = { 
    unitID = "", unitType = 0, 
    officer1_name = "", officer1_id = "", 
    officer2_name = "", officer2_id = "", 
    status = 0, vehiclePlate = "", 
    division = 0, shift = 0, 
    base_radio_slot = 1,
    notes = "" 
}

unitInfoBuffers = {
    unitID = imgui.new.char[32](unitInfo.unitID), 
    unitType = imgui.new.int(unitInfo.unitType),
    
    officer1_name = imgui.new.char[64](unitInfo.officer1_name), 
    officer1_id = imgui.new.char[32](unitInfo.officer1_id),
    officer1_phone = imgui.new.char[32](unitInfo.officer1_phone or ""), 
    
    officer2_name = imgui.new.char[64](unitInfo.officer2_name), 
    officer2_id = imgui.new.char[32](unitInfo.officer2_id),
    officer2_phone = imgui.new.char[32](unitInfo.officer2_phone or ""), 
    
    status = imgui.new.int(unitInfo.status), 
    vehiclePlate = imgui.new.char[32](unitInfo.vehiclePlate),
    division = imgui.new.int(unitInfo.division), 
    shift = imgui.new.int(unitInfo.shift),
    base_radio_slot = imgui.new.int(unitInfo.base_radio_slot or 1),
    notes = imgui.new.char[256](unitInfo.notes) 
}


vehicleEquipment = {
    ar15 = imgui.new.bool(false),
    ll40mm = imgui.new.bool(false),
    beanbag = imgui.new.bool(false),
    riot_shield = imgui.new.bool(false),
    spikes = imgui.new.bool(false),
    narcan = imgui.new.bool(false),
    pit_auth = imgui.new.bool(false),
    aed = imgui.new.bool(false)
}

alpr_hud_data = {
    scan_plate = "---",
    camera_pos = "FWD", -- FWD, LEFT, RGHT, REAR
    status = "SCANNING", 
    is_alert = false,
    alert_type = ""
}
alpr_last_detected_camera = "FWD"


local comboBoxData = {
    unitType = { "E/H/K: Basic Patrol Unit", "S: Supervisor Unit", "W: SEB Extendet Station Unit", "D4A: MCB Metropolitan", "D11E: East OSSD", "D11EG: East GET", "D5A: Homicide Metropolitan", "D6A: Narcotics Metropolitan", "temp", "temp", "temp", "temp", "AIR: Aero Bureau Unit" },
    status = { "Available", "En Route", "On Scene / C6", "Busy", "Out of Service" },
    shift = { "Watch I (22:00-06:00)", "Watch II (06:00-14:00)", "Watch III (14:00-22:00)" },
    division = { "02 EAST LS AREA", "28 GANTON AREA", "24 SPECIAL ENFORCEMENT BUREAU" }
}

local function get_division_prefix(div_name)
    if not div_name then return "00" end
    local num = div_name:match("(%d+)") 
    return num or "00"
end

local divisionOptions_c, unitTypeOptions_c, shiftOptions_c = nil, nil, nil
local boloTypes_c, boloStatuses_c = nil, nil
local unitActivityLog = { { time = os.date("%H:%M:%S"), event = "SYSTEM", details = "CAD/MDT Initialized" } }
local selectedPatrolUnit = nil
local currentLocation = "Updating..."
local lastLocationUpdate = 0
local LOCATION_UPDATE_INTERVAL = 2000 

function getCityNameFromCoords(x, y, z)
    if x >= -3000 and x <= -1200 and y >= -2000 and y <= 1500 then
        return "Los Santos"
    elseif x >= -3000 and x <= -1200 and y >= -1000 and y <= 500 then
        return "San Fierro"
    elseif x >= 500 and x <= 3000 and y >= 500 and y <= 3000 then
        return "Las Venturas"
    else
        return "San Andreas"
    end
end

function getShortLocationCode(x, y, z)
    local zone = getNameOfZone(x, y, z)
    if not zone or zone == "" then
        return "N/A"
    end
    local zone_codes = {
        ["Rodeo"] = "ROD", ["Verona Beach"] = "VER", ["Santa Monica Beach"] = "SMB", ["Venice Beach"] = "VEN", ["Downtown Los Santos"] = "DTLS",
        ["East Los Santos"] = "ELS", ["Glen Park"] = "GP", ["Idlewood"] = "IDL", ["Jefferson"] = "JEF", ["Las Colinas"] = "LC", ["Little Mexico"] = "LM",
        ["Los Flores"] = "LF", ["Marina"] = "MAR", ["Market"] = "MKT", ["Mulholland"] = "MUL", ["Pershing Square"] = "PS", ["Richman"] = "RCH",
        ["Santa Maria Beach"] = "SMB", ["Temple"] = "TMP", ["Unity Station"] = "US", ["Verdant Bluffs"] = "VB", ["Vinewood"] = "VW", ["Willowfield"] = "WF"
    }
    return zone_codes[zone] or zone:sub(1, 3):upper()
end

function updateCurrentLocation()
    if os.clock() * 1000 - lastLocationUpdate < LOCATION_UPDATE_INTERVAL then
        return
    end
    
    if isCharInAnyCar(PLAYER_PED) then
        local vehicle = storeCarCharIsInNoSave(PLAYER_PED)
        local x, y, z = getCarCoordinates(vehicle)
        local zone = getNameOfZone(x, y, z)
        local area = getCityNameFromCoords(x, y, z)
        currentLocation = string.format("%s, %s", zone, area)
    else
        local x, y, z = getCharCoordinates(PLAYER_PED)
        local zone = getNameOfZone(x, y, z)
        local area = getCityNameFromCoords(x, y, z)
        currentLocation = string.format("%s, %s (On foot)", zone, area)
    end
    
    lastLocationUpdate = os.clock() * 1000
end

function generateNewBoloId()
    local year = os.date("%y")
    local highest_id = 0
    for _, bolo in ipairs(data_storage.bolos) do
        if bolo.id and type(bolo.id) == 'string' then
            local id_year, id_num = bolo.id:match("^(%d+)-(%d+)$")
            if id_year == year and id_num then
                if tonumber(id_num) > highest_id then
                    highest_id = tonumber(id_num)
                end
            end
        end
    end
    return string.format("%s-%04d", year, highest_id + 1)
end

function drawBoloCreatorWindow()
    if not UI.bolo_creator_window[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 500, 600), imgui.Cond.FirstUseEver)
    

    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 5.0) 
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 0.0) 
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.20, 0.20, 0.24, 1.0)) 
    

    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.1, 0.1, 0.12, 0.98))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, imgui.ImVec4(0.1, 0.1, 0.12, 1.0))
    
    if imgui.Begin("New BOLO Report", UI.bolo_creator_window, imgui.WindowFlags.NoCollapse) then
        imgui.PushFont(fonts[22])
        imgui.TextColored(imgui.ImVec4(1,1,1,1), "CREATE NEW REPORT")
        imgui.PopFont()
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        imgui.BeginGroup()
            imgui.TextDisabled("Report Type")
            imgui.SetNextItemWidth(150)
            imgui.Combo("##btype", newBoloData.type, boloTypes_c, #boloTypes)
        imgui.EndGroup()
        
        imgui.SameLine()
        
        imgui.BeginGroup()
            imgui.TextDisabled("Subject Name / Plate")
            imgui.SetNextItemWidth(250)
            imgui.InputText("##bname", newBoloData.subject_name, ffi.sizeof(newBoloData.subject_name))
        imgui.EndGroup()

        imgui.Dummy(imgui.new('ImVec2', 0, 5))
        
        imgui.BeginGroup()
            imgui.TextDisabled("Last Known Location")
            imgui.SetNextItemWidth(-1)
            imgui.InputText("##bloc", newBoloData.last_location, ffi.sizeof(newBoloData.last_location))
        imgui.EndGroup()

        imgui.Dummy(imgui.new('ImVec2', 0, 15))
        imgui.TextDisabled("VISUAL DESCRIPTION")
        imgui.InputTextMultiline("##bdesc", newBoloData.description, ffi.sizeof(newBoloData.description), imgui.new('ImVec2', -1, 80))

        imgui.Dummy(imgui.new('ImVec2', 0, 10))
        imgui.TextDisabled("CRIME / REASON FOR ALERT")
        imgui.InputTextMultiline("##breason", newBoloData.crime_summary, ffi.sizeof(newBoloData.crime_summary), imgui.new('ImVec2', -1, 80))

        imgui.Dummy(imgui.new('ImVec2', 0, 20))
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 0.2, 1.0))
        if imgui.Button("SUBMIT REPORT", imgui.new('ImVec2', 150, 40)) then
            local new_bolo = {
                bolo_id = "",
                type = boloTypes[newBoloData.type[0] + 1],
                subject_name = safe_str(newBoloData.subject_name),
                last_location = safe_str(newBoloData.last_location),
                description = safe_str(newBoloData.description),
                crime_summary = safe_str(newBoloData.crime_summary),
                status = "In Progress",
                created_by = safe_str(unitInfoBuffers.officer1_name)
            }
            events.trigger('cad:addBolo', new_bolo)
            UI.bolo_creator_window[0] = false
        end
        imgui.PopStyleColor()
        
        imgui.SameLine()
        
        if imgui.Button("CANCEL", imgui.new('ImVec2', 100, 40)) then
            UI.bolo_creator_window[0] = false
        end

    end
    imgui.End()
    
    imgui.PopStyleColor(3) 
    imgui.PopStyleVar(2) 
end

local alpr_interaction_mode = false

local function drawStyledInput(label, buffer, size, width, flags, icon)
    imgui.BeginGroup()
        if icon and fonts[18] then 
            imgui.PushFont(fonts[18])
            imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.7, 1), icon)
            imgui.PopFont()
            imgui.SameLine() 
        end
        imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), label)
        
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 4.0)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.new('ImVec2', 10, 10))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.15, 0.15, 0.18, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.2, 0.2, 0.25, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0.25, 0.25, 0.3, 1.0))
        
        imgui.SetNextItemWidth(width)

        imgui.InputText("##" .. label, buffer, size, flags)
        
        imgui.PopStyleColor(3)
        imgui.PopStyleVar(2)
    imgui.EndGroup()
    imgui.Dummy(imgui.new('ImVec2', 0, 5))
end

local function drawStyledCheckbox(label, bool_ptr)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local height = 20
    local width = 40
    local radius = height * 0.50
    

    imgui.InvisibleButton(label, imgui.new('ImVec2', width + 10 + imgui.CalcTextSize(label).x, height))
    local is_clicked = imgui.IsItemClicked()
    
    if is_clicked then
        bool_ptr[0] = not bool_ptr[0]
    end
    
    local col_bg
    if imgui.IsItemHovered() then
        col_bg = bool_ptr[0] and 0xFF00C853 or 0xFF555555 
    else
        col_bg = bool_ptr[0] and 0xFF00E676 or 0xFF444444 
    end
    

    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), col_bg, radius)
    local circle_x = bool_ptr[0] and (p.x + width - radius) or (p.x + radius)
    draw_list:AddCircleFilled(imgui.new('ImVec2', circle_x, p.y + radius), radius - 1.5, 0xFFFFFFFF)
    
    imgui.SameLine()
    imgui.SetCursorScreenPos(imgui.new('ImVec2', p.x + width + 10, p.y))
    imgui.TextColored(imgui.ImVec4(0.9, 0.9, 0.9, 1), label)
    
    imgui.Dummy(imgui.new('ImVec2', 0, 5)) 
    
    return is_clicked
end

local function drawStyledCombo(label, current_item, items, items_count, width, icon)
    imgui.BeginGroup()
        if icon and fonts[18] then 
            imgui.PushFont(fonts[18])
            imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.7, 1), icon)
            imgui.PopFont()
            imgui.SameLine() 
        end
        imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), label)

        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 4.0)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.new('ImVec2', 10, 10))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.15, 0.15, 0.18, 1.0))
        
        imgui.SetNextItemWidth(width)
        imgui.Combo("##"..label, current_item, items, items_count)
        
        imgui.PopStyleColor(1)
        imgui.PopStyleVar(2)
    imgui.EndGroup()
    imgui.Dummy(imgui.new('ImVec2', 0, 5))
end

function renderALPRWindow()
    if not UI.alpr_window[0] then
        if alpr_interaction_mode then alpr_interaction_mode = false end
        return
    end
    if wasKeyPressed(vkeys.VK_F2) then
        alpr_interaction_mode = not alpr_interaction_mode
    end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 450, 280), imgui.Cond.FirstUseEver)
    do
        local sw, _ = getScreenResolution()
        imgui.SetNextWindowPos(imgui.new('ImVec2', sw - 20, 180), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 1.0, 0.0))
    end

    local style_pushed = false
    if alpr_is_wanted_plate then
        local time = os.clock()
        local title_color
        local border_color = imgui.ImVec4(0.8, 0.1, 0.1, 1.0)

        if time < alpr_flash_end_time then
            local pulse = (math.sin(time * 15) + 1) / 2
            title_color = imgui.ImVec4(0.7 + pulse * 0.3, 0.1, 0.1, 1.0)
        else
            title_color = imgui.ImVec4(0.5, 0.1, 0.1, 1.0)
        end
        
        imgui.PushStyleColor(imgui.Col.TitleBgActive, title_color)
        imgui.PushStyleColor(imgui.Col.TitleBg, title_color)
        imgui.PushStyleColor(imgui.Col.Border, border_color)
        style_pushed = true
    end

    local success, err = pcall(function()
        if imgui.Begin("ALPR Scan", UI.alpr_window, imgui.WindowFlags.NoResize) then
            if os.clock() * 1000 - last_alpr_scan_time > 1000 then
                updateALPRData()
                last_alpr_scan_time = os.clock() * 1000
            end

            imgui.PushFont(fonts[22])
            imgui.Text("Automatic License Plate Reader")
            imgui.PopFont()
            imgui.Separator()
            imgui.BeginChild("ALPRInfo", imgui.new('ImVec2', -1, -110))

            if not alpr_current_scan.found and alpr_current_scan.model == "Scanning..." then
                imgui.Text("Scanning for vehicles...")
            elseif not alpr_current_scan.found then
                imgui.Text(tostring(alpr_current_scan.model))
            else
                renderLabeledText("VEHICLE MODEL:", tostring(alpr_current_scan.model), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
                renderLabeledText("LICENSE PLATE:", tostring(alpr_current_scan.plate), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
                renderLabeledText("DRIVER:", tostring(alpr_current_scan.driver), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            end

            imgui.EndChild()
            imgui.Separator()

            imgui.TextDisabled("Press F2 to toggle cursor and controls")

            local button_size = imgui.new('ImVec2', imgui.GetContentRegionAvail().x / 3 - 4, 40)
            if not alpr_current_scan.found then
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.5)
                imgui.Button("T/S", button_size)
                imgui.PopStyleVar()
            else
                if imgui.Button("T/S", button_size) then
                    addUnitLogEntry("ALPR", "Traffic stop announced for: " .. tostring(alpr_current_scan.plate))
                end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Announce traffic stop on radio")
            end
            imgui.SameLine()
            if not alpr_current_scan.found then
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.5)
                imgui.Button("GET INFO", button_size)
                imgui.PopStyleVar()
            else
                if imgui.Button("GET INFO", button_size) then
                    setClipboardText(tostring(alpr_current_scan.plate))
                    print(string.format("[CAD/MDT] License plate '%s' copied to clipboard.", tostring(alpr_current_scan.plate)))
                end
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Copy license plate to clipboard")
            end
            imgui.SameLine()
            if imgui.Button("CLOSE", button_size) then
                UI.alpr_window[0] = false
            end
        end
        imgui.End()
    end)

    if style_pushed then
        imgui.PopStyleColor(3)
    end

    if not success then
        log('UI', log_levels.ERROR, "An error occurred in renderALPRWindow: " .. tostring(err))
    end
end


function renderALPRHud()
    local is_manual_mode = UI.alpr_window[0]
    if not is_manual_mode and not should_render_passive_alpr_hud() then
        return
    end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 280, 145), imgui.Cond.FirstUseEver)
    do
        local sw, _ = getScreenResolution()
        imgui.SetNextWindowPos(imgui.new('ImVec2', sw - 20, 20), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 1.0, 0.0))
    end

    if is_manual_mode and wasKeyPressed(vkeys.VK_F2) then
        alpr_interaction_mode = not alpr_interaction_mode
    end
    

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 8, 8))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 6.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 4.0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.1, 0.1, 0.1, 0.95))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
    
    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
    if not is_manual_mode then
        flags = flags + imgui.WindowFlags.NoInputs
    end

    local hud_open_ref = UI.alpr_window
    if not is_manual_mode then
        alpr_passive_hud_open[0] = true
        hud_open_ref = alpr_passive_hud_open
    end

    if imgui.Begin("ALPR_HUD_Overlay", hud_open_ref, flags) then
        if is_manual_mode and os.clock() * 1000 - last_alpr_scan_time > 1000 then
            updateALPRData()
            last_alpr_scan_time = os.clock() * 1000
        end
        local draw_list = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        

        local is_alarm_visual = alpr_hud_data.is_alert or (alpr_is_wanted_plate and os.clock() <= alpr_flash_end_time)

        local bg_col = alpr_hud_style_normal.bg_col
        local text_col = alpr_hud_style_normal.plate_text_col
        local status_text = alpr_hud_data.status or "SCANNING"
        local border_col = alpr_hud_style_normal.border_col
        local info_text_col = alpr_hud_style_normal.info_text_col
        local model_text_col = alpr_hud_style_normal.model_text_col
        local alert_pulse = 0.0
        
        if is_alarm_visual then
            status_text = alpr_hud_data.alert_type ~= "" and alpr_hud_data.alert_type or "ALARM"
            alert_pulse = (math.sin(os.clock() * 12.0) + 1.0) * 0.5

            local bg_v = imgui.ImVec4(0.35 + 0.30 * alert_pulse, 0.02, 0.02, 0.98)
            local border_v = imgui.ImVec4(0.85 + 0.15 * alert_pulse, 0.02, 0.02, 1.0)
            local plate_v = imgui.ImVec4(1.0, 0.10 + 0.90 * alert_pulse, 0.10 + 0.90 * alert_pulse, 1.0)
            local info_v = imgui.ImVec4(1.0, 0.72, 0.72, 1.0)
            local model_v = imgui.ImVec4(1.0, 0.84, 0.84, 1.0)

            bg_col = imgui.GetColorU32Vec4(bg_v)
            border_col = imgui.GetColorU32Vec4(border_v)
            text_col = imgui.GetColorU32Vec4(plate_v)
            info_text_col = imgui.GetColorU32Vec4(info_v)
            model_text_col = imgui.GetColorU32Vec4(model_v)
        end


        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + w, p.y + 85), bg_col, 4.0)
        draw_list:AddRect(p, imgui.new('ImVec2', p.x + w, p.y + 85), border_col, 4.0, 0, 1.0 + alert_pulse * 2.0)

        if is_alarm_visual then
            local stripe_alpha = 60 + math.floor(alert_pulse * 120)
            local stripe_color = bit.bor(0x000000FF, bit.lshift(stripe_alpha, 24))
            draw_list:AddRectFilled(
                imgui.new('ImVec2', p.x + 4, p.y + 4),
                imgui.new('ImVec2', p.x + 10, p.y + 81),
                stripe_color,
                2.0
            )
            draw_list:AddRectFilled(
                imgui.new('ImVec2', p.x + w - 10, p.y + 4),
                imgui.new('ImVec2', p.x + w - 4, p.y + 81),
                stripe_color,
                2.0
            )

            local blink_alpha = 50 + math.floor(alert_pulse * 140)
            local blink_color = bit.bor(0x000000FF, bit.lshift(blink_alpha, 24))
            draw_list:AddRectFilled(
                imgui.new('ImVec2', p.x, p.y),
                imgui.new('ImVec2', p.x + w, p.y + 85),
                blink_color,
                4.0
            )
        end


        local plate_text = "---"
        if alpr_current_scan and alpr_current_scan.found and alpr_current_scan.plate and alpr_current_scan.plate ~= "" then
            plate_text = alpr_current_scan.plate
        else
            plate_text = "---"
        end
        if plate_text == "" then plate_text = "---" end
        
        imgui.PushFont(fonts[22])
        local txt_size = imgui.CalcTextSize(plate_text)
        local txt_pos_x = p.x + (w - txt_size.x) / 2
        
        draw_list:AddText(imgui.new('ImVec2', txt_pos_x, p.y + 10), text_col, plate_text)
        imgui.PopFont()


        local model_text = alpr_current_scan and alpr_current_scan.model or "Scanning..."
        if model_text == "" then model_text = "Unknown" end
        local model_str = "MODEL: " .. tostring(model_text)
        local model_size = imgui.CalcTextSize(model_str)
        draw_list:AddText(imgui.new('ImVec2', p.x + (w - model_size.x)/2, p.y + 45), model_text_col, model_str)

        local hud_cam = alpr_hud_data.camera_pos or alpr_last_detected_camera or "FWD"
        local info_str = string.format("CAM: %s  |  %s", hud_cam, status_text)
        local info_size = imgui.CalcTextSize(info_str)
        draw_list:AddText(imgui.new('ImVec2', p.x + (w - info_size.x)/2, p.y + 62), info_text_col, info_str)

        if is_alarm_visual then
            local alert_str = "HIT"
            imgui.PushFont(fonts[22])
            local alert_size = imgui.CalcTextSize(alert_str)
            imgui.PopFont()
            local alert_x = p.x + w - alert_size.x - 8
            local alert_y = p.y + 8
            local hit_col = imgui.GetColorU32Vec4(imgui.ImVec4(1.0, 0.4 + 0.6 * alert_pulse, 0.4 + 0.6 * alert_pulse, 1.0))
            draw_list:AddText(imgui.new('ImVec2', alert_x, alert_y), hit_col, alert_str)

            local alarm_banner = "ALPR HIT"
            local banner_size = imgui.CalcTextSize(alarm_banner)
            local banner_col = imgui.GetColorU32Vec4(imgui.ImVec4(1.0, 0.2 + 0.8 * alert_pulse, 0.2 + 0.8 * alert_pulse, 1.0))
            draw_list:AddText(imgui.new('ImVec2', p.x + (w - banner_size.x) / 2, p.y - 2), banner_col, alarm_banner)
        end



        if is_manual_mode then
            imgui.SetCursorPosY(105)
            imgui.Columns(2, "HudControls", false)
            
            if alpr_hud_data.is_alert then
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.1, 0.1, 1.0))
                if imgui.Button("ACCEPT", imgui.new('ImVec2', -1, 20)) then
                    alpr_hud_data.is_alert = false
                    alpr_is_wanted_plate = false
                    
                    UI.alpr_manager[0] = true 
                end
                imgui.PopStyleColor()
            else
                if imgui.Button("MENU", imgui.new('ImVec2', -1, 20)) then
                    UI.alpr_log_window[0] = not UI.alpr_log_window[0]
                end
            end
            
            imgui.NextColumn()
            
            local mute_label = alpr_muted and "UNMUTE" or "MUTE"
            if imgui.Button(mute_label, imgui.new('ImVec2', -1, 20)) then
                alpr_muted = not alpr_muted
            end
            
            imgui.Columns(1)
        else
            local passive_label = "AUTO MODE"
            local passive_size = imgui.CalcTextSize(passive_label)
            draw_list:AddText(imgui.new('ImVec2', p.x + w - passive_size.x - 8, p.y + 90), 0xFFAAAAAA, passive_label)
        end
        
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

function renderUnitMiniHud()
    if not UI.unit_mini_hud[0] then return end
    if not core or not core.isAuthenticated or not core.isAuthenticated() then return end

    local unit = core.current_unit or {}
    local callsign = tostring(unit.unitID or unit.unitId or "N/A")
    local status_idx = tonumber(unit.status) or 4
    local unit_status = comboBoxData.status[status_idx + 1] or "Unknown"
    local fq_text = "Fq 912." .. tostring(tonumber(UI.unit_mini_hud_last_slot) or 1)
    local socket_connected = (cad_websocket and cad_websocket.get_status and tostring(cad_websocket.get_status() or "") == "CONNECTED")
    local socket_dot_color = socket_connected and 0xFF2ECC71 or 0xFFE74C3C
    local status_color = imgui.ImVec4(0.65, 0.65, 0.65, 1.0)
    local assignment_text = "STANDBY"
    local assignment_color = imgui.ImVec4(0.65, 0.65, 0.65, 1.0)
    if status_idx == 0 then
        status_color = imgui.ImVec4(0.18, 0.80, 0.44, 1.0)
    elseif status_idx == 1 then
        status_color = imgui.ImVec4(0.90, 0.30, 0.24, 1.0)
    elseif status_idx == 2 then
        status_color = imgui.ImVec4(1.00, 0.80, 0.00, 1.0)
    elseif status_idx == 3 then
        status_color = imgui.ImVec4(0.00, 0.50, 1.00, 1.0)
    end

    if callsign ~= "N/A" then
        local callsign_str = tostring(callsign)
        for _, incident in ipairs(data_storage.incidents or {}) do
            if incident and tostring(incident.status or "") ~= "Resolved" then
                local assigned_units = normalize_assigned_units(incident.assigned_units)
                for _, assigned in ipairs(assigned_units) do
                    if tostring(assigned) == callsign_str then
                        assignment_text = "INC #" .. tostring(incident.id or "?")
                        assignment_color = imgui.ImVec4(1.00, 0.45, 0.45, 1.0)
                        break
                    end
                end
            end
            if assignment_text ~= "STANDBY" then break end
        end

        if assignment_text == "STANDBY" then
            for _, call in ipairs(data_storage.calls or {}) do
                if not is_call_resolved_status(call.status) then
                    local assigned_units = normalize_assigned_units(call.assigned_units)
                    for _, assigned in ipairs(assigned_units) do
                        if tostring(assigned) == callsign_str then
                            assignment_text = "CALL #" .. tostring(call.server_call_id or call.id or "?")
                            assignment_color = imgui.ImVec4(1.00, 0.75, 0.35, 1.0)
                            break
                        end
                    end
                end
                if assignment_text ~= "STANDBY" then break end
            end
        end
    end

    local sw, _ = getScreenResolution()
    if UI.unit_mini_hud_pos_x < 0 or UI.unit_mini_hud_pos_y < 0 then
        UI.unit_mini_hud_pos_x = sw - 250
        UI.unit_mini_hud_pos_y = 170
    end
    imgui.SetNextWindowPos(imgui.new('ImVec2', UI.unit_mini_hud_pos_x, UI.unit_mini_hud_pos_y), imgui.Cond.Always)
    imgui.SetNextWindowBgAlpha(0.65)

    local can_drag_hud = UI.mdt[0]
    local flags = imgui.WindowFlags.NoTitleBar
        + imgui.WindowFlags.AlwaysAutoResize
        + imgui.WindowFlags.NoResize
        + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoSavedSettings
    if not can_drag_hud then
        flags = flags + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoInputs
    end

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 8, 5))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 5.0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0.70))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.26, 0.26, 0.26, 0.95))

    if imgui.Begin("UNIT_STATUS_MINIHUD", UI.unit_mini_hud, flags) then
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), tostring(callsign))
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.60, 0.60, 0.60, 1.0), "|")
        imgui.SameLine()
        imgui.TextColored(status_color, tostring(unit_status))
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.60, 0.60, 0.60, 1.0), "|")
        imgui.SameLine()
        imgui.TextColored(assignment_color, assignment_text)
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.60, 0.60, 0.60, 1.0), "|")
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.70, 0.78, 0.95, 1.0), fq_text)
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(0.60, 0.60, 0.60, 1.0), "|")
        imgui.SameLine()
        local p = imgui.GetCursorScreenPos()
        imgui.GetWindowDrawList():AddCircleFilled(imgui.new('ImVec2', p.x + 5, p.y + 7), 4.0, socket_dot_color, 16)
        imgui.Dummy(imgui.new('ImVec2', 12, 12))

        if can_drag_hud then
            local io = imgui.GetIO()
            if imgui.IsWindowHovered() and imgui.IsMouseClicked(0) then
                UI.unit_mini_hud_dragging = true
            end

            if UI.unit_mini_hud_dragging and imgui.IsMouseDown(0) then
                UI.unit_mini_hud_pos_x = UI.unit_mini_hud_pos_x + io.MouseDelta.x
                UI.unit_mini_hud_pos_y = UI.unit_mini_hud_pos_y + io.MouseDelta.y
            end

            if UI.unit_mini_hud_dragging and imgui.IsMouseReleased(0) then
                UI.unit_mini_hud_dragging = false
                settings.set('ui_settings', 'unit_mini_hud_pos_x', UI.unit_mini_hud_pos_x)
                settings.set('ui_settings', 'unit_mini_hud_pos_y', UI.unit_mini_hud_pos_y)
                settings.save()
            end
        end
    end
    imgui.End()

    imgui.PopStyleColor(2)
    imgui.PopStyleVar(2)
end

function renderALPRLogWindow()
    if not UI.alpr_log_window[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 700, 500), imgui.Cond.FirstUseEver)
    do
        local sw, _ = getScreenResolution()
        imgui.SetNextWindowPos(imgui.new('ImVec2', sw - 20, 180), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 1.0, 0.0))
    end
    if imgui.Begin("ALPR Scan Log", UI.alpr_log_window) then
        if imgui.Button("Clear Log") then
            alpr_scan_log = {}
            selected_alpr_log_index = nil
        end
        imgui.Separator()

        imgui.Columns(2)
        imgui.SetColumnWidth(0, 250)

        imgui.BeginChild("ScanList")
        for i, scan in ipairs(alpr_scan_log) do
            local is_hit_entry = (scan.alert == true) or (type(scan.match) == "string" and scan.match ~= "")
            local label = string.format("%s (%s)", scan.plate, scan.model)
            if is_hit_entry then
                label = "[HIT] " .. label
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 0.35, 0.35, 1))
            end
            if imgui.Selectable(label, selected_alpr_log_index == i) then
                selected_alpr_log_index = i
                safe_copy(alpr_log_comment_buffer, scan.notes or "")
            end
            if is_hit_entry then
                imgui.PopStyleColor()
            end
        end
        imgui.EndChild()

        imgui.NextColumn()

        imgui.BeginChild("ScanDetails")
        if selected_alpr_log_index and alpr_scan_log[selected_alpr_log_index] then
            local scan = alpr_scan_log[selected_alpr_log_index] 
            
            imgui.Text("Scan Details")
            imgui.Separator() 
            
                        renderLabeledText("Timestamp:", os.date("%Y-%m-%d %H:%M:%S", scan.timestamp), imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            renderLabeledText("Vehicle Model:", scan.model, imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            renderLabeledText("License Plate:", scan.plate, imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            renderLabeledText("Driver:", scan.driver, imgui.ImVec4(1,1,0,1), imgui.ImVec4(1,1,1,1))
            
            if imgui.Button("Copy Plate") then setClipboardText(scan.plate) end
            imgui.SameLine()
            if imgui.Button("Copy Driver") then setClipboardText(scan.driver) end
            
            imgui.Separator()
            imgui.Text("Notes:")
            imgui.InputTextMultiline("##alpr_notes", alpr_log_comment_buffer, ffi.sizeof(alpr_log_comment_buffer), imgui.new('ImVec2', -1, 100))
            
            if imgui.Button("Save Notes") then
                scan.notes = safe_str(alpr_log_comment_buffer)
            end
        else
            imgui.Text("Select a scan from the list to see details.")
        end
        imgui.EndChild()

        imgui.Columns(1)
        
    end
    imgui.End()
end


function renderALPRManager()
    if not UI.alpr_manager[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 600, 450), imgui.Cond.FirstUseEver)
    

    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.08, 0.08, 0.10, 0.98))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, imgui.ImVec4(0.08, 0.08, 0.10, 1.0))
    
    if imgui.Begin("ALPR System Manager", UI.alpr_manager) then
        

        imgui.PushFont(fonts[22])
        imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1), "ALPR CONTROL PANEL")
        imgui.PopFont()
        imgui.Separator()
        
        if imgui.BeginTabBar("ALPRTabs") then
            

            if imgui.BeginTabItem(" READ HISTORY ") then
                imgui.BeginChild("HistoryList", imgui.new('ImVec2', 0, -40), true)
                    

                    imgui.Columns(4, "HistCols", false)
                    imgui.SetColumnWidth(0, 80)  -- Time
                    imgui.SetColumnWidth(1, 100) -- Plate
                    imgui.SetColumnWidth(2, 60)  -- Cam
                    
                    imgui.TextDisabled("TIME")
                    imgui.NextColumn()
                    imgui.TextDisabled("PLATE")
                    imgui.NextColumn()
                    imgui.TextDisabled("CAM")
                    imgui.NextColumn()
                    imgui.TextDisabled("VEHICLE INFO")
                    imgui.NextColumn()
                    imgui.Separator()
                    

                    for i, scan in ipairs(alpr_scan_log) do
                        local time_str = os.date("%H:%M:%S", scan.timestamp)
                        local col = imgui.ImVec4(1,1,1,1)
                        if scan.alert or (type(scan.match) == "string" and scan.match ~= "") then
                            col = imgui.ImVec4(1, 0.3, 0.3, 1)
                        end
                        
                        imgui.TextColored(col, time_str)
                        imgui.NextColumn()
                        
                        imgui.PushFont(fonts[18])
                        imgui.TextColored(col, scan.plate)
                        imgui.PopFont()
                        imgui.NextColumn()
                        
                        imgui.TextColored(imgui.ImVec4(0.6,0.6,0.6,1), scan.cam or "FWD")
                        imgui.NextColumn()
                        
                        imgui.TextColored(col, scan.model)
                        imgui.NextColumn()
                        
                        imgui.Separator()
                    end
                    imgui.Columns(1)
                    
                imgui.EndChild()
                
                if imgui.Button("CLEAR HISTORY", imgui.new('ImVec2', 150, 30)) then
                    alpr_scan_log = {}
                end
                
                imgui.EndTabItem()
            end
            

            if imgui.BeginTabItem(" SYSTEM SETTINGS ") then
                imgui.Dummy(imgui.new('ImVec2', 0, 10))
                
                imgui.TextDisabled("AUDIO CONFIGURATION")

                imgui.Checkbox("Play Alert Sound", imgui.new.bool(true))
                imgui.Checkbox("Voice Announcement (TTS)", imgui.new.bool(false))
                
                imgui.Dummy(imgui.new('ImVec2', 0, 10))
                imgui.Separator()
                imgui.Dummy(imgui.new('ImVec2', 0, 10))
                
                imgui.TextDisabled("CAMERA CONFIGURATION")
                if imgui.Checkbox("Front Camera", alpr_camera_config.front) then
                    if settings then
                        settings.set('alpr_settings', 'cam_front', alpr_camera_config.front[0])
                        settings.save()
                    end
                end
                if imgui.Checkbox("Rear Camera", alpr_camera_config.rear) then
                    if settings then
                        settings.set('alpr_settings', 'cam_rear', alpr_camera_config.rear[0])
                        settings.save()
                    end
                end
                if imgui.Checkbox("Side Cameras", alpr_camera_config.sides) then
                    if settings then
                        settings.set('alpr_settings', 'cam_sides', alpr_camera_config.sides[0])
                        settings.save()
                    end
                end
                
                imgui.EndTabItem()
            end
            
            imgui.EndTabBar()
        end
    end
    imgui.End()
    imgui.PopStyleColor(2)
end

local function renderUnitTable(title, unit_list)
    imgui.Text(string.format("%s (%d)", title, #unit_list));
    imgui.Separator()

    if #unit_list == 0 then
        imgui.Text("No active units found or data not yet loaded.")
        return
    end

    local columns = {
        {name="Unit", width=100},
        {name="Officer 1", width=220},
        {name="Officer 2", width=220},
        {name="Status", width=140},
        {name="Location", width=-1},
    }

    local function row_renderer(unit, i)
        imgui.Text(unit.unitID or "N/A"); imgui.NextColumn()
        imgui.Text(unit.officer1_name or "N/A"); imgui.NextColumn()
        imgui.Text(unit.officer2_name or ""); imgui.NextColumn()

        local current_status = tonumber(unit.status)
        if current_status and comboBoxData and comboBoxData.status[current_status + 1] then
             local status_text = comboBoxData.status[current_status + 1]
             local status_color = (patrol_status_color_map and patrol_status_color_map[current_status + 1]) or status_colors.gray
             imgui.TextColored(status_color, status_text); imgui.NextColumn()
        else
             imgui.Text("Invalid Status"); imgui.NextColumn()
        end

        imgui.Text(unit.location or "N/A");
    end

    renderTable("unit_table", columns, unit_list, row_renderer, {selected_index = selectedPatrolUnit, on_select = function(i) selectedPatrolUnit = unit_list[i] end})
end

function renderDiscordLogin()
    local avail_w = imgui.GetContentRegionAvail().x
    
    if fonts[22] then imgui.PushFont(fonts[22]) end
    local text = "TERMINAL ACCESS"
    local text_size = imgui.CalcTextSize(text)
    imgui.SetCursorPosX((avail_w - text_size.x) / 2)
    imgui.TextColored(imgui.ImVec4(0.45, 0.53, 0.85, 1.0), text)
    if fonts[22] then imgui.PopFont() end

    local sub_text = "Identify yourself to continue"
    imgui.SetCursorPosX((avail_w - imgui.CalcTextSize(sub_text).x) / 2)
    imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.6, 1), sub_text)
    
    imgui.Dummy(imgui.new('ImVec2', 0, 15))
    
    imgui.SetCursorPosX((avail_w - 220) / 2)
    if imgui.Button(fa.ICON_FA_RIGHT_FROM_BRACKET .. " Открыть Discord сервер", imgui.new('ImVec2', 220, 30)) then
        os.execute('explorer "https://discord.gg/AfRUXtfQ8C"')
    end
    
    imgui.Dummy(imgui.new('ImVec2', 0, 15))
    
    drawStyledInput("6-DIGIT CODE", discord_auth.code, 7, avail_w, 0, fa.ICON_FA_SHIELD_HALVED)
    
    if discord_auth.is_loading then
        local loading_text = "Authenticating..."
        imgui.SetCursorPosX((avail_w - imgui.CalcTextSize(loading_text).x) / 2)
        imgui.TextColored(imgui.ImVec4(0.0, 0.7, 1.0, 1), loading_text)
    elseif discord_auth.error_message ~= "" then
        imgui.PushTextWrapPos(avail_w)
        imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), fa.ICON_FA_TRIANGLE_EXCLAMATION .. " " .. discord_auth.error_message)
        imgui.PopTextWrapPos()
    end
    
    imgui.Dummy(imgui.new('ImVec2', 0, 15))
    
    if not discord_auth.is_loading then
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.0, 0.4, 0.8, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.1, 0.5, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.0, 0.3, 0.7, 1.0))
        
        if imgui.Button("VERIFY IDENTITY", imgui.new('ImVec2', avail_w, 45)) then
            local code = ffi.string(discord_auth.code)
            if #code == 6 then
                discord_auth.is_loading = true
                discord_auth.error_message = ""
                core.verifyDiscordCode(code)
            else
                discord_auth.error_message = "Код должен быть 6-значным"
            end
        end
        imgui.PopStyleColor(3)
    end
end

function renderCharacterSelection()
    local avail_w = imgui.GetContentRegionAvail().x
    local style = imgui.GetStyle()
    
    if fonts[18] then imgui.PushFont(fonts[18]) end
    imgui.Text("IDENTIFIED USER")
    if fonts[18] then imgui.PopFont() end
    imgui.Separator()
    imgui.Dummy(imgui.new('ImVec2', 0, 10))
    
    for i = 1, 2 do
        local char = discord_auth.characters[i]
        
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 5.0)
        
        local child_flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
        
        imgui.BeginChild("Slot" .. i, imgui.new('ImVec2', avail_w, 100), true, child_flags)
        if char then
            imgui.SetCursorPosY(15)
            
            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.Text(char.full_name)
            if fonts[18] then imgui.PopFont() end
            
            imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), "BADGE: #" .. (char.badge_number or "N/A"))
            imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), "ROLE: " .. tostring(char.role):upper())
            
            local btn_w = 80
            local padding_right = style.WindowPadding.x + 10
            
            imgui.SetCursorPos(imgui.new('ImVec2', avail_w - btn_w - padding_right, 35))
            if imgui.Button("SELECT##" .. char.id, imgui.new('ImVec2', btn_w, 30)) then
                core.selectCharacter(char.id, discord_auth.discord_id)
            end
        else
            imgui.SetCursorPos(imgui.new('ImVec2', (avail_w - 30) / 2, 20))
            imgui.Text(fa.ICON_FA_USER)
            
            imgui.SetCursorPos(imgui.new('ImVec2', (avail_w - 150) / 2, 55))
            if imgui.Button("NEW CHARACTER##" .. i, imgui.new('ImVec2', 150, 30)) then
                discord_auth.state = 'registration'
                safe_copy(registration_buffers.full_name, "")
                safe_copy(registration_buffers.badge, "")
            end
        end
        imgui.EndChild()
        imgui.PopStyleVar()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))
    end
    
    imgui.Dummy(imgui.new('ImVec2', 0, 10))
    
    if imgui.Button("LOGOUT", imgui.new('ImVec2', avail_w, 35)) then
        discord_auth.state = 'login'
        discord_auth.discord_id = nil
        safe_copy(discord_auth.code, "")
    end
end

function renderCharacterRegistration()
    local avail_w = imgui.GetContentRegionAvail().x
    
    if fonts[18] then imgui.PushFont(fonts[18]) end
    imgui.Text("CHARACTER REGISTRATION")
    if fonts[18] then imgui.PopFont() end
    imgui.Separator()
    imgui.Dummy(imgui.new('ImVec2', 0, 10))
    
    drawStyledInput("FULL NAME (FIRST LAST)", registration_buffers.full_name, 64, avail_w, 0, fa.ICON_FA_USER)
    drawStyledInput("BADGE NUMBER", registration_buffers.badge, 32, avail_w, 0, fa.ICON_FA_ID_CARD)
    
    if registration_buffers.error ~= "" then
        imgui.PushTextWrapPos(avail_w)
        imgui.TextColored(imgui.ImVec4(1, 0.3, 0.3, 1), fa.ICON_FA_TRIANGLE_EXCLAMATION .. " " .. registration_buffers.error)
        imgui.PopTextWrapPos()
    end
    
    imgui.Dummy(imgui.new('ImVec2', 0, 15))
    
    if imgui.Button("CREATE CHARACTER", imgui.new('ImVec2', avail_w, 45)) then
        local name = ffi.string(registration_buffers.full_name)
        if #name > 3 and name:find(" ") then
            core.createCharacter(name, ffi.string(registration_buffers.badge), discord_auth.discord_id)
        else
            registration_buffers.error = "Enter Full Name (e.g. John Doe)"
        end
    end
    
    imgui.Dummy(imgui.new('ImVec2', 0, 5))
    if imgui.Button("CANCEL", imgui.new('ImVec2', avail_w, 30)) then
        discord_auth.state = 'selection'
    end
end

function renderDiscordAuthUI()
    local avail_w = imgui.GetContentRegionAvail().x
    
    if discord_auth.state == 'login' then
        renderDiscordLogin()
    elseif discord_auth.state == 'selection' then
        renderCharacterSelection()
    elseif discord_auth.state == 'registration' then
        renderCharacterRegistration()
    end
end

function renderLoginWindow()
    local sw, sh = getScreenResolution()
    local win_h = 500
    local win_w = 400

    imgui.SetNextWindowSize(imgui.new('ImVec2', win_w, win_h), imgui.Cond.Always)
    imgui.SetNextWindowPos(imgui.new('ImVec2', sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))

    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.05, 0.05, 0.07, 0.95))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.2, 0.2, 0.25, 0.5))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 25, 25))

    if imgui.Begin("##AuthWindow", UI.login_window, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoTitleBar) then
        local icon_size = 60
        imgui.SetCursorPosX((win_w - icon_size) / 2)
        if fonts[22] then
            imgui.PushFont(fonts[22])
            imgui.SetWindowFontScale(2.0)
            imgui.TextColored(imgui.ImVec4(0.45, 0.53, 0.85, 1.0), fa.ICON_FA_USER_SHIELD)
            imgui.SetWindowFontScale(1.0)
            imgui.PopFont()
        end

        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        renderDiscordAuthUI()

        imgui.Dummy(imgui.new('ImVec2', 0, 15))
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        local footer_text = "CAD System - Discord Auth"
        local ft_w = imgui.CalcTextSize(footer_text).x
        imgui.SetCursorPosX((win_w - ft_w) / 2)
        imgui.TextColored(imgui.ImVec4(0.4, 0.4, 0.5, 1), footer_text)
    end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(2)
end

function renderUnitMiniMap(unit)
    if not unit or not unit.pos_x or not unit.pos_y then
        imgui.Text("Unit position not available.")
        return
    end


    local minimap_width = imgui.GetContentRegionAvail().x
    local minimap_height = 350

    local draw_list = imgui.GetWindowDrawList()
    local widget_pos = imgui.GetCursorScreenPos()

    local world_view_height = 750.0
    local world_view_width = world_view_height * (minimap_width / minimap_height)

    local world_x_start = unit.pos_x - world_view_width / 2
    local world_y_start = unit.pos_y + world_view_height / 2

    for y_tile = 0, 3 do
        for x_tile = 0, 3 do
            local tile_index = y_tile * 4 + x_tile + 1
            local texture = map_tile_textures.standard[tile_index]

            if texture then
                local tile_world_x0 = -3000.0 + x_tile * 1500.0
                local tile_world_y1 = 3000.0 - y_tile * 1500.0
                local tile_world_x1 = tile_world_x0 + 1500.0
                local tile_world_y0 = tile_world_y1 - 1500.0

                local intersect_x0 = math.max(world_x_start, tile_world_x0)
                local intersect_y1 = math.min(world_y_start, tile_world_y1)
                local intersect_x1 = math.min(world_x_start + world_view_width, tile_world_x1)
                local intersect_y0 = math.max(world_y_start - world_view_height, tile_world_y0)

                if intersect_x1 > intersect_x0 and intersect_y1 > intersect_y0 then

                    local u0 = (intersect_x0 - tile_world_x0) / 1500.0
                    local v0 = (tile_world_y1 - intersect_y1) / 1500.0
                    local u1 = (intersect_x1 - tile_world_x0) / 1500.0
                    local v1 = (tile_world_y1 - intersect_y0) / 1500.0

                    local screen_x0 = widget_pos.x + ((intersect_x0 - world_x_start) / world_view_width) * minimap_width
                    local screen_y0 = widget_pos.y + ((world_y_start - intersect_y1) / world_view_height) * minimap_height
                    local screen_x1 = widget_pos.x + ((intersect_x1 - world_x_start) / world_view_width) * minimap_width
                    local screen_y1 = widget_pos.y + ((world_y_start - intersect_y0) / world_view_height) * minimap_height

                    draw_list:AddImage(texture, imgui.new('ImVec2', screen_x0, screen_y0), imgui.new('ImVec2', screen_x1, screen_y1), imgui.new('ImVec2', u0, v0), imgui.new('ImVec2', u1, v1))
                end
            end
        end
    end
    
    imgui.SetCursorPosY(imgui.GetCursorPosY() + minimap_height)

    local center_x = widget_pos.x + minimap_width / 2
    local center_y = widget_pos.y + minimap_height / 2

    draw_list:AddCircleFilled(imgui.new('ImVec2', center_x, center_y), 5, 0xFF00FF00)
    draw_list:AddText(imgui.new('ImVec2', center_x + 8, center_y - 8), 0xFFFFFFFF, unit.unitID or 'N/A')
end

local status_colors_modern = {
    [0] = 0xFF2ECC71, -- Available
    [1] = 0xFFE74C3C, -- Enroute
    [2] = 0xFFFFCC00, -- On Scene
    [3] = 0xFF0080FF, -- Busy/Panic
    [4] = 0xFF95A5A6  -- Out of Service
}


local call_status_colors_hex = {
    ['Pending']  = 0xFF00A5FF,
    ['En-route'] = 0xFFFF8000, -- Синий
    ['Clear']    = 0xFF2ECC71, -- Зеленый
    ['Default']  = 0xFF808080  -- Серый
}

local incident_status_colors_hex = {
    ['Active']              = 0xFF0000D0, -- Красный (Активный)
    ['Under Investigation'] = 0xFF0080FF, -- Оранжевый
    ['Code 4']              = 0xFFFFCC00,
    ['Resolved']            = 0xFF2ECC71, -- Зеленый
    ['Default']             = 0xFF808080
}

local function drawModernIncidentCard(incident, is_selected)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local width = imgui.GetColumnWidth() - 10 
    local height = 60
    local rounding = 6.0


    local status_key = incident.status or 'Active'
    local color = incident_status_colors_hex[status_key] or incident_status_colors_hex['Default']
    
    local btn_unique_name = "##inc_card_" .. tostring(incident.id)
    

    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
    local clicked = imgui.Button(btn_unique_name, imgui.new('ImVec2', width, height))
    imgui.PopStyleColor(3)
    

    local is_hovered = imgui.IsItemHovered()
    local bg_color = is_selected and 0xFF454545 or 0xFF252A33
    if is_hovered and not is_selected then bg_color = 0xFF353A45 end

    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), bg_color, rounding)
    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + 5, p.y + height), color, rounding, 1+8)


    local content_start_x = p.x + 15
    local top_padding = 6
    

    local id_text = "#" .. tostring(incident.id)
    local id_size = imgui.CalcTextSize(id_text)
    draw_list:AddText(imgui.new('ImVec2', p.x + width - id_size.x - 10, p.y + top_padding), 0xFF808080, id_text)


    local summary = incident.summary or "No Summary"
    if #summary > 40 then summary = summary:sub(1, 37) .. "..." end
    
    if fonts[18] then imgui.PushFont(fonts[18]) end
    draw_list:AddText(imgui.new('ImVec2', content_start_x, p.y + top_padding), 0xFFFFFFFF, summary)
    if fonts[18] then imgui.PopFont() end


    local sub_text = incident.location or "Unknown Loc"
    local icon = fa.ICON_FA_LOCATION_DOT
    
    if incident.tactical_channel then

        sub_text = "CH 912." .. incident.tactical_channel .. "  |  " .. sub_text
        icon = fa.ICON_FA_walkie_talkie or fa.ICON_FA_TRIANGLE_EXCLAMATION
    end

    if #sub_text > 45 then sub_text = sub_text:sub(1, 42) .. "..." end
    draw_list:AddText(imgui.new('ImVec2', content_start_x, p.y + 32), 0xFFAAAAAA, icon .. " " .. sub_text)


    local status_txt = (incident.status or ""):upper()
    local st_size = imgui.CalcTextSize(status_txt)
    draw_list:AddText(imgui.new('ImVec2', p.x + width - st_size.x - 10, p.y + height - 18), color, status_txt)

    return clicked
end


local function drawModernCallCard(call, is_selected)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local width = imgui.GetColumnWidth() - 10 
    local height = 55
    local rounding = 6.0


    local status_key = call.status or 'Pending'
    local color = call_status_colors_hex[status_key] or call_status_colors_hex['Default']
    

    local btn_unique_name = "##call_card_" .. tostring(call.id)

    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
    local clicked = imgui.Button(btn_unique_name, imgui.new('ImVec2', width, height))
    imgui.PopStyleColor(3)
    

    local is_hovered = imgui.IsItemHovered()
    local bg_color = is_selected and 0xFF454545 or 0xFF252A33
    if is_hovered and not is_selected then bg_color = 0xFF353A45 end


    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), bg_color, rounding)
    


    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + 5, p.y + height), color, rounding, 1+8)


    local content_start_x = p.x + 15
    local top_padding = 6
    

    local id_text = "#" .. tostring(call.id)
    if call.server_call_id then
        id_text = id_text .. " (" .. tostring(call.server_call_id) .. ")"
    end
    local id_size = imgui.CalcTextSize(id_text)
    draw_list:AddText(imgui.new('ImVec2', p.x + width - id_size.x - 10, p.y + top_padding), 0xFF808080, id_text)


    local details = call.description or {}
    local summary = details.incident_details or "No details provided"
    

    if #summary > 45 then summary = summary:sub(1, 42) .. "..." end
    

    if fonts[18] then imgui.PushFont(fonts[18]) end
    draw_list:AddText(imgui.new('ImVec2', content_start_x, p.y + top_padding), 0xFFFFFFFF, summary)
    if fonts[18] then imgui.PopFont() end


    local location = details.location or "Unknown Location"
    if #location > 50 then location = location:sub(1, 47) .. "..." end
    draw_list:AddText(imgui.new('ImVec2', content_start_x, p.y + 28), 0xFFAAAAAA, fa.ICON_FA_LOCATION_DOT .. " " .. location)


    local status_txt = (call.status or "Pending"):upper()
    local st_size = imgui.CalcTextSize(status_txt)
    draw_list:AddText(imgui.new('ImVec2', p.x + width - st_size.x - 10, p.y + height - 18), color, status_txt)




    
    return clicked
end


local function drawModernUnitCard(unit, is_selected)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local width = imgui.GetColumnWidth() - 10 
    local height = 40 
    local rounding = 4.0


    local status_idx = tonumber(unit.status) or 4
    local color = status_colors_modern[status_idx] or status_colors_modern[4]
    




    local btn_unique_name = "##unit_card_" .. tostring(unit.id)
    local clicked = imgui.InvisibleButton(btn_unique_name, imgui.new('ImVec2', width, height))
    

    local bg_color = is_selected and 0xFF3A4149 or 0xFF252A33 
    if imgui.IsItemHovered() then bg_color = 0xFF2F3640 end 
    

    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), bg_color, rounding)


    local badge_width = 60


    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + badge_width, p.y + height), color, rounding, 9) 
    

    local unit_id_text = tostring(unit.unitID or "?")
    local text_size = imgui.CalcTextSize(unit_id_text)
    local text_pos_x = p.x + (badge_width - text_size.x) / 2
    local text_pos_y = p.y + (height - text_size.y) / 2
    
    drawOutlinedText(draw_list, imgui.new('ImVec2', text_pos_x, text_pos_y), unit_id_text, 0xFFFFFFFF, 0xAA000000)


    local info_x = p.x + badge_width + 10
    
    local status_text = comboBoxData.status[status_idx + 1] or "Unknown"
    draw_list:AddText(imgui.new('ImVec2', info_x, p.y + 4), color, status_text)

    local slot_num = tonumber(unit.current_channel_id)
    if not slot_num or slot_num <= 0 then
        if is_unit_for_current_user(unit) then
            slot_num = tonumber(UI.unit_mini_hud_last_slot)
        end
    end
    if slot_num and slot_num > 0 then
        local fq_text = "Fq 912." .. tostring(slot_num)
        local fq_size = imgui.CalcTextSize(fq_text)
        local fq_x = p.x + width - fq_size.x - 10
        local fq_y = p.y + 4
        draw_list:AddText(imgui.new('ImVec2', fq_x, fq_y), 0xFF808080, fq_text)
    end

    local location_text = tostring(unit.location or "N/A")
    if #location_text > 35 then location_text = string.sub(location_text, 1, 32) .. "..." end
    draw_list:AddText(imgui.new('ImVec2', info_x, p.y + 22), 0xFFAAAAAA, location_text)


    imgui.SetCursorPosY(imgui.GetCursorPosY() - height + 45) 

    return clicked
end

local function renderSidebarIcon(icon, tab_index, current_tab_ptr, size)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local is_selected = (current_tab_ptr == tab_index)
    

    local col_bg_active = 0xFF3D3D3D
    local col_bg_hover = 0xFF2E2E2E
    local col_accent = 0xFFFF9900
    local col_icon_active = 0xFFFFFFFF
    local col_icon_inactive = 0xFF909090


    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
    local clicked = imgui.Button("##sidebar_btn_"..tab_index, size)
    imgui.PopStyleColor(3)

    local hovered = imgui.IsItemHovered()


    if is_selected then
        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + size.x, p.y + size.y), col_bg_active, 4.0)

        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + 4, p.y + size.y), col_accent, 4.0, 1+8)
    elseif hovered then
        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + size.x, p.y + size.y), col_bg_hover, 4.0)
    end


    local icon_size = imgui.CalcTextSize(icon)
    local icon_pos = imgui.new('ImVec2', p.x + (size.x - icon_size.x) / 2, p.y + (size.y - icon_size.y) / 2)
    
    local icon_col = is_selected and col_icon_active or col_icon_inactive
    if hovered and not is_selected then icon_col = 0xFFE0E0E0 end
    
    draw_list:AddText(icon_pos, icon_col, icon)

    return clicked
end

local nav_tabs = {
    { id = 1, icon = fa.ICON_FA_TABLE_LIST, label = "CALLS" },      
    { id = 2, icon = fa.ICON_FA_TRIANGLE_EXCLAMATION, label = "INCIDENTS" }, 
    { id = 3, icon = fa.ICON_FA_CAR_SIDE, label = "UNITS" },        
    { id = 4, icon = fa.ICON_FA_ID_CARD, label = "MY INFO" },       
    { id = 5, icon = fa.ICON_FA_GEARS, label = "SYSTEM" }           
}


local current_mdt_tab = 1 

local function renderNavButton(icon, label, tab_id, selected_id)
    local is_selected = (tab_id == selected_id)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local btn_height = 45
    local btn_width = 115 
    
    local col_bg = is_selected and 0xFF353535 or 0x00000000
    local col_text = is_selected and 0xFFFFFFFF or 0xFF909090
    local col_accent = 0xFFFF9900 

    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1,1,1,0.05))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(1,1,1,0.1))
    
    local result = imgui.Button("##nav_"..label, imgui.new('ImVec2', btn_width, btn_height))
    imgui.PopStyleColor(3)

    if is_selected then
        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + btn_width, p.y + btn_height), col_bg, 4.0)
        draw_list:AddRectFilled(imgui.new('ImVec2', p.x + 20, p.y + btn_height - 3), imgui.new('ImVec2', p.x + btn_width - 20, p.y + btn_height), col_accent, 2.0)
    elseif imgui.IsItemHovered() then
         draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + btn_width, p.y + btn_height), 0xFF252525, 4.0)
    end


    if fonts[18] then imgui.PushFont(fonts[18]) end

    local icon_size = imgui.CalcTextSize(icon)
    local label_size = imgui.CalcTextSize(label)
    
    local content_width = icon_size.x + 8 + label_size.x
    local start_x = p.x + (btn_width - content_width) / 2
    local center_y = p.y + (btn_height - icon_size.y) / 2

    draw_list:AddText(imgui.new('ImVec2', start_x, center_y), col_text, icon)
    draw_list:AddText(imgui.new('ImVec2', start_x + icon_size.x + 8, center_y), col_text, label)

    if fonts[18] then imgui.PopFont() end

    return result
end

local function drawInfoCard(label, value, width, icon)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local height = 45
    

    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), 0xFF1E2228, 6.0)
    draw_list:AddRect(p, imgui.new('ImVec2', p.x + width, p.y + height), 0xFF353A45, 6.0)


    local content_offset = 10
    if icon then
        imgui.PushFont(fonts[22])
        draw_list:AddText(imgui.new('ImVec2', p.x + 10, p.y + 10), 0xFF606060, icon)
        imgui.PopFont()
        content_offset = 40
    end


    draw_list:AddText(imgui.new('ImVec2', p.x + content_offset, p.y + 5), 0xFF808080, label:upper())
    

    local val_str = tostring(value or "N/A")
    if #val_str > 40 then val_str = val_str:sub(1, 37).."..." end
    

    if fonts[18] then imgui.PushFont(fonts[18]) end
    draw_list:AddText(imgui.new('ImVec2', p.x + content_offset, p.y + 20), 0xFFFFFFFF, val_str)
    if fonts[18] then imgui.PopFont() end


    imgui.Dummy(imgui.new('ImVec2', width, height))
end


local function renderCallsTab()
    local main_w, main_h = imgui.GetContentRegionAvail().x, imgui.GetContentRegionAvail().y
    
    imgui.Columns(2, "CallsTabColumns", false)
    imgui.SetColumnWidth(0, 420) 


    imgui.BeginChild("CallList", imgui.new('ImVec2', 0, 0), true)
        
        local calls_to_display = {}
        local should_hide_placeholders = settings.get('ui_settings', 'hide_placeholder_calls', false)
        local placeholder_text = "Происходит что-то неладное!"

        for _, call in ipairs(data_storage.calls) do
            local should_hide = false
            if should_hide_placeholders and call.description and call.description.incident_details == placeholder_text then
                should_hide = true
            end
            if call.type == 'INCIDENT' then should_hide = true end
            if not should_hide then table.insert(calls_to_display, call) end
        end

        imgui.TextDisabled("АКТИВНЫЕ ВЫЗОВЫ (" .. #calls_to_display .. ")")
        imgui.Separator()

        if #calls_to_display == 0 then
            imgui.Text("No active calls.")
        else
            for i, call in ipairs(calls_to_display) do
                local is_selected = selected_call_index and data_storage.calls[selected_call_index] and data_storage.calls[selected_call_index].id == call.id
                
                if drawModernCallCard(call, is_selected) then
                    for original_idx, original_call in ipairs(data_storage.calls) do
                        if original_call.id == call.id then
                            selected_call_index = original_idx
                            break
                        end
                    end
                end
                imgui.Dummy(imgui.new('ImVec2', 0, 5))
            end
        end
    imgui.EndChild()

    imgui.NextColumn()


    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.1, 0.1, 0.12, 1.0))
    imgui.BeginChild("CallDetails", imgui.new('ImVec2', 0, 0), true)
        if selected_call_index and data_storage.calls[selected_call_index] then
            local call = data_storage.calls[selected_call_index]
            local details = call.description or {}
            local width = imgui.GetContentRegionAvail().x

            --[[imgui.BeginGroup()
                imgui.PushFont(fonts[22])
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "CALL #" .. tostring(call.id))
                imgui.PopFont()

                local date_str = ToMSK(call.created_at or call.timestamp)
                if date_str ~= "N/A" then
                    imgui.SameLine()
                    imgui.SetCursorPosY(imgui.GetCursorPosY() + 5)
                    imgui.TextDisabled(date_str)
                end
            imgui.EndGroup()]]
            imgui.BeginGroup()
                imgui.PushFont(fonts[22])
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "CALL #" .. tostring(call.id))
                imgui.PopFont()

                local offset_applied = false


                if call.server_call_id then
                    imgui.SameLine()
                    imgui.SetCursorPosY(imgui.GetCursorPosY() + 5)
                    imgui.TextDisabled("(SERVER ID: " .. tostring(call.server_call_id) .. ")")
                    offset_applied = true
                end

                local date_str = ToMSK(call.created_at or call.timestamp)
                if date_str ~= "N/A" then
                    imgui.SameLine()

                    if not offset_applied then
                        imgui.SetCursorPosY(imgui.GetCursorPosY() + 5)
                    end
                    imgui.TextDisabled(date_str)
                end
            imgui.EndGroup()

            imgui.SameLine()
            

            local status_txt = (call.status or "Pending"):upper()
            local status_w = 100
            imgui.SetCursorPosX(width - status_w)
            
            local st_col = imgui.ImVec4(0.5, 0.5, 0.5, 1)
            if call.status == 'Pending' then st_col = imgui.ImVec4(1.0, 0.6, 0.0, 1.0) end
            if call.status == 'En-route' then st_col = imgui.ImVec4(0.0, 0.5, 1.0, 1.0) end
            if call.status == 'Clear' then st_col = imgui.ImVec4(0.2, 0.8, 0.2, 1.0) end

            imgui.PushStyleColor(imgui.Col.Button, st_col)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, st_col)
            imgui.PushStyleColor(imgui.Col.ButtonActive, st_col)
            imgui.Button(status_txt, imgui.new('ImVec2', status_w, 30))
            imgui.PopStyleColor(3)

            imgui.Separator()
            imgui.Dummy(imgui.new('ImVec2', 0, 10))



            drawInfoCard("Location", details.location or "Unknown", width, fa.ICON_FA_LOCATION_DOT)
            imgui.Dummy(imgui.new('ImVec2', 0, 5))
            

            local half_w = (width - 10) / 2
            drawInfoCard("Caller", details.caller_name or "Anonymous", half_w, fa.ICON_FA_USER)
            imgui.SameLine()
            drawInfoCard("Phone", details.phone_number or "N/A", half_w, fa.ICON_FA_PHONE)
            
            imgui.Dummy(imgui.new('ImVec2', 0, 15))


            imgui.TextDisabled("INCIDENT DETAILS")
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 1.0))
            imgui.BeginChild("DescBlock", imgui.new('ImVec2', 0, 80), true)
                imgui.PushFont(fonts[18])
                imgui.TextWrapped(details.incident_details or "No description provided.")
                imgui.PopFont()
            imgui.EndChild()
            imgui.PopStyleColor()

            imgui.Dummy(imgui.new('ImVec2', 0, 10))


            local btn_w = (width - 10) / 3
            

            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.0, 0.45, 0.7, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.1, 0.55, 0.8, 1.0))
            if imgui.Button("ASSIGN ME", imgui.new('ImVec2', btn_w, 40)) then
                updateCallStatus(call.id, "accept", safe_str(unitInfoBuffers.unitID))
                sampSendChat('/accept ' .. tostring(call.server_call_id))
                cadui_module.setPendingCheckpointForCall(call.id)
                unitInfoBuffers.status[0] = 1

                -- Auto set radio channel if provided in call
                if call.tactical_channel and tonumber(call.tactical_channel) then
                    setRadioChannel(tonumber(call.tactical_channel))
                end

                broadcastUnitStatus()
                if core.fetchAbasData then
                    core.fetchAbasData()
                end
            end
            imgui.PopStyleColor(2)
            imgui.SameLine()


            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.4, 0.0, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.5, 0.1, 1.0))
            if imgui.Button("NEW EVENT", imgui.new('ImVec2', btn_w, 40)) then
                 arm_pending_incident_marker_seed("create_from_call", 25)
                 send_ws_request('incident', 'create_from_call', { call_id = call.id }, function(data, err)
                    if not err and data and data.success then
                        local new_incident = data.payload and data.payload.incident or nil
                        local new_id = (new_incident and new_incident.id) or (data.payload and data.payload.id)
                        if new_id then
                            send_ws_request('tactical', 'accept_assist', { incident_id = new_id })
                            cadui_module.touchIncidentWaypoint(new_id, 'create_from_call_accept')
                            consume_pending_incident_marker_seed()
                            addNotification(
                                "NEW EVENT CREATED",
                                string.format("Incident #%s was created from call #%s.", tostring(new_id), tostring(call.server_call_id or call.id)),
                                8,
                                nil,
                                "incident_created"
                            )
                        else
                            addNotification("NEW EVENT", "Event was created, but incident ID was not returned.", 8)
                        end
                    else
                        addNotification("NEW EVENT FAILED", tostring(err or (data and data.error) or "Unknown error"), 10)
                    end
                 end)
                 selected_call_index = nil
            end
            imgui.PopStyleColor(2)
            imgui.SameLine()


            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 0.2, 1.0))
            if imgui.Button("RESOLVE", imgui.new('ImVec2', btn_w, 40)) then
                updateCallStatus(call.id, "clear", safe_str(unitInfoBuffers.unitID))
            end
            imgui.PopStyleColor(1)

            imgui.Dummy(imgui.new('ImVec2', 0, 10))


            imgui.TextDisabled("ASSIGNED UNITS")
            if call.assigned_units and #call.assigned_units > 0 then
                for _, u in ipairs(call.assigned_units) do
                    local unit_label = tostring(u)
                    local is_lspd = unit_label:find("LSPD", 1, true) ~= nil
                    local btn_color = is_lspd and imgui.ImVec4(0.2, 0.5, 0.8, 1.0) or imgui.ImVec4(0.25, 0.25, 0.3, 1.0)
                    local caption = is_lspd and "LSPD" or unit_label
                    imgui.PushStyleColor(imgui.Col.Button, btn_color)
                    imgui.Button(fa.ICON_FA_CAR_SIDE .. " " .. caption)
                    imgui.PopStyleColor()
                    imgui.SameLine()
                end
                imgui.NewLine()
            else
                imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "No units assigned.")
            end

            imgui.Dummy(imgui.new('ImVec2', 0, 5))
            imgui.Separator()



            if imgui.BeginTabBar("CallBottomTabs") then
                if imgui.BeginTabItem("Events Log") then
                    imgui.BeginChild("LogScroll", imgui.new('ImVec2', 0, 120), true)
                    if call.event_log then
                        for _, event in ipairs(call.event_log) do
                            imgui.TextDisabled(event.time or "")
                            imgui.SameLine()
                            imgui.Text(event.event or "")
                        end
                    end
                    imgui.EndChild()
                    imgui.EndTabItem()
                end
                
                if imgui.BeginTabItem("Notes") then
                    imgui.InputTextMultiline("##call_note", call_note_buffer, ffi.sizeof(call_note_buffer), imgui.new('ImVec2', -1, 80))
                    if imgui.Button("Add Note", imgui.new('ImVec2', 100, 30)) then
                        local note_text = safe_str(call_note_buffer)
                        if note_text ~= "" then
                            addCallLogEntry(call.id, note_text)
                            ffi.copy(call_note_buffer, "")
                        end
                    end
                    imgui.EndTabItem()
                end
                imgui.EndTabBar()
            end

        else

            local center_x = imgui.GetContentRegionAvail().x / 2
            local center_y = imgui.GetContentRegionAvail().y / 2
            imgui.SetCursorPos(imgui.new('ImVec2', center_x - 80, center_y - 20))
            imgui.TextDisabled("Select a call to view details")
        end
    imgui.EndChild()
    imgui.PopStyleColor() -- ChildBg
    end
local session_start_time = os.time()
local session_stats = {
    calls_accepted = 0,
    incidents_joined = 0,
    distance_traveled = 0.0
}

arm_pending_incident_marker_seed = function(reason, ttl_sec)
    pending_incident_marker_seed.active = true
    pending_incident_marker_seed.until_ts = os.clock() + (ttl_sec or 20)
    pending_incident_marker_seed.reason = reason or "unknown"
end

consume_pending_incident_marker_seed = function()
    pending_incident_marker_seed.active = false
    pending_incident_marker_seed.until_ts = 0
    pending_incident_marker_seed.reason = nil
end

local function renderIncidentsTab()
    local main_w = imgui.GetContentRegionAvail().x
    
    imgui.Columns(2, "IncidentsTabCols", false)
    imgui.SetColumnWidth(0, 420)


    imgui.BeginChild("IncidentList", imgui.new('ImVec2', 0, 0), true)
        local incidents_to_display = {}
        if data_storage.incidents then
            for _, inc in ipairs(data_storage.incidents) do
                if inc.status ~= "Resolved" then table.insert(incidents_to_display, inc) end
            end
        end

        imgui.TextDisabled("ACTIVE INCIDENTS (" .. #incidents_to_display .. ")")
        imgui.Separator()

        if #incidents_to_display == 0 then
            imgui.Text("No active incidents.")
        else
            for i, incident in ipairs(incidents_to_display) do
                local is_selected = (selected_incident_index == i)
                

                if drawModernIncidentCard(incident, is_selected) then
                    selected_incident_index = i
                end
                imgui.Dummy(imgui.new('ImVec2', 0, 5))
            end
        end
    imgui.EndChild()

    imgui.NextColumn()


    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.1, 0.1, 0.12, 1.0))
    imgui.BeginChild("IncidentDetails", imgui.new('ImVec2', 0, 0), true)
        if selected_incident_index and incidents_to_display[selected_incident_index] then
            local incident = incidents_to_display[selected_incident_index]
            local width = imgui.GetContentRegionAvail().x


            imgui.BeginGroup()
                imgui.PushFont(fonts[22])
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "INCIDENT #" .. tostring(incident.id))
                imgui.PopFont()
                

                --[[local date_str = incident.created_at or ""
                if date_str ~= "" then
                     date_str = date_str:gsub("T", " "):gsub("%.%d+Z", "")
                     imgui.SameLine(); imgui.TextDisabled(date_str)
                end]]--
                local date_str = ToMSK(incident.created_at)
                if date_str ~= "N/A" then
                     imgui.SameLine() 
                     imgui.TextDisabled(date_str)
                end
            imgui.EndGroup()

            imgui.SameLine()
            

            local status_txt = (incident.status or "Active"):upper()
            local status_w = 140
            imgui.SetCursorPosX(width - status_w)
            
            local st_col = incident_status_colors_hex[incident.status] or incident_status_colors_hex['Default']

            local vec_col = incidentStatusColors[incident.status] or imgui.ImVec4(0.5,0.5,0.5,1)
            
            imgui.PushStyleColor(imgui.Col.Button, vec_col)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, vec_col)
            imgui.PushStyleColor(imgui.Col.ButtonActive, vec_col)
            imgui.Button(status_txt, imgui.new('ImVec2', status_w, 30))
            imgui.PopStyleColor(3)

            imgui.Separator()
            imgui.Dummy(imgui.new('ImVec2', 0, 10))



            local half_w = (width - 10) / 2
            

            if incident.tactical_channel then
                drawInfoCard("Location", incident.location or "Unknown", half_w, fa.ICON_FA_LOCATION_DOT)
                imgui.SameLine()
                drawInfoCard("Radio Freq", "912." .. incident.tactical_channel, half_w, fa.ICON_FA_walkie_talkie or "R") 

            else

                drawInfoCard("Location", incident.location or "Unknown", width, fa.ICON_FA_LOCATION_DOT)
            end
            
            imgui.Dummy(imgui.new('ImVec2', 0, 15))


            imgui.TextDisabled("SITUATION SUMMARY")
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 1.0))
            imgui.BeginChild("IncDescBlock", imgui.new('ImVec2', 0, 80), true)
                imgui.PushFont(fonts[18])
                imgui.TextWrapped(incident.summary or "No summary provided.")
                imgui.PopFont()
            imgui.EndChild()
            imgui.PopStyleColor()

            imgui.Dummy(imgui.new('ImVec2', 0, 10))


            local btn_w = (width - 10) / 3
            local can_accept = incident.status ~= 'Code 4' and incident.status ~= 'Resolved'


            if can_accept then
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.0, 0.45, 0.7, 1.0))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.1, 0.55, 0.8, 1.0))
                if imgui.Button("ACCEPT ASSIST", imgui.new('ImVec2', btn_w, 40)) then
                    send_ws_request('tactical', 'accept_assist', { incident_id = incident.id })
                    
                    if incident.tactical_channel and tonumber(incident.tactical_channel) then
                        setRadioChannel(tonumber(incident.tactical_channel))
                    end

                    optimistic_accept_assist(incident.id)
                    cadui_module.touchIncidentWaypoint(incident.id, 'incident_tab_accept')
                    addUnitLogEntry("INCIDENT", "Accepted assist for #" .. incident.id)
                end
                imgui.PopStyleColor(2)
            else
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, 0.5)
                imgui.Button("CLOSED", imgui.new('ImVec2', btn_w, 40))
                imgui.PopStyleVar()
            end
            imgui.SameLine()


            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.4, 0.0, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.5, 0.1, 1.0))
            if imgui.Button("UPDATE STATUS", imgui.new('ImVec2', btn_w, 40)) then
                imgui.OpenPopup("IncStatusPopup")
            end
            imgui.PopStyleColor(2)


            if imgui.BeginPopup("IncStatusPopup") then
                imgui.TextDisabled("Set Status:")
                for _, st in ipairs(incidentStatusTypes) do
                    if st ~= "Resolved" then
                        if imgui.Selectable(st) then
                            send_ws_request('tactical', 'update_incident_status', { incident_id = incident.id, status = st })
                            optimistic_set_incident_status(incident.id, st)
                            cadui_module.touchIncidentWaypoint(incident.id, 'status_' .. tostring(st))
                        end
                    end
                end
                imgui.EndPopup()
            end
            imgui.SameLine()


            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 0.2, 1.0))
            if imgui.Button("RESOLVE / CODE 4", imgui.new('ImVec2', btn_w, 40)) then
                 send_ws_request('tactical', 'update_incident_status', { incident_id = incident.id, status = 'Resolved' })
                 optimistic_set_incident_status(incident.id, 'Resolved')
                 send_map_request('close_dispatch_marker', { dedupe_key = "dispatch:incident_call:" .. tostring(incident.id) })
                 revertToBaseRadioSlot()
                 selected_incident_index = nil
            end
            imgui.PopStyleColor(1)

            imgui.Dummy(imgui.new('ImVec2', 0, 10))


            local function normalize_units(val)
                if type(val) == "table" then return val end
                if type(val) == "string" then
                    local ok, decoded = pcall(json.decode, val)
                    if ok and type(decoded) == "table" then return decoded end
                    return { val }
                end
                if type(val) == "number" then return { tostring(val) } end
                return {}
            end

            local function normalize_event_log(val)
                if type(val) == "table" then return val end
                if type(val) == "string" then
                    local ok, decoded = pcall(json.decode, val)
                    if ok and type(decoded) == "table" then return decoded end
                end
                return {}
            end

            local assigned_units = normalize_units(incident.assigned_units)
            local event_log = normalize_event_log(incident.event_log)

            imgui.TextDisabled("ASSIGNED UNITS")
            if assigned_units and #assigned_units > 0 then
                for _, u in ipairs(assigned_units) do
                    local unit_label = tostring(u)
                    local is_lspd = unit_label:find("LSPD", 1, true) ~= nil
                    local btn_color = is_lspd and imgui.ImVec4(0.2, 0.5, 0.8, 1.0) or imgui.ImVec4(0.25, 0.25, 0.3, 1.0)
                    local caption = is_lspd and "LSPD" or unit_label
                    imgui.PushStyleColor(imgui.Col.Button, btn_color)
                    imgui.Button(fa.ICON_FA_CAR_SIDE .. " " .. caption)
                    imgui.PopStyleColor()
                    imgui.SameLine()
                end
                imgui.NewLine()
            else
                imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "No units attached.")
            end

            imgui.Dummy(imgui.new('ImVec2', 0, 5))
            imgui.Separator()


            if imgui.BeginTabBar("IncBottomTabs") then
                if imgui.BeginTabItem("Events Log") then
                    imgui.BeginChild("IncLogScroll", imgui.new('ImVec2', 0, 120), true)
                    if event_log and #event_log > 0 then
                        for _, event in ipairs(event_log) do
                            imgui.TextDisabled(event.time or "")
                            imgui.SameLine()
                            imgui.Text(event.event or "")
                        end
                    end
                    imgui.EndChild()
                    imgui.EndTabItem()
                end
                imgui.EndTabBar()
            end

        else

            local center_x = imgui.GetContentRegionAvail().x / 2
            local center_y = imgui.GetContentRegionAvail().y / 2
            imgui.SetCursorPos(imgui.new('ImVec2', center_x - 90, center_y - 20))
            imgui.TextDisabled("Select an incident to view details")
        end
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.Columns(1)
end


local function renderUnitsTab()
    local main_w = imgui.GetContentRegionAvail().x
    
    imgui.Columns(2, "UnitsTabColumns", false)
    imgui.SetColumnWidth(0, 360)


    imgui.BeginChild("UnitListLeft", imgui.new('ImVec2', 0, 0), true)
        imgui.TextDisabled("ACTIVE UNITS (" .. #data_storage.units .. ")")
        imgui.Separator()
        
        if #data_storage.units == 0 then
            imgui.Text("No active units.")
        else
            for i, unit in ipairs(data_storage.units) do
                local is_selected = (selected_unit_index == i)
                if drawModernUnitCard(unit, is_selected) then
                    selected_unit_index = i
                end
                imgui.Dummy(imgui.new('ImVec2', 0, 5))
            end
        end
    imgui.EndChild()

    imgui.NextColumn()


    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.1, 0.1, 0.12, 1.0))
    imgui.BeginChild("UnitDetailsRight", imgui.new('ImVec2', 0, 0), true)
        if selected_unit_index and data_storage.units[selected_unit_index] then
            local unit = data_storage.units[selected_unit_index]
            local width = imgui.GetContentRegionAvail().x


            imgui.BeginGroup()
                imgui.PushFont(fonts[22])
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "UNIT " .. tostring(unit.unitID or "N/A"))
                imgui.PopFont()
                
                local type_idx = unit.unitType or 0
                local type_name = comboBoxData.unitType[type_idx+1] or "Patrol Unit"
                imgui.TextDisabled(type_name)
            imgui.EndGroup()

            imgui.SameLine()


            local status_idx = (tonumber(unit.status) or 4)
            local status_text = comboBoxData.status[status_idx + 1] or "UNKNOWN"
            
            local st_col = imgui.ImVec4(0.5, 0.5, 0.5, 1)
            if status_idx == 0 then st_col = imgui.ImVec4(0.2, 0.8, 0.2, 1) 
            elseif status_idx == 1 then st_col = imgui.ImVec4(0.0, 0.4, 0.8, 1) 
            elseif status_idx == 2 then st_col = imgui.ImVec4(0.0, 0.7, 0.7, 1) 
            elseif status_idx == 3 then st_col = imgui.ImVec4(0.8, 0.3, 0.0, 1) 
            end

            local status_w = 160
            imgui.SetCursorPosX(width - status_w)
            
            imgui.PushStyleColor(imgui.Col.Button, st_col)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, st_col)
            imgui.PushStyleColor(imgui.Col.ButtonActive, st_col)
            imgui.Button(status_text, imgui.new('ImVec2', status_w, 35))
            imgui.PopStyleColor(3)

            imgui.Separator()
            imgui.Dummy(imgui.new('ImVec2', 0, 10))


            local col_w = (width - 15) / 2
            
            local officer1_text = unit.officer1_name or "N/A"
            if unit.officer1_phone and safe_str(unit.officer1_phone) ~= "" then
                officer1_text = officer1_text .. " Tel:" .. safe_str(unit.officer1_phone)
            end
            drawInfoCard("Officer 1", officer1_text, col_w, fa.ICON_FA_USER_SHIELD)
            
            imgui.SameLine()
            
            local officer2_text = "None"
            if unit.officer2_name and safe_str(unit.officer2_name) ~= "" then
                officer2_text = unit.officer2_name
                if unit.officer2_phone and safe_str(unit.officer2_phone) ~= "" then
                    officer2_text = officer2_text .. " Tel:" .. safe_str(unit.officer2_phone)
                end
            end
            drawInfoCard("Officer 2", officer2_text, col_w, fa.ICON_FA_USER_SHIELD)
            
            imgui.Dummy(imgui.new('ImVec2', 0, 5))
            
            local div_idx = tonumber(unit.division) or 0
            local div_name = comboBoxData.division[div_idx + 1] or "N/A"
            drawInfoCard("Division", div_name, col_w, fa.ICON_FA_ID_CARD)
            imgui.SameLine()
            drawInfoCard("Vehicle", unit.vehiclePlate or "No Plate", col_w, fa.ICON_FA_CAR_SIDE)
            
            imgui.Dummy(imgui.new('ImVec2', 0, 5))
            
            local current_slot = tonumber(unit.current_channel_id)
            if (not current_slot or current_slot <= 0) and is_unit_for_current_user(unit) then
                current_slot = tonumber(UI.unit_mini_hud_last_slot)
            end
            local slot_text = (current_slot and current_slot > 0) and ("912." .. tostring(current_slot)) or "N/A"
            drawInfoCard("Radio Slot", slot_text, col_w, fa.ICON_FA_WALKIE_TALKIE)
            
            imgui.Dummy(imgui.new('ImVec2', 0, 5))
            drawInfoCard("Last Location", unit.location or "Unknown", width, fa.ICON_FA_LOCATION_DOT)

            imgui.Dummy(imgui.new('ImVec2', 0, 10))
            imgui.Separator()

            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.TextDisabled("VEHICLE RESOURCES")
            if fonts[18] then imgui.PushFont(fonts[18]) end            
            imgui.Dummy(imgui.new('ImVec2', 0, 3))
            
            local function is_equipped(val)
                return val == 1 or val == true
            end
            local function DrawReadOnlyCheckbox(label, active)
                local icon = active and fa.ICON_FA_CHECK_SQUARE or fa.ICON_FA_SQUARE
                local color = active and imgui.ImVec4(0.2, 0.8, 0.2, 1) or imgui.ImVec4(0.4, 0.4, 0.4, 1)
                
                imgui.PushStyleColor(imgui.Col.Text, color)
                imgui.Text(icon) 
                imgui.PopStyleColor()
                
                imgui.SameLine()
                imgui.SetCursorPosY(imgui.GetCursorPosY()) 
                imgui.Text(label)

            end

            imgui.Columns(2, "VehResInfoList", false)

            DrawReadOnlyCheckbox("AR-15 Rifle",      is_equipped(unit.ar15))
            DrawReadOnlyCheckbox("40mm Less-Lethal", is_equipped(unit.ll40mm))
            DrawReadOnlyCheckbox("Beanbag Shotgun",  is_equipped(unit.beanbag))
            DrawReadOnlyCheckbox("Riot Shield",      is_equipped(unit.riot_shield))

            imgui.NextColumn()

            DrawReadOnlyCheckbox("Spike Strips",     is_equipped(unit.spikes))
            DrawReadOnlyCheckbox("Narcan",           is_equipped(unit.narcan))
            DrawReadOnlyCheckbox("PIT Authorized",   is_equipped(unit.pit_auth))
            DrawReadOnlyCheckbox("AED Onboard",      is_equipped(unit.aed))

            imgui.Columns(1)
            if fonts[18] then imgui.PopFont() end
            imgui.Separator()

            imgui.Dummy(imgui.new('ImVec2', 0, 15))

            local btn_w = (width - 10) / 2
            
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.25, 0.3, 1.0))
            if imgui.Button("SIMPLEX REQ", imgui.new('ImVec2', btn_w, 40)) then
                 log('UI', log_levels.INFO, "Requesting simplex with unit " .. tostring(unit.id))
                 send_ws_request('tactical', 'request_simplex', { target_unit_id = unit.id })
            end
            imgui.SameLine()
            
            if imgui.Button("STATUS CHECK", imgui.new('ImVec2', btn_w, 40)) then
                 addUnitLogEntry("SYSTEM", "Status check sent to " .. tostring(unit.unitID))
            end
            imgui.PopStyleColor()

            imgui.Dummy(imgui.new('ImVec2', 0, 10))
            imgui.Separator()

            local bottom_h = imgui.GetContentRegionAvail().y
            imgui.Columns(2, "UnitBottomSplit", false)
            imgui.SetColumnWidth(0, width * 0.65)

            imgui.BeginChild("BottomLogs", imgui.new('ImVec2', 0, bottom_h), false)
                if imgui.BeginTabBar("UnitHistoryTabs") then
                    
                    if imgui.BeginTabItem("Personal Log") then
                        imgui.BeginChild("PLogScroll", imgui.new('ImVec2', 0, 0), true)
                        local logs_to_show = (safe_str(unitInfoBuffers.unitID) == unit.unitID) and unitActivityLog or (unit.event_log or {})
                        
                        if #logs_to_show == 0 then
                            imgui.TextDisabled("No records available.")
                        else
                            for _, entry in ipairs(logs_to_show) do
                                imgui.TextDisabled(entry.time or "")
                                imgui.SameLine()
                                imgui.TextWrapped((entry.event or "") .. ": " .. (entry.details or ""))
                                imgui.Separator()
                            end
                        end
                        imgui.EndChild()
                        imgui.EndTabItem()
                    end

                    if imgui.BeginTabItem("Incidents") then
                        imgui.BeginChild("IncHistScroll", imgui.new('ImVec2', 0, 0), true)
                        
                        local found_any = false
                        if data_storage.incidents then
                            for _, inc in ipairs(data_storage.incidents) do
                                local is_assigned = false
                                if inc.assigned_units then
                                    for _, u in ipairs(inc.assigned_units) do
                                        if tostring(u) == tostring(unit.unitID) then is_assigned = true; break end
                                    end
                                end
                                
                                if is_assigned then
                                    found_any = true
                                    imgui.TextColored(imgui.ImVec4(0.8, 0.4, 0.0, 1), "#" .. tostring(inc.id))
                                    imgui.SameLine()
                                    imgui.Text(inc.summary or "No Summary")
                                    imgui.TextDisabled(inc.location or "Unknown")
                                    imgui.Separator()
                                end
                            end
                        end
                        
                        if not found_any then
                            imgui.TextDisabled("No active incidents linked.")
                        end
                        
                        imgui.EndChild()
                        imgui.EndTabItem()
                    end

                    imgui.EndTabBar()
                end
            imgui.EndChild()

            imgui.NextColumn()

            imgui.BeginChild("BottomMap", imgui.new('ImVec2', 0, bottom_h), false)
                imgui.TextDisabled("LIVE FEED")
                if unit.pos_x and unit.pos_y then

                    renderUnitMiniMap(unit)
                
                else
                    imgui.Dummy(imgui.new('ImVec2', 0, 0))
                    imgui.TextWrapped("No GPS Signal")
                end
            imgui.EndChild()

            imgui.Columns(1)

        else
            local center_x = imgui.GetContentRegionAvail().x / 2
            local center_y = imgui.GetContentRegionAvail().y / 2
            imgui.SetCursorPos(imgui.new('ImVec2', center_x - 80, center_y - 20))
            imgui.TextDisabled("Select a unit to view details")
        end
    imgui.EndChild()
    imgui.PopStyleColor()
    imgui.Columns(1)
end

local function renderMyInfoTab()  
    local main_w = imgui.GetContentRegionAvail().x
    
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 5.0) 
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 0.0) 
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.20, 0.20, 0.24, 1.0)) 
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.25, 0.25, 0.30, 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0.30, 0.30, 0.35, 1.0))

    imgui.Columns(2, "MyInfoCols", false)
    imgui.SetColumnWidth(0, main_w * 0.6) 

    imgui.BeginChild("MyInfoLeft", imgui.new('ImVec2', 0, 0), true, imgui.WindowFlags.NoScrollbar)
        
        imgui.BeginGroup()
            imgui.PushFont(fonts[22])
            imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "UNIT CONFIGURATION")
            imgui.PopFont()
            imgui.TextDisabled("Manage your unit identity and resources")
        imgui.EndGroup()
        
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 0.6))
        imgui.BeginChild("IdentityBlock", imgui.new('ImVec2', 0, 100), true, imgui.WindowFlags.NoScrollbar)
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 8))
            
            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1), fa.ICON_FA_ID_CARD .. " IDENTITY")
            if fonts[18] then imgui.PopFont() end
            
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 35))
            
            imgui.BeginGroup()
                imgui.TextDisabled("Callsign (Unit ID)")
                imgui.SetNextItemWidth(150)
                if imgui.InputText("##uid", unitInfoBuffers.unitID, ffi.sizeof(unitInfoBuffers.unitID)) then
                    mark_unit_field_dirty("unitID")
                end
            imgui.EndGroup()
            imgui.SameLine()
            imgui.BeginGroup()
                imgui.TextDisabled("Unit Type")
                imgui.SetNextItemWidth(200)
                if imgui.Combo("##utype", unitInfoBuffers.unitType, unitTypeOptions_c, #comboBoxData.unitType) then
                    mark_unit_field_dirty("unitType")
                end
            imgui.EndGroup()
            imgui.SameLine()
            imgui.BeginGroup()
                imgui.TextDisabled("Division")
                imgui.SetNextItemWidth(180)
                if imgui.Combo("##udiv", unitInfoBuffers.division, divisionOptions_c, #comboBoxData.division) then
                    mark_unit_field_dirty("division")
                end
            imgui.EndGroup()
        imgui.EndChild()
        imgui.PopStyleColor()

        imgui.Dummy(imgui.new('ImVec2', 0, 5))

        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 0.6))
        imgui.BeginChild("RadioSlotBlock", imgui.new('ImVec2', 0, 80), true, imgui.WindowFlags.NoScrollbar)
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 8))
            
            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1), fa.ICON_FA_WALKIE_TALKIE .. " RADIO SIMPLEX")
            if fonts[18] then imgui.PopFont() end
            
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 35))
            
            imgui.BeginGroup()
                imgui.TextDisabled("BASE SIMPLEX (912.X)")
                imgui.SetNextItemWidth(100)
                
                if imgui.InputInt("##rslot", unitInfoBuffers.base_radio_slot, 0, 0) then
                    mark_unit_field_dirty("base_radio_slot")
                end
            imgui.EndGroup()
            
            imgui.SameLine()
            
            imgui.BeginGroup()
                imgui.TextDisabled("BASE PATCH")
                if imgui.Button("C-TAC  (30)") then updateLastRadioSlotUsed(30, "ui_preset"); sampSendChat("/slot 30") end
                imgui.SameLine()
                if imgui.Button("A-TAC 1 (10)") then updateLastRadioSlotUsed(10, "ui_preset"); sampSendChat("/slot 10") end
                imgui.SameLine()
                if imgui.Button("L-TAC 6 (20)") then updateLastRadioSlotUsed(20, "ui_preset"); sampSendChat("/slot 20") end
                imgui.SameLine()
                if imgui.Button("EMER 50 (99)") then updateLastRadioSlotUsed(99, "ui_preset"); sampSendChat("/slot 99") end
            imgui.EndGroup()
        imgui.EndChild()
        imgui.PopStyleColor()

        imgui.Dummy(imgui.new('ImVec2', 0, 5))

        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 0.6))
        imgui.BeginChild("CrewBlock", imgui.new('ImVec2', 0, 150), true, imgui.WindowFlags.NoScrollbar)
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 8))
            
            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1), fa.ICON_FA_USER_SHIELD .. " CREW ASSIGNMENT")
            if fonts[18] then imgui.PopFont() end
            
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 35))
            
            imgui.BeginGroup()
                imgui.TextDisabled("Officer #1 Name")
                imgui.SetNextItemWidth(220)
                if imgui.InputText("##off1", unitInfoBuffers.officer1_name, ffi.sizeof(unitInfoBuffers.officer1_name)) then
                    mark_unit_field_dirty("officer1_name")
                end
                imgui.Dummy(imgui.new('ImVec2', 0, 2))
                imgui.TextDisabled("Phone #1")
                imgui.SetNextItemWidth(220)
                if imgui.InputText("##ph1", unitInfoBuffers.officer1_phone, ffi.sizeof(unitInfoBuffers.officer1_phone)) then
                    mark_unit_field_dirty("officer1_phone")
                end
            imgui.EndGroup()

            imgui.SameLine(260)
            
            imgui.BeginGroup()
                imgui.TextDisabled("Officer #2 Name")
                imgui.SetNextItemWidth(220)
                if imgui.InputText("##off2", unitInfoBuffers.officer2_name, ffi.sizeof(unitInfoBuffers.officer2_name)) then
                    mark_unit_field_dirty("officer2_name")
                end
                imgui.Dummy(imgui.new('ImVec2', 0, 2))
                imgui.TextDisabled("Phone #2")
                imgui.SetNextItemWidth(220)
                if imgui.InputText("##ph2", unitInfoBuffers.officer2_phone, ffi.sizeof(unitInfoBuffers.officer2_phone)) then
                    mark_unit_field_dirty("officer2_phone")
                end
            imgui.EndGroup()
        imgui.EndChild()
        imgui.PopStyleColor()

        imgui.Dummy(imgui.new('ImVec2', 0, 5))

        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 0.6))
        imgui.BeginChild("VehBlock", imgui.new('ImVec2', 0, 160), true, imgui.WindowFlags.NoScrollbar)
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 8))
            
            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1), fa.ICON_FA_CAR_SIDE .. " VEHICLE RESOURCE")
            if fonts[18] then imgui.PopFont() end
            
            imgui.SetCursorPos(imgui.new('ImVec2', 10, 35))
            
            imgui.Columns(3, "VehResLayout", false)
            imgui.SetColumnWidth(0, 200) 

            imgui.BeginGroup()
                imgui.TextDisabled("License Plate")
                imgui.SetNextItemWidth(170)
                if imgui.InputText("##plate", unitInfoBuffers.vehiclePlate, ffi.sizeof(unitInfoBuffers.vehiclePlate)) then
                    mark_unit_field_dirty("vehiclePlate")
                end
                imgui.Dummy(imgui.new('ImVec2', 0, 10))
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.4, 0.0, 1.0)) 
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.5, 0.1, 1.0))
                imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.7, 0.3, 0.0, 1.0))
                --[[if imgui.Button("GET FROM CAR", imgui.new('ImVec2', 170, 35)) then
                     local ped = PLAYER_PED
                     if isCharInAnyCar(ped) then
                        local car = storeCarCharIsInNoSave(ped)
                        local ok, vehId = sampGetVehicleIdByCarHandle(car)
                        if ok then
                            assigned_vehicle_id = vehId
                            local plate = getplate(vehId)
                            if plate then 
                                ffi.copy(unitInfoBuffers.vehiclePlate, plate:gsub("[%z%s]", ""):upper()) 
                                if core.current_unit then core.fetchUnitLogs(core.current_unit.id, 'profile') end
                            end
                        end
                     end
                end]]
                if imgui.Button("GET FROM CAR", imgui.new('ImVec2', 170, 35)) then
                    local ped = PLAYER_PED
                    if isCharInAnyCar(ped) then
                        local car_handle = storeCarCharIsInNoSave(ped)
                        local result, vehId = sampGetVehicleIdByCarHandle(car_handle)

                        if result then
                            local real_plate = getplate(vehId)
                            
                            if real_plate then
                                assigned_vehicle_id = vehId
                                
                                local current_div_idx = unitInfoBuffers.division[0]
                                local div_name = comboBoxData.division[current_div_idx + 1] or "00"
                                local prefix = get_division_prefix(div_name)
                                
                                local visual_callsign = string.format("SH%s%03d", prefix, vehId)
                                
                                local clean_system_plate = real_plate:gsub("[%z%s]", ""):upper()

                                sampSendChat("/dsign " .. tostring(vehId))
                                sampSendChat("/callsign " .. visual_callsign)

                                ffi.copy(unitInfoBuffers.vehiclePlate, visual_callsign)
                                
                                if core.system_override_plate ~= nil then 
                                    core.system_override_plate = clean_system_plate
                                else
                                end
                                
                                --[[if core.current_unit then 
                                    core.fetchUnitLogs(core.current_unit.id, 'profile') 
                                end]]
                            end
                        else
                            sampAddChatMessage("CAD: Ошибка ID транспорта.", 0xFF0000)
                        end
                    end
                end
                imgui.PopStyleColor(3)
            imgui.EndGroup()

        imgui.NextColumn()

            imgui.BeginGroup()

                if imgui.Checkbox("AR-15 Rifle", vehicleEquipment.ar15) then
                    if core.current_unit then core.current_unit.ar15 = vehicleEquipment.ar15[0] end
                    broadcastUnitStatus()
                end


                if imgui.Checkbox("40mm Less-Lethal", vehicleEquipment.ll40mm) then
                    if core.current_unit then core.current_unit.ll40mm = vehicleEquipment.ll40mm[0] end
                    broadcastUnitStatus()
                end


                if imgui.Checkbox("Beanbag Shotgun", vehicleEquipment.beanbag) then
                    if core.current_unit then core.current_unit.beanbag = vehicleEquipment.beanbag[0] end
                    broadcastUnitStatus()
                end


                if imgui.Checkbox("Riot Shield", vehicleEquipment.riot_shield) then
                    if core.current_unit then core.current_unit.riot_shield = vehicleEquipment.riot_shield[0] end
                    broadcastUnitStatus()
                end
            imgui.EndGroup()

            imgui.NextColumn()
            
            imgui.BeginGroup()

                if imgui.Checkbox("Spike Strips", vehicleEquipment.spikes) then
                    if core.current_unit then core.current_unit.spikes = vehicleEquipment.spikes[0] end
                    broadcastUnitStatus()
                end


                if imgui.Checkbox("Narcan", vehicleEquipment.narcan) then
                    if core.current_unit then core.current_unit.narcan = vehicleEquipment.narcan[0] end
                    broadcastUnitStatus()
                end


                if imgui.Checkbox("PIT Authorized", vehicleEquipment.pit_auth) then
                    if core.current_unit then core.current_unit.pit_auth = vehicleEquipment.pit_auth[0] end
                    broadcastUnitStatus()
                end


                if imgui.Checkbox("AED Onboard", vehicleEquipment.aed) then
                    if core.current_unit then core.current_unit.aed = vehicleEquipment.aed[0] end
                    broadcastUnitStatus()
                end
            imgui.EndGroup()
            
            imgui.Columns(1)

        imgui.EndChild()
        imgui.PopStyleColor()

        --[[imgui.Dummy(imgui.new('ImVec2', 0, 5))
        
        imgui.TextDisabled("UNIT NOTES / SHIFT INFO")
        imgui.Columns(2, "NotesShiftSplit", false)
        imgui.SetColumnWidth(0, main_w * 0.4)
        
        imgui.Combo("##shift", unitInfoBuffers.shift, shiftOptions_c, #comboBoxData.shift)
        imgui.NextColumn()
        imgui.SetNextItemWidth(-1)
        imgui.InputText("##UnitNotes", unitInfoBuffers.notes, ffi.sizeof(unitInfoBuffers.notes))
        imgui.Columns(1)]]

        imgui.Dummy(imgui.new('ImVec2', 0, 15))
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.0, 0.6, 0.35, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.0, 0.7, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.0, 0.5, 0.3, 1.0))
        --[[if imgui.Button("UPDATE STATUS & SAVE CONFIGURATION", imgui.new('ImVec2', -1, 45)) then
            broadcastUnitStatus()
            
            local equip_data = {
                ar15 = vehicleEquipment.ar15[0],
                ll40mm = vehicleEquipment.ll40mm[0],
                beanbag = vehicleEquipment.beanbag[0],
                riot = vehicleEquipment.riot_shield[0],
                spikes = vehicleEquipment.spikes[0],
                narcan = vehicleEquipment.narcan[0],
                pit = vehicleEquipment.pit_auth[0],
                aed = vehicleEquipment.aed[0]
            }

            local unit_data_to_save = {
                unitID = safe_str(unitInfoBuffers.unitID),
                unitType = unitInfoBuffers.unitType[0],
                officer1_name = safe_str(unitInfoBuffers.officer1_name),
                officer1_phone = safe_str(unitInfoBuffers.officer1_phone),
                officer2_name = safe_str(unitInfoBuffers.officer2_name),
                officer2_phone = safe_str(unitInfoBuffers.officer2_phone),
                status = unitInfoBuffers.status[0],
                vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
                division = unitInfoBuffers.division[0],
                shift = unitInfoBuffers.shift[0],
                notes = safe_str(unitInfoBuffers.notes),
                equipment = equip_data,
                assigned_vehicle_id = assigned_vehicle_id
            }
            settings.saveUnitInfo(unit_data_to_save)
            settings.save()
            updateRadioParserSign(unit_data_to_save.unitID)
            
            if core.current_unit then 
                core.fetchUnitLogs(core.current_unit.id, 'profile') 
            end
        end]]
    --[[if imgui.Button("UPDATE STATUS & SAVE CONFIGURATION", imgui.new('ImVec2', -1, 45)) then
            broadcastUnitStatus()
            
            
            local payload = {
                id = core.current_unit and core.current_unit.id or 0, 
                
                vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
                notes = safe_str(unitInfoBuffers.notes),
                division = unitInfoBuffers.division[0],
                
                ar15 = vehicleEquipment.ar15[0],
                ll40mm = vehicleEquipment.ll40mm[0],
                beanbag = vehicleEquipment.beanbag[0],
                riot_shield = vehicleEquipment.riot_shield[0],
                spikes = vehicleEquipment.spikes[0],
                narcan = vehicleEquipment.narcan[0],
                pit_auth = vehicleEquipment.pit_auth[0],
                aed = vehicleEquipment.aed[0]
            }

            cad_websocket.send({
                type = 'unit',
                action = 'update_unit_details',
                token = core.getToken(),
                payload = payload
            })

            local unit_data_to_save_local = {
                unitID = safe_str(unitInfoBuffers.unitID),
                unitType = unitInfoBuffers.unitType[0],
                officer1_name = safe_str(unitInfoBuffers.officer1_name),
                officer1_phone = safe_str(unitInfoBuffers.officer1_phone),
                officer2_name = safe_str(unitInfoBuffers.officer2_name),
                officer2_phone = safe_str(unitInfoBuffers.officer2_phone),
                status = unitInfoBuffers.status[0],
                vehiclePlate = payload.vehiclePlate,
                division = payload.division,
                shift = unitInfoBuffers.shift[0],
                notes = payload.notes,
                equipment = {
                    ar15 = payload.ar15,
                    ll40mm = payload.ll40mm,
                    beanbag = payload.beanbag,
                    riot = payload.riot_shield, 
                    spikes = payload.spikes,
                    narcan = payload.narcan,
                    pit = payload.pit_auth,
                    aed = payload.aed
                },
                assigned_vehicle_id = assigned_vehicle_id
            }
            
            settings.saveUnitInfo(unit_data_to_save_local)
            settings.save()
            updateRadioParserSign(unit_data_to_save_local.unitID)
            clear_unit_dirty_fields()
            
            if core.current_unit then 
                core.fetchUnitLogs(core.current_unit.id, 'profile') 
            end
        end]]
        local btn_text = "UPDATE STATUS & SAVE CONFIGURATION"
        if not core.current_unit then
            btn_text = "GO ON DUTY (CREATE UNIT)"
        end

        if imgui.Button(btn_text, imgui.new('ImVec2', -1, 45)) then
            
            local payload = {
                unitID = safe_str(unitInfoBuffers.unitID),
                unitType = unitInfoBuffers.unitType[0],
                vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
                notes = safe_str(unitInfoBuffers.notes),
                division = unitInfoBuffers.division[0],
                base_radio_slot = unitInfoBuffers.base_radio_slot[0],
                officer1_name = safe_str(unitInfoBuffers.officer1_name),
                officer1_phone = safe_str(unitInfoBuffers.officer1_phone),
                officer2_name = safe_str(unitInfoBuffers.officer2_name),
                officer2_phone = safe_str(unitInfoBuffers.officer2_phone),
                
                ar15 = vehicleEquipment.ar15[0],
                ll40mm = vehicleEquipment.ll40mm[0],
                beanbag = vehicleEquipment.beanbag[0],
                riot_shield = vehicleEquipment.riot_shield[0],
                spikes = vehicleEquipment.spikes[0],
                narcan = vehicleEquipment.narcan[0],
                pit_auth = vehicleEquipment.pit_auth[0],
                aed = vehicleEquipment.aed[0]
            }

            if core.current_unit then
                broadcastUnitStatus() 
                payload.id = core.current_unit.id

                cad_websocket.send({
                    type = 'unit',
                    action = 'update_unit_details',
                    token = core.getToken(),
                    payload = payload
                })
            else
                payload.unitID = safe_str(unitInfoBuffers.unitID) 
                payload.unitType = unitInfoBuffers.unitType[0]
                
                cad_websocket.send({
                    type = 'unit',
                    action = 'form_or_update_crew',
                    token = core.getToken(),
                    payload = payload
                })
                log('UI', log_levels.INFO, "Sent request to create new unit.")
            end

            local unit_data_to_save_local = {
                unitID = safe_str(unitInfoBuffers.unitID),
                unitType = unitInfoBuffers.unitType[0],
                officer1_name = safe_str(unitInfoBuffers.officer1_name),
                officer1_phone = safe_str(unitInfoBuffers.officer1_phone),
                officer2_name = safe_str(unitInfoBuffers.officer2_name),
                officer2_phone = safe_str(unitInfoBuffers.officer2_phone),
                status = unitInfoBuffers.status[0],
                vehiclePlate = payload.vehiclePlate,
                division = payload.division,
                base_radio_slot = unitInfoBuffers.base_radio_slot[0],
                shift = unitInfoBuffers.shift[0],
                notes = payload.notes,
                equipment = { 
                    ar15 = payload.ar15,
                    ll40mm = payload.ll40mm,
                    beanbag = payload.beanbag,
                    riot = payload.riot_shield, 
                    spikes = payload.spikes,
                    narcan = payload.narcan,
                    pit = payload.pit_auth,
                    aed = payload.aed
                },
                assigned_vehicle_id = assigned_vehicle_id
            }
            
            settings.saveUnitInfo(unit_data_to_save_local)
            settings.save()
            updateRadioParserSign(unit_data_to_save_local.unitID)
            
            --[[if core.current_unit then 
                core.fetchUnitLogs(core.current_unit.id, 'profile') 
            end]]

        end
        if imgui.Button("DEASSIGN / LEAVE UNIT", imgui.new('ImVec2', -1, 30)) then
            if core.current_unit then
                cad_websocket.send({
                    type = 'unit',
                    action = 'leave_unit',
                    token = core.getToken(),
                    payload = {
                        unit_id = core.current_unit.id
                    }
                })
            end
            
            safe_copy(unitInfoBuffers.officer2_name, "")
            safe_copy(unitInfoBuffers.officer2_phone, "")
            if core.current_user and core.current_user.full_name then
                safe_copy(unitInfoBuffers.officer1_name, core.current_user.full_name)
            end
            clear_unit_dirty_fields()
        end
        imgui.PopStyleColor(3)

    imgui.EndChild()

    imgui.NextColumn()

    local right_w = imgui.GetColumnWidth() - 10
    
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.12, 0.12, 0.14, 1.0))
    imgui.BeginChild("StatsBlock", imgui.new('ImVec2', 0, 135), true, imgui.WindowFlags.NoScrollbar) 
        
        local current_time = os.time()
        if not session_start_time then session_start_time = os.time() end
        
        local abas_stats = core.abas_data or { score = 1.00, today_time = 0, today_calls = 0 }
        
        imgui.SetCursorPos(imgui.new('ImVec2', 10, 5))
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), "PERFORMANCE RATING (ABAS)")
        
        imgui.SetCursorPos(imgui.new('ImVec2', 10, 22))
        imgui.PushFont(fonts[22])
        
        local score_val = abas_stats.score or 1.0
        local score_color = imgui.ImVec4(1, 1, 1, 1)
        if score_val < 0.85 then score_color = imgui.ImVec4(1.0, 0.3, 0.3, 1)
        elseif score_val > 1.15 then score_color = imgui.ImVec4(0.3, 1.0, 0.3, 1)
        end
        
        imgui.TextColored(score_color, string.format("%.2f", score_val))
        imgui.PopFont()
        
        imgui.SameLine()
        imgui.SetCursorPosY(25)
        imgui.TextDisabled("(Weekly Avg)")

        imgui.Separator()
        
        local duration_local = os.difftime(current_time, session_start_time)
        local total_seconds = (abas_stats.today_time or 0) + duration_local
        
        local hours = math.floor(total_seconds / 3600)
        local mins = math.floor((total_seconds % 3600) / 60)
        local time_str = string.format("%02dh %02dm", hours, mins)

        local cell_w = (right_w - 20) / 2
        
        imgui.SetCursorPos(imgui.new('ImVec2', 10, 55))
        imgui.BeginGroup()
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "TIME ON DUTY")
            if fonts[18] then imgui.PushFont(fonts[18]) end
            imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), time_str)
            if fonts[18] then imgui.PopFont() end
        imgui.EndGroup()
        
        imgui.SameLine(cell_w + 10)
        
        imgui.BeginGroup()
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "CALLS RESPONDED")
            if fonts[18] then imgui.PushFont(fonts[18]) end
            local calls_count = abas_stats.today_calls or 0
            if (core.session_calls_count or 0) > calls_count then calls_count = core.session_calls_count end
            
            imgui.TextColored(imgui.ImVec4(0.4, 0.8, 1.0, 1), tostring(calls_count))
            if fonts[18] then imgui.PopFont() end
        imgui.EndGroup()
        
        imgui.SetCursorPos(imgui.new('ImVec2', 10, 95))
        imgui.BeginGroup()
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1), "SHIFT START")
            imgui.PushFont(fonts[18])
            
            -- imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), os.date("%H:%M", session_start_time))
            
            local start_str = "--:--"
            if core.abas_data and core.abas_data.shift_start then
                start_str = core.abas_data.shift_start
            elseif session_start_time then
                start_str = os.date("%H:%M", session_start_time)
            end
            
            imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), start_str)
            
            imgui.PopFont()
        imgui.EndGroup()

    imgui.EndChild()
    imgui.PopStyleColor() 

    imgui.Dummy(imgui.new('ImVec2', 0, 5))

    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.05, 0.05, 0.05, 1.0)) 
    local remaining_h = imgui.GetContentRegionAvail().y
    imgui.BeginChild("MyActivityLogRight", imgui.new('ImVec2', 0, remaining_h), true)
        imgui.SetCursorPos(imgui.new('ImVec2', 10, 10))
        imgui.TextDisabled("SESSION ACTIVITY LOG")
        
        imgui.SameLine()
        local avail_w = imgui.GetContentRegionAvail().x
        imgui.SetCursorPosX(imgui.GetCursorPosX() + avail_w - 30)
        if imgui.Button(fa.ICON_FA_GEARS .. "##refreshlogs") then
            --[[if core.current_unit then
                 core.fetchUnitLogs(core.current_unit.id, 'profile')
             end]]
        end

        imgui.Separator()
        
        local logs_source = core.session_logs or {}
        
        if #logs_source == 0 then
            imgui.TextColored(imgui.ImVec4(0.5,0.5,0.5,1), "(In dev. system off)No activity recorded yet.")
        else
            for _, entry in ipairs(logs_source) do 
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.6, 0.6, 0.6, 1))
                
                --[[local time_display = entry.timestamp
                if type(time_display) == 'string' and #time_display > 16 then
                     time_display = time_display:sub(12, 16)
                end
                
                imgui.Text(time_display or "??:??")
                imgui.PopStyleColor()
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.2, 0.8, 0.2, 1), ">") 
                imgui.SameLine()]]--
                local full_date_msk = ToMSK(entry.timestamp)
                local time_display = "??:??"

                if full_date_msk ~= "N/A" then
                     time_display = full_date_msk:sub(12, 16)
                end

                imgui.Text(time_display)
                imgui.PopStyleColor()
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.2, 0.8, 0.2, 1), ">") 
                imgui.SameLine()
                
                local action = entry.action_type or "EVENT"
                local details = entry.details or ""
                imgui.TextWrapped(action .. ": " .. details)
                
                local p = imgui.GetCursorScreenPos()
                imgui.GetWindowDrawList():AddLine(p, imgui.new('ImVec2', p.x + 300, p.y), 0xFF252525, 1.0)
                imgui.Dummy(imgui.new('ImVec2', 0, 2))
            end
        end
        
        if imgui.GetScrollY() >= imgui.GetScrollMaxY() then
            imgui.SetScrollHereY(1.0)
        end
    imgui.EndChild()
    imgui.PopStyleColor()

    imgui.Columns(1)
    
    imgui.PopStyleColor(3) 
    imgui.PopStyleVar(2)   
end

local function renderSettingsTab()
    local main_w = imgui.GetContentRegionAvail().x
    local avail_h = imgui.GetContentRegionAvail().y
    
    imgui.Columns(2, "SettingsCols", false)
    imgui.SetColumnWidth(0, main_w * 0.65) 

    imgui.BeginChild("SettingsLeft", imgui.new('ImVec2', 0, 0), true)
        
        if fonts[22] then imgui.PushFont(fonts[22]) end
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), fa.ICON_FA_GEARS .. " SYSTEM CONFIGURATION")
        if fonts[22] then imgui.PopFont() end
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        local btn_w = (imgui.GetContentRegionAvail().x - 10) / 2
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.20, 0.20, 0.22, 1.0))
        if imgui.Button(fa.ICON_FA_TABLE_LIST .. " DEBUG LOG", imgui.new('ImVec2', btn_w, 40)) then
            sampProcessChatInput("/caddiag")
        end
        if imgui.IsItemHovered() then imgui.SetTooltip("View technical logs & errors") end
        
        imgui.SameLine()
        
        if imgui.Button(fa.ICON_FA_GEARS .. " FORCE RECONNECT", imgui.new('ImVec2', btn_w, 40)) then
            if cad_websocket then
                if cad_websocket.is_connected and cad_websocket.is_connected() then
                    if cad_websocket.disconnect then 
                        cad_websocket.disconnect() 
                    end
                end

                if cad_websocket.connect then
                    cad_websocket.connect()
                    addUnitLogEntry("SYSTEM", "Manual reconnection initiated.")
                    sampAddChatMessage("CAD: {FFFF00}Reconnecting...", -1)
                else
                    addUnitLogEntry("SYSTEM", "Error: connect() method not found.")
                end
            end
        end
        imgui.PopStyleColor()

        imgui.Dummy(imgui.new('ImVec2', 0, 20))

        imgui.TextDisabled("INTERFACE & BEHAVIOR")
        imgui.Dummy(imgui.new('ImVec2', 0, 5))
        imgui.Columns(2, "CheckboxesCols", false)
        
        local show_notif = imgui.new.bool(settings.get('ui_settings', 'show_notifications', true))
        if drawStyledCheckbox("911 в чат", show_notif) then
            settings.set('ui_settings', 'show_notifications', show_notif[0])
            settings.save()
        end
        
        local alpr_sound = imgui.new.bool(settings.get('audio_settings', 'notification_sounds', true))
        if drawStyledCheckbox("ALPR Sound", alpr_sound) then
            settings.set('audio_settings', 'notification_sounds', alpr_sound[0])
            settings.save()
        end

        local alpr_auto_passive = imgui.new.bool(alpr_passive_scan_enabled)
        if drawStyledCheckbox("Auto ALPR (passive)", alpr_auto_passive) then
            alpr_passive_scan_enabled = alpr_auto_passive[0]
            settings.set('alpr_settings', 'passive_scan', alpr_passive_scan_enabled)
            settings.save()
            if not alpr_passive_scan_enabled then
                alpr_passive_hud_until = 0
            end
        end

        imgui.NextColumn()
        

        local hide_calls = imgui.new.bool(settings.get('ui_settings', 'hide_placeholder_calls', false))
        if drawStyledCheckbox("Скрывать Происходит что-то неладное.", hide_calls) then
            settings.set('ui_settings', 'hide_placeholder_calls', hide_calls[0])
            settings.save()
        end
        
        local disable_auto_sign = imgui.new.bool(settings.get('radio_settings', 'disableAutoSign', false))
        if drawStyledCheckbox("Выкл. маркировка в чат.", disable_auto_sign) then
            settings.set('radio_settings', 'disableAutoSign', disable_auto_sign[0])
            settings.save()
        end

        local mini_hud_enabled = imgui.new.bool(settings.get('ui_settings', 'unit_mini_hud', true))
        if drawStyledCheckbox("Mini HUD (unit)", mini_hud_enabled) then
            UI.unit_mini_hud[0] = mini_hud_enabled[0]
            settings.set('ui_settings', 'unit_mini_hud', mini_hud_enabled[0])
            settings.save()
        end
        if UI.unit_mini_hud[0] then
            imgui.TextDisabled("Drag Mini HUD with mouse while MDT window is open.")
        end

        imgui.Columns(1) 
        imgui.Dummy(imgui.new('ImVec2', 0, 15))

        imgui.TextDisabled("HOTKEYS")
        imgui.Dummy(imgui.new('ImVec2', 0, 5))
        imgui.Columns(3, "BindsCols", false)
        
        for i, bind in ipairs(BinderManager.binds) do
            if bind.is_system then
                imgui.BeginGroup()
                    imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), bind.title)
                    local btn_txt = BinderManager.keysToString(bind.keys)
                    local txt_col = imgui.ImVec4(1,1,1,1)
                    
                    if BinderManager.is_binding_key and BinderManager.current_bind_index == i then
                        btn_txt = "PRESS KEY..."
                        txt_col = imgui.ImVec4(1, 0.8, 0, 1)
                    end
                    
                    imgui.PushStyleColor(imgui.Col.Text, txt_col)
                    if imgui.Button(btn_txt .. "##bind_"..i, imgui.new('ImVec2', -1, 30)) then
                        if BinderManager.is_binding_key and BinderManager.current_bind_index == i then
                            BinderManager.is_binding_key = false; BinderManager.current_bind_index = nil
                        else
                            BinderManager.is_binding_key = true; BinderManager.current_bind_index = i
                        end
                    end
                    imgui.PopStyleColor()
                imgui.EndGroup()
                imgui.NextColumn()
            end
        end
        imgui.Columns(1)

        imgui.Dummy(imgui.new('ImVec2', 0, 20))
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 10))

        imgui.BeginGroup()
            if fonts[22] then imgui.PushFont(fonts[22]) end
            imgui.TextColored(imgui.ImVec4(0.4, 0.8, 1.0, 1), fa.ICON_FA_WALKIE_TALKIE .. " RADIO SUBSCRIPTIONS")
            if fonts[22] then imgui.PopFont() end
            imgui.TextDisabled("Toggle channels you want to monitor")
            
            imgui.Dummy(imgui.new('ImVec2', 0, 10))
            
            imgui.Columns(3, "RadioGrid", false)
            imgui.SetColumnWidth(0, 180) -- NAME
            imgui.SetColumnWidth(1, 100) -- FREQ
            imgui.SetColumnWidth(2, 100)  -- LISTEN
            
            imgui.TextDisabled("CHANNEL NAME")
            imgui.NextColumn()
            imgui.TextDisabled("FREQ")
            imgui.NextColumn()
            imgui.TextDisabled("LISTEN")
            imgui.NextColumn()
            
            imgui.Separator()
            
            for i, channel in ipairs(fixed_radio_channels) do
                imgui.PushIDInt(i)
                imgui.AlignTextToFramePadding()
                imgui.TextDisabled(channel.name)
                imgui.NextColumn()
                
                imgui.AlignTextToFramePadding()
                imgui.TextDisabled(channel.freq)
                imgui.NextColumn()
                
                local ptr_bool = imgui.new.bool(radio_subscription_state[i] or false)
                if drawStyledCheckbox("" .. channel.id, ptr_bool) then
                    local new_state = ptr_bool[0]
                    radio_subscription_state[i] = new_state
                        
                    events.trigger('radio:ui_set_channel', {
                        channel_id = channel.id,
                        state = new_state
                    })
                end
                imgui.NextColumn()
                imgui.Separator()
                
                imgui.PopID()
            end
            imgui.Columns(1)
            
        imgui.EndGroup()

    imgui.EndChild()

    imgui.NextColumn()

    imgui.BeginChild("SettingsRight", imgui.new('ImVec2', 0, 0), true)
        
        local content_w = imgui.GetContentRegionAvail().x 

        if fonts[22] then imgui.PushFont(fonts[22]) end
        imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), fa.ICON_FA_USER_SHIELD .. " ACCOUNT SETTINGS")
        if fonts[22] then imgui.PopFont() end
        imgui.Separator()
        imgui.Dummy(imgui.new('ImVec2', 0, 15))

        imgui.TextDisabled("SECURITY / PASSWORD")
        
        drawStyledInput("OLD PASSWORD", passwordChangeBuffers.old_password, ffi.sizeof(passwordChangeBuffers.old_password), content_w, imgui.InputTextFlags.Password, nil)
        drawStyledInput("NEW PASSWORD", passwordChangeBuffers.new_password, ffi.sizeof(passwordChangeBuffers.new_password), content_w, imgui.InputTextFlags.Password, nil)
        drawStyledInput("CONFIRM NEW", passwordChangeBuffers.confirm_password, ffi.sizeof(passwordChangeBuffers.confirm_password), content_w, imgui.InputTextFlags.Password, nil)

        if passwordChangeBuffers.status_message ~= "" then
            local col = passwordChangeBuffers.is_error and imgui.ImVec4(1, 0.3, 0.3, 1) or imgui.ImVec4(0.2, 0.8, 0.2, 1)
            imgui.PushTextWrapPos(content_w)
            imgui.TextColored(col, passwordChangeBuffers.status_message)
            imgui.PopTextWrapPos()
        end

        imgui.Dummy(imgui.new('ImVec2', 0, 5))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.4, 0.0, 1.0))
        if imgui.Button("CHANGE PASSWORD", imgui.new('ImVec2', content_w, 40)) then
            requestPasswordChange()
        end
        imgui.PopStyleColor()

        imgui.Dummy(imgui.new('ImVec2', 0, 20))
        imgui.TextDisabled("PERSONAL / FULL NAME")
        imgui.Dummy(imgui.new('ImVec2', 0, 5))

        drawStyledInput("FIRST NAME", fullNameChangeBuffers.first_name, ffi.sizeof(fullNameChangeBuffers.first_name), content_w, 0, nil)
        drawStyledInput("LAST NAME", fullNameChangeBuffers.last_name, ffi.sizeof(fullNameChangeBuffers.last_name), content_w, 0, nil)

        if fullNameChangeBuffers.status_message ~= "" then
            local col = fullNameChangeBuffers.is_error and imgui.ImVec4(1, 0.3, 0.3, 1) or imgui.ImVec4(0.2, 0.8, 0.2, 1)
            imgui.PushTextWrapPos(content_w)
            imgui.TextColored(col, fullNameChangeBuffers.status_message)
            imgui.PopTextWrapPos()
        end

        imgui.Dummy(imgui.new('ImVec2', 0, 5))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.55, 0.2, 1.0))
        if imgui.Button("CHANGE NAME", imgui.new('ImVec2', content_w, 40)) then
            requestFullNameChange()
        end
        imgui.PopStyleColor()

        local avail_h_right = imgui.GetContentRegionAvail().y
        if avail_h_right > 50 then
            imgui.SetCursorPosY(imgui.GetCursorPosY() + avail_h_right - 45)
        else
            imgui.Dummy(imgui.new('ImVec2', 0, 20))
        end
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.6, 0.1, 0.1, 0.6))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.8, 0.1, 0.1, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.5, 0.0, 0.0, 1.0))
        
        if imgui.Button(fa.ICON_FA_RIGHT_FROM_BRACKET .. " LOGOUT SESSION", imgui.new('ImVec2', content_w, 40)) then
             core.logout()
             UI.login_window[0] = true
             UI.mdt[0] = false
        end
        imgui.PopStyleColor(3)

    imgui.EndChild()

    imgui.Columns(1)
end


function renderMDTWindow()
    if not core.isAuthenticated() then
        if not UI.login_window[0] then UI.login_window[0] = true end
        return
    end

    UI.login_window[0] = false
    updateCurrentLocation()

    local sizeX, sizeY = getScreenResolution()    
    imgui.SetNextWindowPos(imgui.new('ImVec2', sizeX / 2, sizeY / 2), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1400, 850), imgui.Cond.FirstUseEver)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8.0)
    
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.08, 0.08, 0.10, 0.98))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.12, 0.12, 0.14, 1.0))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.25, 1.0)) 
    
    local function drawStatusBtn(label, color_base, width, height, is_active)
        local draw_list = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local rounding = 4.0
        local col_bg, col_text, col_border = 0x00000000, color_base, color_base
        
        if is_active then
            col_bg = color_base
            col_text = imgui.ImVec4(1, 1, 1, 1) 
            col_border = color_base
        elseif imgui.IsMouseHoveringRect(p, imgui.new('ImVec2', p.x + width, p.y + height)) then
            col_bg = imgui.ImVec4(color_base.x, color_base.y, color_base.z, 0.2)
        end

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
        local clicked = imgui.Button("##st_"..label, imgui.new('ImVec2', width, height))
        imgui.PopStyleColor(3)

        if is_active or imgui.IsItemHovered() then
            draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), imgui.GetColorU32Vec4(col_bg), rounding)
        end
        local border_u32 = imgui.GetColorU32Vec4(col_border)
        draw_list:AddRect(p, imgui.new('ImVec2', p.x + width, p.y + height), border_u32, rounding, 15, 1.5)

        local text_size = imgui.CalcTextSize(label)
        local text_pos = imgui.new('ImVec2', p.x + (width - text_size.x) / 2, p.y + (height - text_size.y) / 2)
        if fonts[18] then imgui.PushFont(fonts[18]) end
        draw_list:AddText(text_pos, imgui.GetColorU32Vec4(col_text), label)
        if fonts[18] then imgui.PopFont() end
        return clicked
    end

    local function drawMiniListCard(id_str, title, subtitle, color_u32)
        local draw_list = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local width = imgui.GetContentRegionAvail().x
        local height = 42
        local rounding = 4.0
        local bg_col = imgui.IsMouseHoveringRect(p, imgui.new('ImVec2', p.x + width, p.y + height)) and 0xFF2A3038 or 0xFF1E2228
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
        local clicked = imgui.Button("##mini_"..id_str, imgui.new('ImVec2', width, height))
        imgui.PopStyleColor(3)

        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), bg_col, rounding)
        draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + 3, p.y + height), color_u32, rounding, 1+8) 

        local text_x = p.x + 10
        local header_text = string.format("#%s %s", id_str, title)
        if #header_text > 32 then header_text = header_text:sub(1, 29).."..." end
        
        if fonts[18] then imgui.PushFont(fonts[18]) end
        draw_list:AddText(imgui.new('ImVec2', text_x, p.y + 4), 0xFFFFFFFF, header_text)
        if fonts[18] then imgui.PopFont() end
        
        if #subtitle > 45 then subtitle = subtitle:sub(1, 42).."..." end
        draw_list:AddText(imgui.new('ImVec2', text_x, p.y + 22), 0xFFAAAAAA, subtitle)
        return clicked
    end

    if imgui.Begin("CAD_System_Main", UI.mdt, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse) then
        
        local win_w = imgui.GetContentRegionAvail().x
        local win_h = imgui.GetContentRegionAvail().y
        
        local header_height = 80
        local top_bar_height = 50
        local left_sidebar_width = 250
        local right_sidebar_width = 120
        local center_width = win_w - left_sidebar_width - right_sidebar_width
        local main_spacing_y = imgui.GetStyle().ItemSpacing.y
        local content_height = win_h - header_height - top_bar_height - (main_spacing_y * 2)

        imgui.BeginChild("TopHeader", imgui.new('ImVec2', win_w, header_height), false)
            local draw_list = imgui.GetWindowDrawList()
            local p = imgui.GetCursorScreenPos()
            
            draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + win_w, p.y + header_height), 0xFF151515, 8.0, 1+2)
            draw_list:AddLine(imgui.new('ImVec2', p.x, p.y + header_height), imgui.new('ImVec2', p.x + win_w, p.y + header_height), 0xFF303030, 1.0)

            imgui.SetCursorPos(imgui.new('ImVec2', 20, 25))
            imgui.PushFont(fonts[22])
            imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "Computer-Aided Dispatch")
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(1, 0.6, 0, 1), "System")
            imgui.PopFont()

            local nav_block_width = #nav_tabs * 145
            imgui.SetCursorPos(imgui.new('ImVec2', (win_w - nav_block_width) / 2, 17))
            for _, tab in ipairs(nav_tabs) do
                if renderNavButton(tab.icon, tab.label, tab.id, current_mdt_tab) then
                    current_mdt_tab = tab.id
                end
                imgui.SameLine()
            end

            local right_block_w = 320
            imgui.SetCursorPos(imgui.new('ImVec2', win_w - right_block_w, 10))
            
            imgui.BeginGroup()

                local time_str = os.date("%H:%M:%S")
                local date_str = os.date("%A, %d %b %Y")
                local officer_name = "Unknown Officer"
                if core.current_user then
                    if core.current_user.full_name and #core.current_user.full_name > 0 then
                        officer_name = core.current_user.full_name
                    elseif core.current_user.username then
                        officer_name = core.current_user.username
                    end
                end
                
                if officer_name == "Unknown Officer" and safe_str(unitInfoBuffers.officer1_name) ~= "" then
                    officer_name = safe_str(unitInfoBuffers.officer1_name)
                end

                imgui.PushFont(fonts[22])
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), time_str)
                imgui.PopFont()
                
                imgui.SameLine()
                imgui.SetCursorPosX(imgui.GetCursorPosX() + 10)
                
                imgui.BeginGroup()
                    if fonts[18] then imgui.PushFont(fonts[18]) end
                    imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), date_str)
                    imgui.TextColored(imgui.ImVec4(1.0, 0.6, 0.0, 1), officer_name)
                    if fonts[18] then imgui.PopFont() end
                imgui.EndGroup()

                imgui.SameLine()
                imgui.SetCursorPosX(imgui.GetCursorPosX() + 10)
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 5)
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.1, 0.1, 0.0))
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.8, 0.2, 0.2, 1))
                imgui.PushFont(fonts[22])
                if imgui.Button(fa.ICON_FA_RIGHT_FROM_BRACKET, imgui.new('ImVec2', 40, 40)) then
                     UI.mdt[0] = false
                end
                imgui.PopFont()
                imgui.PopStyleColor(2)
                if imgui.IsItemHovered() then imgui.SetTooltip("CLOSE") end

            imgui.EndGroup()
        imgui.EndChild()

        imgui.BeginChild("TopRequestBar", imgui.new('ImVec2', win_w, top_bar_height), false)
            local draw_list = imgui.GetWindowDrawList()
            local p = imgui.GetCursorScreenPos()
            draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + win_w, p.y + top_bar_height), 0xFF222225)
            draw_list:AddLine(imgui.new('ImVec2', p.x, p.y + top_bar_height), imgui.new('ImVec2', p.x + win_w, p.y + top_bar_height), 0xFF353535, 1.0)

            imgui.SetCursorPos(imgui.new('ImVec2', 5, 5))
            local btn_h = 40
            local btn_w = (win_w - 20) / 6 

            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.new('ImVec2', 2, 0))
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.25, 0.25, 0.28, 1.0))
            if imgui.Button("TACTICAL", imgui.new('ImVec2', btn_w, btn_h)) then
                addUnitLogEntry("REQUEST", "TAC Assist requested.")
                arm_pending_incident_marker_seed("request_assist_tactical", 25)
                send_ws_request('tactical', 'request_assist', { assistType = 'TACTICAL' }, function(data, err)
                    if err then return end
                    local incident_id = data and data.payload and data.payload.id
                    if incident_id then
                        if cadui_module.touchIncidentWaypoint(incident_id, 'request_assist_tactical_response') then
                            consume_pending_incident_marker_seed()
                        end
                    end
                end) 
            end; imgui.SameLine()
            if imgui.Button("T/S ASSIST", imgui.new('ImVec2', btn_w, btn_h)) then
                addUnitLogEntry("REQUEST", "T/S Assist requested.")
                arm_pending_incident_marker_seed("request_assist_traffic_stop", 25)
                send_ws_request('tactical', 'request_assist', { assistType = 'TRAFFIC_STOP' }, function(data, err)
                    if err then return end
                    local incident_id = data and data.payload and data.payload.id
                    if incident_id then
                        if cadui_module.touchIncidentWaypoint(incident_id, 'request_assist_traffic_stop_response') then
                            consume_pending_incident_marker_seed()
                        end
                    end
                end) 
            end; imgui.SameLine()
            if selected_incident_index and data_storage.incidents[selected_incident_index] then
                if imgui.Button("INCIDENT", imgui.new('ImVec2', btn_w, btn_h)) then
                    local inc = data_storage.incidents[selected_incident_index]
                    addUnitLogEntry("REQUEST", "Incident assist req #" .. inc.id)
                    send_ws_request('tactical', 'request_incident_assist', { incident_id = inc.id })
                    cadui_module.touchIncidentWaypoint(inc.id, 'request_incident_assist')
                end
            else
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, 0.5)
                imgui.Button("INCIDENT", imgui.new('ImVec2', btn_w, btn_h))
                imgui.PopStyleVar()
            end; imgui.SameLine()
            if imgui.Button("AIR UNIT", imgui.new('ImVec2', btn_w, btn_h)) then
                addUnitLogEntry("REQUEST", "Air support requested.")
                arm_pending_incident_marker_seed("request_assist_air_support", 25)
                send_ws_request('tactical', 'request_assist', { assistType = 'AIR_SUPPORT' }, function(data, err)
                    if err then return end
                    local incident_id = data and data.payload and data.payload.id
                    if incident_id then
                        if cadui_module.touchIncidentWaypoint(incident_id, 'request_assist_air_support_response') then
                            consume_pending_incident_marker_seed()
                        end
                    end
                end) 
            end; imgui.SameLine()
            if imgui.Button("SIMPLEX", imgui.new('ImVec2', btn_w, btn_h)) then
                UI.show_simplex_unit_selector[0] = true
            end; imgui.SameLine()
            if imgui.Button("TOW", imgui.new('ImVec2', btn_w, btn_h)) then
                addUnitLogEntry("REQUEST", "Tow request sent.")
                arm_pending_incident_marker_seed("request_assist_tow", 25)
                send_ws_request('tactical', 'request_assist', { assistType = 'TOW_REQUEST' }, function(data, err)
                    if err then return end
                    local incident_id = data and data.payload and data.payload.id
                    if incident_id then
                        if cadui_module.touchIncidentWaypoint(incident_id, 'request_assist_tow_response') then
                            consume_pending_incident_marker_seed()
                        end
                    end
                end) 
            end
            imgui.PopStyleColor()
            imgui.PopStyleVar()
        imgui.EndChild()

        imgui.BeginChild("LeftSidebar", imgui.new('ImVec2', left_sidebar_width, content_height), true)
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.10, 0.10, 0.12, 1.0))
            
            imgui.SetCursorPos(imgui.new('ImVec2', 12, 10)) 
            
            local sidebar_inner_w = left_sidebar_width - 24 
            local half_w = (sidebar_inner_w - 4) / 2
            local btn_h = 45
            local cur_st = unitInfoBuffers.status[0]

            if drawStatusBtn("CLEAR", imgui.ImVec4(0.1, 0.6, 0.2, 1.0), sidebar_inner_w, btn_h, cur_st == 0) then
                setUnitActiveStatus(true)
            end
            
            imgui.SetCursorPosX(12) 
            imgui.Dummy(imgui.new('ImVec2', 0, 4))
            imgui.SetCursorPosX(12) 

            if drawStatusBtn("ENROUTE", imgui.ImVec4(0.0, 0.4, 0.8, 1.0), half_w, btn_h, cur_st == 1) then
                unitInfoBuffers.status[0] = 1; broadcastUnitStatus(); addUnitLogEntry("STATUS", "En Route")
            end
            imgui.SameLine()
            if drawStatusBtn("CODE 6", imgui.ImVec4(0.0, 0.6, 0.6, 1.0), half_w, btn_h, cur_st == 2) then
                unitInfoBuffers.status[0] = 2; broadcastUnitStatus(); addUnitLogEntry("STATUS", "Code 6 (On Scene)")
            end
            
            imgui.SetCursorPosX(12)
            imgui.Dummy(imgui.new('ImVec2', 0, 4))
            imgui.SetCursorPosX(12)

            if drawStatusBtn("BUSY", imgui.ImVec4(0.8, 0.35, 0.0, 1.0), half_w, btn_h, cur_st == 3) then
                unitInfoBuffers.status[0] = 3; broadcastUnitStatus(); addUnitLogEntry("STATUS", "Busy")
            end
            imgui.SameLine()
            if drawStatusBtn("OUT OF SERVICE", imgui.ImVec4(0.4, 0.4, 0.45, 1.0), half_w, btn_h, cur_st == 4) then
                setUnitActiveStatus(false)
            end

            imgui.Dummy(imgui.new('ImVec2', 0, 15))
            imgui.SetCursorPosX(12)
            
            imgui.TextDisabled("ACTIVE INCIDENTS")
            imgui.Separator()
            imgui.SetCursorPosX(12)
            imgui.BeginChild("SidebarIncidents", imgui.new('ImVec2', sidebar_inner_w, 180), false)
                local count_inc = 0
                if data_storage.incidents then
                    for i, inc in ipairs(data_storage.incidents) do
                        if inc.status ~= "Resolved" then
                            local col_u32 = 0xFF808080
                            if inc.status == 'Active' then col_u32 = 0xFF0000D0 end 
                            if inc.status == 'Code 4' then col_u32 = 0xFF00CCFF end
                            
                            local sub_text = inc.location or "Unknown"
                            if inc.tactical_channel then
                                sub_text = "CH 912." .. tostring(inc.tactical_channel) .. " | " .. sub_text
                            end
                            
                            if drawMiniListCard(tostring(inc.id), inc.summary or "Incident", sub_text, col_u32) then
                                current_mdt_tab = 2 
                                selected_incident_index = i 
                            end
                            imgui.Dummy(imgui.new('ImVec2', 0, 2))
                            count_inc = count_inc + 1
                        end
                    end
                end
                if count_inc == 0 then imgui.TextDisabled("No active incidents") end
            imgui.EndChild()

            imgui.Dummy(imgui.new('ImVec2', 0, 10))
            imgui.SetCursorPosX(12)

            imgui.TextDisabled("RECENT 911")
            imgui.Separator()
            imgui.SetCursorPosX(12)
            
            imgui.BeginChild("SidebarCalls", imgui.new('ImVec2', sidebar_inner_w, 225), false, imgui.WindowFlags.NoScrollbar)
                local count_calls = 0
                for i = 1, math.min(#data_storage.calls, 5) do 
                    local call = data_storage.calls[i]
                    if call then
                        local col_u32 = 0xFF00A5FF 
                        local desc = (call.description and call.description.incident_details) or "Call"
                        local loc_txt = (call.description and call.description.location) or "Unknown"
                        
                        if drawMiniListCard(tostring(call.id), desc, loc_txt, col_u32) then
                            current_mdt_tab = 1 
                            for idx, c in ipairs(data_storage.calls) do
                                if c.id == call.id then selected_call_index = idx; break end
                            end
                        end
                        imgui.Dummy(imgui.new('ImVec2', 0, 2))
                        count_calls = count_calls + 1
                    end
                end
                if count_calls == 0 then imgui.TextDisabled("No recent calls") end
            imgui.EndChild()

            local avail_y = imgui.GetContentRegionAvail().y
            if avail_y > 50 then
                imgui.SetCursorPosY(imgui.GetCursorPosY() + avail_y - 50)
            end
            
            imgui.SetCursorPosX(12)
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.1, 0.1, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.2, 0.2, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.6, 0.0, 0.0, 1.0))
            if imgui.Button("PANIC", imgui.new('ImVec2', sidebar_inner_w, 45)) then
                play_interface_trigger("panic_button")
                addUnitLogEntry("STATUS", "PANIC BUTTON ACTIVATED")
                sampSendChat("/bk")
            end
            imgui.PopStyleColor(3)
            
            imgui.PopStyleColor()
        imgui.EndChild()
        
        imgui.SameLine()

        imgui.BeginGroup()
            imgui.BeginChild("SubHeaderCenter", imgui.new('ImVec2', center_width, 30), false)
               local draw_list = imgui.GetWindowDrawList()
               local p = imgui.GetCursorScreenPos()
               draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + center_width, p.y + 30), 0xFF1E1E1E)
               
               imgui.SetCursorPos(imgui.new('ImVec2', 10, 5))
               if fonts[18] then imgui.PushFont(fonts[18]) end
               imgui.TextDisabled(fa.ICON_FA_USER)
               imgui.SameLine()
               imgui.TextColored(imgui.ImVec4(0.9,0.9,0.9,1), safe_str(unitInfoBuffers.officer1_name))
               imgui.SameLine()
               imgui.TextDisabled(" | ")
               imgui.SameLine()
               imgui.TextDisabled(fa.ICON_FA_LOCATION_DOT)
               imgui.SameLine()
               imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1), currentLocation)
               if fonts[18] then imgui.PopFont() end
            imgui.EndChild()

            imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 10, 10))
            local content_body_h = imgui.GetContentRegionAvail().y
            imgui.BeginChild("ContentBody", imgui.new('ImVec2', center_width, content_body_h), true)
                if current_mdt_tab == 1 then renderCallsTab() 
                elseif current_mdt_tab == 2 then renderIncidentsTab()
                elseif current_mdt_tab == 3 then renderUnitsTab()
                elseif current_mdt_tab == 4 then renderMyInfoTab()
                elseif current_mdt_tab == 5 then renderSettingsTab()
                end
            imgui.EndChild()
            imgui.PopStyleVar()
        imgui.EndGroup()
        
        imgui.SameLine()

        imgui.BeginChild("RightSidebar", imgui.new('ImVec2', right_sidebar_width, content_height), true)
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.10, 0.10, 0.12, 1.0))
            
            imgui.SetCursorPos(imgui.new('ImVec2', 8, 8)) 
            local tool_w = right_sidebar_width - 16 
            local tool_h = 70
            local gap = 8
            local tool_col = imgui.ImVec4(0.9, 0.45, 0.0, 1.0) 
            local ext_col = imgui.ImVec4(0.8, 0.4, 0.0, 1.0)

            if drawStatusBtn("RMS", ext_col, tool_w, tool_h, false) then
                sampProcessChatInput("/rms") 
                addUnitLogEntry("SYSTEM", "Opening RMS...")
            end
            
            imgui.SetCursorPosX(8)
            imgui.Dummy(imgui.new('ImVec2', 0, gap))
            imgui.SetCursorPosX(8)

            if drawStatusBtn("MDC", ext_col, tool_w, tool_h, false) then
                sampSendChat("/mdc")
                UI.mdt[0] = false
                addUnitLogEntry("SYSTEM", "Opening Mobile Data Computer...")
            end
            
            imgui.SetCursorPosX(8)
            imgui.Dummy(imgui.new('ImVec2', 0, gap))
            imgui.SetCursorPosX(8)

            if drawStatusBtn("BOLO", tool_col, tool_w, tool_h, UI.bolo_editor[0]) then
                UI.bolo_editor[0] = not UI.bolo_editor[0]
            end
            
            imgui.SetCursorPosX(8)
            imgui.Dummy(imgui.new('ImVec2', 0, gap))
            imgui.SetCursorPosX(8)
            
            local alpr_active = UI.alpr_window[0] or UI.alpr_manager[0] or UI.alpr_log_window[0]
            if drawStatusBtn("ALPR", tool_col, tool_w, tool_h, alpr_active) then
                cadui_module.toggleALPR()
            end
            
            imgui.SetCursorPosX(8)
            imgui.Dummy(imgui.new('ImVec2', 0, gap))
            imgui.SetCursorPosX(8)
            
            if drawStatusBtn("MAP", tool_col, tool_w, tool_h, UI.map_window[0]) then
                UI.map_window[0] = not UI.map_window[0]
            end
            
            imgui.PopStyleColor()
        imgui.EndChild()

    end
    imgui.End()
    
    imgui.PopStyleColor(3) 
    imgui.PopStyleVar(2) 
end

function updateRadioParserSign(new_sign)
    if not new_sign or new_sign == "" then return end
    
    local file_path = "moonloader/lspdradio_settings.txt"
    local lines = {}
    local found = false

    local file = io.open(file_path, "r")
    if file then
        for line in file:lines() do
            if line:match("^userCallsign=") then
                table.insert(lines, "userCallsign=" .. new_sign)
                found = true
            else
                table.insert(lines, line)
            end
        end
        file:close()
    end

    if not found then
        table.insert(lines, "userCallsign=" .. new_sign)
    end

    local out_file = io.open(file_path, "w")
    if out_file then
        out_file:write(table.concat(lines, "\n"))
        out_file:close()
    end
end

function loadUnitInfoFromSettings()
    local loaded_unit_info = settings.getUnitInfo()
    if loaded_unit_info then
        log('UI', log_levels.INFO, 'Loading unit info from settings.')
        safe_copy(unitInfoBuffers.unitID, loaded_unit_info.unitID or "")
        unitInfoBuffers.unitType[0] = loaded_unit_info.unitType or 0
        safe_copy(unitInfoBuffers.officer1_name, loaded_unit_info.officer1_name or "")
        safe_copy(unitInfoBuffers.officer1_phone, loaded_unit_info.officer1_phone or "")
        
        safe_copy(unitInfoBuffers.officer2_name, loaded_unit_info.officer2_name or "")
        safe_copy(unitInfoBuffers.officer2_phone, loaded_unit_info.officer2_phone or "")
        
        unitInfoBuffers.status[0] = loaded_unit_info.status or 4
        safe_copy(unitInfoBuffers.vehiclePlate, loaded_unit_info.vehiclePlate or "")
        unitInfoBuffers.division[0] = loaded_unit_info.division or 0
        unitInfoBuffers.base_radio_slot[0] = loaded_unit_info.base_radio_slot or 1
        safe_copy(unitInfoBuffers.notes, loaded_unit_info.notes or "")
        assigned_vehicle_id = loaded_unit_info.assigned_vehicle_id or nil
        

        if loaded_unit_info.equipment then
            vehicleEquipment.ar15[0] = loaded_unit_info.equipment.ar15 or false
            vehicleEquipment.ll40mm[0] = loaded_unit_info.equipment.ll40mm or false
            vehicleEquipment.beanbag[0] = loaded_unit_info.equipment.beanbag or false
            vehicleEquipment.riot_shield[0] = loaded_unit_info.equipment.riot or false
            vehicleEquipment.spikes[0] = loaded_unit_info.equipment.spikes or false
            vehicleEquipment.narcan[0] = loaded_unit_info.equipment.narcan or false
            vehicleEquipment.pit_auth[0] = loaded_unit_info.equipment.pit or false
            vehicleEquipment.aed[0] = loaded_unit_info.equipment.aed or false
        end
    else
        log('UI', log_levels.WARN, 'No saved unit info found, using defaults.')
    end
end

local bolo_status_colors_hex = {
    ['In Progress'] = 0xFFFF9900, -- Оранжевый
    ['In Custody']  = 0xFF3498DB, -- Синий
    ['Clear']       = 0xFF2ECC71, -- Зеленый
    ['Default']     = 0xFF808080  -- Серый
}

local function drawModernBoloCard(bolo, is_selected)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local width = imgui.GetColumnWidth() - 10 
    local height = 60
    local rounding = 5.0

    local status_key = bolo.status or 'In Progress'
    local color = bolo_status_colors_hex[status_key] or bolo_status_colors_hex['Default']
    
    local btn_name = "##bolo_card_" .. tostring(bolo.id)
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
    local clicked = imgui.Button(btn_name, imgui.new('ImVec2', width, height))
    imgui.PopStyleColor(3)
    
    local is_hovered = imgui.IsItemHovered()
    local bg_color = is_selected and 0xFF454545 or 0xFF252A33
    if is_hovered and not is_selected then bg_color = 0xFF353A45 end

    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), bg_color, rounding)
    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + 5, p.y + height), color, rounding, 1+8)

    local start_x = p.x + 15
    local id_text = string.format("BOLO #%s", tostring(bolo.id or "?"))
    draw_list:AddText(imgui.new('ImVec2', start_x, p.y + 5), 0xFF808080, id_text)

    local subject = bolo.subject_name or "Unknown Subject"
    if #subject > 35 then subject = subject:sub(1, 32).."..." end
    
    if fonts[18] then imgui.PushFont(fonts[18]) end
    draw_list:AddText(imgui.new('ImVec2', start_x, p.y + 18), 0xFFFFFFFF, subject)
    if fonts[18] then imgui.PopFont() end

    local type_icon = (bolo.type == "Vehicle") and fa.ICON_FA_CAR_SIDE or fa.ICON_FA_USER
    local time_str = bolo.timestamp_created or "Just now"
    time_str = time_str:match("(%d%d%d%d%-%d%d%-%d%d)") or time_str 
    
    if fonts[18] then imgui.PushFont(fonts[18]) end
    draw_list:AddText(imgui.new('ImVec2', start_x, p.y + 38), 0xFFAAAAAA, string.format("%s  %s  |  %s", type_icon, bolo.type or "?", time_str))
    if fonts[18] then imgui.PopFont() end

    return clicked
end

local function drawPlateCard(plate_entry, width)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local height = 40
    
    draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + width, p.y + height), 0xFFDDDDDD, 4.0) 
    draw_list:AddRect(p, imgui.new('ImVec2', p.x + width, p.y + height), 0xFF202020, 4.0, 15, 1.5) 
    
    local text = tostring(plate_entry.plate):upper()
    local text_size = imgui.CalcTextSize(text)
    local center_x = p.x + (width - text_size.x) / 2
    local center_y = p.y + (height - text_size.y) / 2
    
    if fonts[22] then imgui.PushFont(fonts[22]) end
    draw_list:AddText(imgui.new('ImVec2', center_x, center_y), 0xFF402010, text)
    if fonts[22] then imgui.PopFont() end
    
    imgui.Dummy(imgui.new('ImVec2', width, height))
end

function drawBoloEditor()
    if not UI.bolo_editor[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 1000, 650), imgui.Cond.FirstUseEver)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.08, 0.08, 0.10, 0.98))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.12, 0.12, 0.14, 1.0))
    
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 5.0) 
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 0.0) 
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.20, 0.20, 0.24, 1.0)) 
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0.25, 0.25, 0.30, 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0.30, 0.30, 0.35, 1.0))
    
    if imgui.Begin("BOLO System", UI.bolo_editor, imgui.WindowFlags.NoCollapse) then
        
        local win_w = imgui.GetContentRegionAvail().x
        imgui.BeginChild("BoloHeader", imgui.new('ImVec2', win_w, 50), false)
            local draw_list = imgui.GetWindowDrawList()
            local p = imgui.GetCursorScreenPos()
            draw_list:AddRectFilled(p, imgui.new('ImVec2', p.x + win_w, p.y + 50), 0xFF151515)
            
            imgui.SetCursorPos(imgui.new('ImVec2', 15, 10))
            imgui.PushFont(fonts[22])
            imgui.TextColored(imgui.ImVec4(1, 0.6, 0, 1), "WANTED & BOLO")
            imgui.PopFont()
            imgui.SameLine()
            imgui.TextDisabled(" |  DATABASE MANAGEMENT")
            
            imgui.SetCursorPos(imgui.new('ImVec2', win_w - 40, 10))
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
            if imgui.Button(fa.ICON_FA_XMARK, imgui.new('ImVec2', 30, 30)) then UI.bolo_editor[0] = false end
            imgui.PopStyleColor()
        imgui.EndChild()

        imgui.PushStyleColor(imgui.Col.Tab, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.TabActive, imgui.ImVec4(0.2, 0.2, 0.25, 1))
        
        if imgui.BeginTabBar("BoloTabs") then
            
            if imgui.BeginTabItem(" ACTIVE REPORTS ") then
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 10, 10))
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 0.2, 1.0))
                if imgui.Button("+ CREATE NEW REPORT", imgui.new('ImVec2', -1, 35)) then
                    UI.bolo_creator_window[0] = true
                end
                imgui.PopStyleColor()
                
                imgui.Dummy(imgui.new('ImVec2', 0, 5))

                imgui.Columns(2, "BoloCols", false)
                imgui.SetColumnWidth(0, 350)

                imgui.BeginChild("BoloList", imgui.new('ImVec2', 0, 0), true)
                    if #data_storage.bolos == 0 then
                        imgui.TextDisabled("No active reports.")
                    else
                        for i, bolo in ipairs(data_storage.bolos) do
                            local is_selected = (selected_bolo_index == i)

                            if drawModernBoloCard(bolo, is_selected) then
                                selected_bolo_index = i
                                safe_copy(bolo_note_buffer, "")
                            end
                            imgui.Dummy(imgui.new('ImVec2', 0, 5))
                        end
                    end
                imgui.EndChild()

                imgui.NextColumn()

                imgui.BeginChild("BoloDetails", imgui.new('ImVec2', 0, 0), true)
                    local width = imgui.GetContentRegionAvail().x

                    if selected_bolo_index and data_storage.bolos[selected_bolo_index] then
                        local bolo = data_storage.bolos[selected_bolo_index]
                        
                        imgui.BeginGroup()
                            imgui.PushFont(fonts[22])
                            imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "CASE #" .. tostring(bolo.id))
                            imgui.PopFont()
                            imgui.TextDisabled("Created by: " .. (bolo.created_by or "Unknown"))
                        imgui.EndGroup()

                        imgui.SameLine()
                        
                        local status_w = 140
                        imgui.SetCursorPosX(width - status_w)
                        local st_vec = boloStatusColors[bolo.status] or imgui.ImVec4(0.5,0.5,0.5,1)
                        
                        imgui.PushStyleColor(imgui.Col.Button, st_vec)
                        imgui.Button(bolo.status or "Unknown", imgui.new('ImVec2', status_w, 30))
                        imgui.PopStyleColor()

                        imgui.Separator()
                        imgui.Dummy(imgui.new('ImVec2', 0, 10))

                        local half_w = (width - 10) / 2
                        drawInfoCard("Subject", bolo.subject_name or "N/A", half_w, fa.ICON_FA_USER)
                        imgui.SameLine()
                        drawInfoCard("Type", bolo.type or "N/A", half_w, (bolo.type=="Vehicle" and fa.ICON_FA_CAR_SIDE or fa.ICON_FA_CIRCLE_QUESTION))
                        
                        imgui.Dummy(imgui.new('ImVec2', 0, 5))
                        drawInfoCard("Last Seen", bolo.last_location or "Unknown", width, fa.ICON_FA_LOCATION_DOT)

                        imgui.Dummy(imgui.new('ImVec2', 0, 15))

                        imgui.TextDisabled("DESCRIPTION / APPEARANCE")
                        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 1.0))
                        imgui.BeginChild("BoloDesc", imgui.new('ImVec2', 0, 80), true)
                            imgui.TextWrapped(bolo.description or "No description.")
                        imgui.EndChild()
                        imgui.PopStyleColor()

                        imgui.Dummy(imgui.new('ImVec2', 0, 5))

                        imgui.TextDisabled("CRIME SUMMARY / REASON")
                        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.18, 1.0))
                        imgui.BeginChild("BoloReason", imgui.new('ImVec2', 0, 60), true)
                            imgui.TextWrapped(bolo.crime_summary or "No details.")
                        imgui.EndChild()
                        imgui.PopStyleColor()

                        imgui.Dummy(imgui.new('ImVec2', 0, 10))

                        imgui.TextDisabled("ACTIONS")
                        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.25, 0.3, 1.0))
                        if imgui.Button("UPDATE STATUS", imgui.new('ImVec2', 150, 35)) then
                            imgui.OpenPopup("BoloStatusPopup")
                        end
                        imgui.PopStyleColor()
                        
                        if imgui.BeginPopup("BoloStatusPopup") then
                            for _, st in ipairs(boloStatuses) do
                                if imgui.Selectable(st) then
                                    updateBoloStatus(bolo.id, st)
                                end
                            end
                            imgui.EndPopup()
                        end

                        imgui.Separator()
                        
                        imgui.Text("Case Notes:")
                        imgui.InputTextMultiline("##bolo_note", bolo_note_buffer, ffi.sizeof(bolo_note_buffer), imgui.new('ImVec2', -1, 40))
                        if imgui.Button("Add Note", imgui.new('ImVec2', 100, 30)) then
                            local note = safe_str(bolo_note_buffer)
                            if note ~= "" then
                                addBoloNote(bolo.id, note)
                                ffi.copy(bolo_note_buffer, "")
                            end
                        end

                        imgui.BeginChild("BoloLogs", imgui.new('ImVec2', 0, 100), true)
                            if bolo.event_log then
                                for _, ev in ipairs(bolo.event_log) do
                                    imgui.TextDisabled(ev.time or "")
                                    imgui.SameLine()
                                    imgui.TextWrapped(ev.event or "")
                                end
                            end
                        imgui.EndChild()

                    else
                        imgui.SetCursorPos(imgui.new('ImVec2', width/2 - 60, 200))
                        imgui.TextDisabled("Select a report to view details")
                    end
                imgui.EndChild()
                imgui.Columns(1)
                imgui.PopStyleVar()
                imgui.EndTabItem()
            end

            if imgui.BeginTabItem(" WANTED PLATES (ALPR) ") then
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 20, 20))
                
                imgui.TextDisabled("HOTLIST MANAGEMENT")
                imgui.Separator()
                
                imgui.Columns(2, "PlateAddCols", false)
                imgui.SetColumnWidth(0, 300)
                
                imgui.Text("Add New Plate:")
                imgui.SetNextItemWidth(200)
                imgui.InputText("##new_plate", new_wanted_plate_buffer, ffi.sizeof(new_wanted_plate_buffer))
                imgui.SameLine()
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.0, 0.6, 0.35, 1.0))
                if imgui.Button("ADD", imgui.new('ImVec2', 80, 25)) then
                    addWantedPlate(safe_str(new_wanted_plate_buffer))
                end
                imgui.PopStyleColor()
                
                imgui.NextColumn()
                imgui.TextWrapped("Vehicles with these plates will trigger an audio alert when scanned by ALPR.")
                imgui.Columns(1)
                
                imgui.Dummy(imgui.new('ImVec2', 0, 15))
                
                imgui.BeginChild("PlatesList", imgui.new('ImVec2', 0, 0), true)
                    if #data_storage.wanted_plates == 0 then
                        imgui.TextDisabled("Hotlist is empty.")
                    else
                        for i, entry in ipairs(data_storage.wanted_plates) do
                            
                            local avail_w = imgui.GetContentRegionAvail().x
                            local btn_w = 90
                            local plate_w = avail_w - btn_w - 15 
                            
                            drawPlateCard(entry, plate_w)
                            
                            imgui.SameLine()
                            
                            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.7, 0.2, 0.2, 1.0))
                            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.8, 0.3, 0.3, 1.0))
                            if imgui.Button("REMOVE##"..i, imgui.new('ImVec2', btn_w, 40)) then
                                removeWantedPlate(entry.id)
                            end
                            imgui.PopStyleColor(2)
                            
                            imgui.Dummy(imgui.new('ImVec2', 0, 5))
                        end
                    end
                imgui.EndChild()
                
                imgui.PopStyleVar()
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
        imgui.PopStyleColor(2) 
    end
    imgui.End()
    
    imgui.PopStyleColor(5) 
    imgui.PopStyleVar(3)   
end

imgui.OnInitialize(function()
    log('UI', log_levels.INFO, 'imgui.OnInitialize started.')

    safe_copy(keyBindBuffers.mdt, settings.get('controls_settings', 'open_mdt_key', 'VK_F2'))
    safe_copy(keyBindBuffers.alpr, settings.get('controls_settings', 'open_alpr_key', 'VK_1'))
    safe_copy(keyBindBuffers.map, settings.get('controls_settings', 'open_map_key', 'VK_M'))
    log('UI', log_levels.INFO, 'Step 1: Old keybinds loaded.')

    loadUnitInfoFromSettings()
    log('UI', log_levels.INFO, 'Step 2: Unit info loaded.')

    local imguiIO = imgui.GetIO()
    imguiIO.IniFilename = nil

    local fonts_path = getGameDirectory() .. '\\moonloader\\cad_system\\resource\\fonts\\'
    local icons_path = fonts_path 

    local config_text = imgui.ImFontConfig()
    config_text.MergeMode = false 
    config_text.PixelSnapH = true

    local config_icons = imgui.ImFontConfig()
    config_icons.MergeMode = true 
    config_icons.PixelSnapH = true
    config_icons.GlyphMinAdvanceX = 13.0
    config_icons.GlyphOffset = imgui.new('ImVec2', 0, 1)

    local icon_ranges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)
    local glyph_ranges_cyr = imguiIO.Fonts:GetGlyphRangesCyrillic()

    if doesFileExist(fonts_path .. 'Roboto-Medium.ttf') then
        fonts[18] = imguiIO.Fonts:AddFontFromFileTTF(fonts_path .. 'Roboto-Medium.ttf', 16, config_text, glyph_ranges_cyr)
    else
        fonts[18] = imguiIO.Fonts:AddFontDefault()
        log('UI', log_levels.WARN, "Roboto font not found at: " .. fonts_path)
    end
    
    if doesFileExist(icons_path .. 'fa-solid-900.ttf') then
        imguiIO.Fonts:AddFontFromFileTTF(icons_path .. 'fa-solid-900.ttf', 14, config_icons, icon_ranges)
    end

    local config_header = imgui.ImFontConfig()
    config_header.MergeMode = false 
    
    if doesFileExist(fonts_path .. 'Roboto-Medium.ttf') then
        fonts[22] = imguiIO.Fonts:AddFontFromFileTTF(fonts_path .. 'Roboto-Medium.ttf', 24, config_header, glyph_ranges_cyr)
        
        if doesFileExist(icons_path .. 'fa-solid-900.ttf') then
            imguiIO.Fonts:AddFontFromFileTTF(icons_path .. 'fa-solid-900.ttf', 20, config_icons, icon_ranges)
        end
    end

    imguiIO.Fonts:Build()

    log('UI', log_levels.INFO, 'Step 3: Fonts processed.')

    divisionOptions_c = imgui.new['const char*'][#comboBoxData.division](comboBoxData.division)
    unitTypeOptions_c = imgui.new['const char*'][#comboBoxData.unitType](comboBoxData.unitType)
    shiftOptions_c = imgui.new['const char*'][#comboBoxData.shift](comboBoxData.shift)
    boloTypes_c = imgui.new['const char*'][#boloTypes](boloTypes)
    boloStatuses_c = imgui.new['const char*'][#boloStatuses](boloStatuses)
    log('UI', log_levels.INFO, 'Step 4: Combo box data prepared.')

    ensure_interface_sounds_loaded(true)
    log('UI', log_levels.INFO, 'Step 5-6: Sounds processed.')

    log('UI', log_levels.INFO, 'Step 7: Textures deferred (lazy load on first map open).')

    ThemeManager.initialize()
    log('UI', log_levels.INFO, 'Step 8: ThemeManager initialized.')

    BinderManager.initialize()
    log('UI', log_levels.INFO, 'Step 9: BinderManager initialized.')
end)


local unit_marker_texture = nil
local next_marker_id = 1
local context_marker = nil
local show_marker_edit_modal = imgui.new.bool(false)
local marker_edit_buffer = {
    text = imgui.new.char[128](),
    radius = imgui.new.float(100.0)
}

local last_map_window_pos = nil
local map_data_loaded = false
local map_fetch_state = { in_flight = false, retry_at = 0 }
local map_markers = {}
local map_lines = {}
local map_interaction_mode = "pan"
local map_context_menu_unit = nil
local map_context_menu_pos = nil
local latched_hovered_item = nil
local is_context_menu_open = false
local active_line_points = {}

function send_map_request(action, payload, callback)
    log('UI', log_levels.DEBUG, string.format("Sending map request: %s", action))
    send_ws_request('map', action, payload, callback)
end

local function upsert_local_map_marker(marker)
    if not marker then return end

    if marker.marker_type == 'line' then
        if type(marker.points_data) == 'string' then
            marker.points_data = json.decode(marker.points_data)
        end
        for i, line in ipairs(map_lines) do
            if tonumber(line.id) == tonumber(marker.id) then
                map_lines[i] = marker
                return
            end
        end
        table.insert(map_lines, marker)
        return
    end

    for i, m in ipairs(map_markers) do
        local same_id = (tonumber(m.id) == tonumber(marker.id))
        local same_dedupe = marker.dedupe_key and m.dedupe_key and tostring(marker.dedupe_key) == tostring(m.dedupe_key)
        if same_id or same_dedupe then
            map_markers[i] = marker
            return
        end
    end
    table.insert(map_markers, marker)
end

function handle_map_update(response)
    local action = response.action
    local payload = response.payload
    log('UI', log_levels.INFO, string.format("Handling map update: %s", action))

    if not payload then return end

    if action == 'marker_added' then
        upsert_local_map_marker(payload)
    elseif action == 'marker_removed' then
        local id_to_remove = payload.id
        if checkpoint_tracker.marker_id and tonumber(checkpoint_tracker.marker_id) == tonumber(id_to_remove) then
            clear_checkpoint_tracker()
        end
        for i = #map_markers, 1, -1 do
            if map_markers[i].id == id_to_remove then
                table.remove(map_markers, i)
            end
        end
        for i = #map_lines, 1, -1 do
            if map_lines[i].id == id_to_remove then
                table.remove(map_lines, i)
            end
        end
    elseif action == 'all_markers_cleared' and payload.type == 'temporary' then
        local remaining_markers = {}
        local remaining_lines = {}
        for _, marker in ipairs(map_markers) do
            if marker.is_permanent == 1 or marker.marker_type == 'dispatch_waypoint' then
                table.insert(remaining_markers, marker)
            end
        end
        for _, line in ipairs(map_lines) do
            if line.is_permanent == 1 then
                table.insert(remaining_lines, line)
            end
        end
        map_markers = remaining_markers
        map_lines = remaining_lines
    elseif action == 'marker_updated' then
        upsert_local_map_marker(payload)
    elseif action == 'markers_removed_stale' then
        local ids_to_remove = payload.ids
        if checkpoint_tracker.marker_id and ids_to_remove then
            for _, id in ipairs(ids_to_remove) do
                if tonumber(id) == tonumber(checkpoint_tracker.marker_id) then
                    clear_checkpoint_tracker()
                    break
                end
            end
        end
        local remaining_markers = {}
        local remaining_lines = {}
        for _, marker in ipairs(map_markers) do
            local should_keep = true
            for _, id in ipairs(ids_to_remove) do
                if marker.id == id then
                    should_keep = false
                    break
                end
            end
            if should_keep then table.insert(remaining_markers, marker) end
        end
        for _, line in ipairs(map_lines) do
            local should_keep = true
            for _, id in ipairs(ids_to_remove) do
                if line.id == id then
                    should_keep = false
                    break
                end
            end
            if should_keep then table.insert(remaining_lines, line) end
        end
        map_markers = remaining_markers
        map_lines = remaining_lines
    end
end

function screenToWorld(screen_x, screen_y, window_pos)
    local map_total_width_unzoomed = 205 * 4
    local map_total_height_unzoomed = 205 * 4

    local map_x_unzoomed = (screen_x - window_pos.x - map_offset_x) / map_zoom
    local map_y_unzoomed = (screen_y - window_pos.y - map_offset_y) / map_zoom

    local world_x = (map_x_unzoomed / map_total_width_unzoomed) * 6000 - 3000
    local world_y = -((map_y_unzoomed / map_total_height_unzoomed) * 6000 - 3000)

    return world_x, world_y
end

pending_checkpoint_source = nil
checkpoint_tracker = {
    pending_started_at = 0,
    marker_id = nil,
    call_id = nil,
    source_type = nil,
    source_id = nil,
    dedupe_key = nil,
    last_pos = nil,
    last_sync = 0,
    last_checkpoint_seen_at = 0
}

function source_uses_checkpoint(source_type)
    return source_type == 'call_911'
end

function is_call_resolved_status(status)
    local s = tostring(status or ''):lower()
    return s == 'clear' or s == 'resolved'
end

function get_local_officer_position()
    if getCharCoordinates and PLAYER_PED then
        local ok, x, y, z = pcall(getCharCoordinates, PLAYER_PED)
        if ok and x and y and z then
            return tonumber(x), tonumber(y), tonumber(z)
        end
    end

    if core and core.current_unit and core.current_unit.pos_x and core.current_unit.pos_y then
        return tonumber(core.current_unit.pos_x), tonumber(core.current_unit.pos_y), tonumber(core.current_unit.pos_z) or 0.0
    end

    return nil, nil, nil
end

MAP_ETA_AVG_SPEED_KMH = 30.0
MAP_ETA_ROUTE_FACTOR = 1.35
CALL_CHECKPOINT_LOSS_GRACE_SEC = 6.0

function estimate_eta_label(distance_m)
    local speed_ms = (MAP_ETA_AVG_SPEED_KMH * 1000.0) / 3600.0
    if speed_ms <= 0 then return "ETA 0:00" end

    local adjusted_distance = (tonumber(distance_m) or 0) * MAP_ETA_ROUTE_FACTOR
    local total_seconds = adjusted_distance / speed_ms
    if total_seconds < 5 then
        return "ETA 0:00"
    end

    local minutes = math.floor(total_seconds / 60)
    local seconds = math.floor((total_seconds % 60) + 0.5)
    if seconds >= 60 then
        minutes = minutes + 1
        seconds = 0
    end
    return string.format("ETA %d:%02d", minutes, seconds)
end

function get_active_checkpoint_xyz()
    if sampGetPlayerCheckpoint and type(sampGetPlayerCheckpoint) == "function" then
        local ok, active, x, y, z = pcall(sampGetPlayerCheckpoint)
        if ok and active then
            return true, x, y, z
        end
    end
    return false, nil, nil, nil
end

function try_sync_dispatch_checkpoint(x, y, z, sync_source)
    if not sync_source or not sync_source.dedupe_key then return end

    upsert_dispatch_waypoint(sync_source, x, y, z, function(data, err)
        if err then
            log('UI', log_levels.ERROR, 'Dispatch waypoint upsert failed: ' .. tostring(err))
            return
        end
        if data and data.payload then
            adopt_dispatch_tracker(data.payload, sync_source)
            checkpoint_tracker.last_pos = { x = x, y = y, z = z }
            checkpoint_tracker.last_sync = os.clock()
            checkpoint_tracker.last_checkpoint_seen_at = checkpoint_tracker.last_sync
            log('UI', log_levels.INFO, string.format('Dispatch waypoint synced for %s:%s at %.2f, %.2f, %.2f', tostring(sync_source.source_type), tostring(sync_source.source_id), x, y, z))
        end
    end)
end

samp_events.onSetCheckpoint = function(position, radius)
    if not position then return end

    local x = tonumber(position.x)
    local y = tonumber(position.y)
    local z = tonumber(position.z)
    if not x or not y or not z then return end

    if pending_checkpoint_source then
        local source = pending_checkpoint_source
        pending_checkpoint_source = nil
        try_sync_dispatch_checkpoint(x, y, z, source)
        return
    end

    if checkpoint_tracker.dedupe_key and source_uses_checkpoint(checkpoint_tracker.source_type) then
        checkpoint_tracker.last_checkpoint_seen_at = os.clock()
        local should_sync = true
        if checkpoint_tracker.last_pos then
            local dx = x - (checkpoint_tracker.last_pos.x or 0)
            local dy = y - (checkpoint_tracker.last_pos.y or 0)
            local dist = math.sqrt(dx * dx + dy * dy)
            should_sync = dist >= 3.0
        end
        if should_sync then
            try_sync_dispatch_checkpoint(x, y, z, {
                source_type = checkpoint_tracker.source_type,
                source_id = checkpoint_tracker.source_id,
                dedupe_key = checkpoint_tracker.dedupe_key,
                label = checkpoint_tracker.call_id and ('Call #' .. tostring(checkpoint_tracker.call_id)) or nil
            })
        end
    end
end

samp_events.onDisableCheckpoint = function()
    if source_uses_checkpoint(checkpoint_tracker.source_type) and (checkpoint_tracker.dedupe_key or checkpoint_tracker.marker_id) then
        checkpoint_tracker.last_checkpoint_seen_at = checkpoint_tracker.last_checkpoint_seen_at or os.clock()
        log('UI', log_levels.DEBUG, 'Checkpoint disabled event received for call_911; waiting for grace timeout before removing marker.')
    end
end

function get_call_id_from_waypoint_marker(marker)
    if not marker then return nil end
    if marker.source_type and (marker.source_type == 'call_911' or marker.source_type == 'incident_call') and marker.source_id then
        return tonumber(marker.source_id)
    end
    if marker.dedupe_key then
        local key = tostring(marker.dedupe_key)
        local call_from_key = key:match("^dispatch:call_911:(%d+)$")
        if call_from_key then
            return tonumber(call_from_key)
        end
        local incident_call_from_key = key:match("^dispatch:incident_call:(%d+)$")
        if incident_call_from_key then
            return tonumber(incident_call_from_key)
        end
    end
    if marker.related_call_id then
        return tonumber(marker.related_call_id)
    end
    if marker.label then
        local from_label = tostring(marker.label):match("[Cc]all%s*#(%d+)")
        if from_label then
            return tonumber(from_label)
        end
    end
    return nil
end

function build_dispatch_dedupe_key(source_type, source_id)
    if not source_type or not source_id then return nil end
    return string.format("dispatch:%s:%s", tostring(source_type), tostring(source_id))
end

function adopt_dispatch_tracker(marker, fallback_source)
    if not marker then return end
    checkpoint_tracker.marker_id = marker.id
    checkpoint_tracker.source_type = marker.source_type or (fallback_source and fallback_source.source_type) or checkpoint_tracker.source_type
    checkpoint_tracker.source_id = marker.source_id or (fallback_source and fallback_source.source_id) or checkpoint_tracker.source_id
    checkpoint_tracker.dedupe_key = marker.dedupe_key or (fallback_source and fallback_source.dedupe_key) or checkpoint_tracker.dedupe_key
    checkpoint_tracker.call_id = get_call_id_from_waypoint_marker(marker) or checkpoint_tracker.call_id
end

function upsert_dispatch_waypoint(source, x, y, z, cb)
    if not source or not source.dedupe_key then
        if cb then cb(nil, "missing source dedupe_key") end
        return
    end

    local payload = {
        dedupe_key = source.dedupe_key,
        source_type = source.source_type,
        source_id = source.source_id,
        label = source.label,
        points_data = {{ x = x, y = y, z = z }},
        is_permanent = 0
    }

    send_map_request('upsert_dispatch_marker', payload, function(data, err)
        if not err and data and data.payload then
            adopt_dispatch_tracker(data.payload, source)
            checkpoint_tracker.last_pos = { x = x, y = y, z = z }
            checkpoint_tracker.last_sync = os.clock()
        end
        if cb then cb(data, err) end
    end)
end

function clear_checkpoint_tracker()
    checkpoint_tracker.marker_id = nil
    checkpoint_tracker.call_id = nil
    checkpoint_tracker.source_type = nil
    checkpoint_tracker.source_id = nil
    checkpoint_tracker.dedupe_key = nil
    checkpoint_tracker.last_pos = nil
    checkpoint_tracker.last_checkpoint_seen_at = 0
end

function close_dispatch_waypoint()
    if checkpoint_tracker.dedupe_key then
        send_map_request('close_dispatch_marker', { dedupe_key = checkpoint_tracker.dedupe_key })
    elseif checkpoint_tracker.marker_id then
        send_map_request('remove_marker', { id = checkpoint_tracker.marker_id })
    end
    clear_checkpoint_tracker()
end

function cadui_module.setPendingCheckpointForCall(call_id)
    if call_id then
        log('UI', log_levels.INFO, 'Pending checkpoint interception for call ID: ' .. tostring(call_id))
        pending_checkpoint_source = {
            source_type = 'call_911',
            source_id = tonumber(call_id) or call_id,
            dedupe_key = build_dispatch_dedupe_key('call_911', tonumber(call_id) or call_id),
            label = 'Call #' .. tostring(call_id)
        }
        checkpoint_tracker.pending_started_at = os.clock()
    end
end

function cadui_module.setPendingCheckpointSource(source_type, source_id, label)
    if not source_type or not source_id then return false end
    local dedupe_key = build_dispatch_dedupe_key(source_type, source_id)
    if not dedupe_key then return false end

    pending_checkpoint_source = {
        source_type = tostring(source_type),
        source_id = source_id,
        dedupe_key = dedupe_key,
        label = label or string.format('%s #%s', tostring(source_type), tostring(source_id))
    }
    checkpoint_tracker.pending_started_at = os.clock()
    log('UI', log_levels.INFO, 'Pending checkpoint interception for source: ' .. tostring(dedupe_key))
    return true
end

function cadui_module.setPendingCheckpointForIncident(incident_id)
    if not incident_id then return false end
    local source_type = 'incident_call'
    local source_id = tonumber(incident_id) or incident_id
    local source_label = 'Incident #' .. tostring(incident_id)
    local dedupe_key = build_dispatch_dedupe_key(source_type, source_id)

    if not dedupe_key then return false end

    local source = {
        source_type = source_type,
        source_id = source_id,
        dedupe_key = dedupe_key,
        label = source_label
    }

    local x, y, z = get_local_officer_position()
    if x and y and z then
        log('UI', log_levels.INFO, string.format('Setting incident waypoint from officer position: incident=%s pos=(%.2f, %.2f, %.2f)', tostring(incident_id), x, y, z))
        upsert_dispatch_waypoint(source, x, y, z)
        pending_checkpoint_source = nil
        checkpoint_tracker.pending_started_at = 0
        return true
    end

    log('UI', log_levels.WARN, 'Failed to set incident waypoint: officer position unavailable.')
    return false
end

function cadui_module.touchIncidentWaypoint(incident_id, reason)
    if not incident_id then return false end
    local dedupe_key = "dispatch:incident_call:" .. tostring(incident_id)
    for _, marker in ipairs(map_markers or {}) do
        if marker and marker.marker_type == 'dispatch_waypoint' and marker.dedupe_key and tostring(marker.dedupe_key) == dedupe_key then
            log('UI', log_levels.DEBUG, string.format('Incident waypoint already exists for #%s; skipping position update (%s)', tostring(incident_id), tostring(reason or 'event')))
            return true
        end
    end
    local ok = cadui_module.setPendingCheckpointForIncident(incident_id)
    if ok then
        log('UI', log_levels.INFO, string.format('Incident waypoint touched for #%s (%s)', tostring(incident_id), tostring(reason or 'event')))
    else
        log('UI', log_levels.WARN, string.format('Incident waypoint touch failed for #%s (%s)', tostring(incident_id), tostring(reason or 'event')))
    end
    return ok
end

function cadui_module.toggleMap()
    UI.map_window[0] = not UI.map_window[0]
end

function cadui_module.toggleALPR()
    local is_alpr_open = UI.alpr_window[0] or UI.alpr_manager[0] or UI.alpr_log_window[0]
    if is_alpr_open then
        UI.alpr_window[0] = false
        UI.alpr_manager[0] = false
        UI.alpr_log_window[0] = false
        return
    end

    if not isCharInAnyCar(PLAYER_PED) then
        return
    end

    if cadui_module.isPlayerInPatrolCar() then
        UI.alpr_manager[0] = true
        UI.alpr_window[0] = true
    end
end



function renderMarkerEditModal()
    if not show_marker_edit_modal[0] or not context_marker then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 300, 200), imgui.Cond.FirstUseEver)
    local sw, sh = getScreenResolution()
    local window_pos = imgui.new('ImVec2', sw / 2, sh / 2)
    imgui.SetNextWindowPos(window_pos, imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))
    
    if imgui.Begin("Edit Marker##marker_edit_modal", show_marker_edit_modal) then
        imgui.InputText("Label", marker_edit_buffer.text, ffi.sizeof(marker_edit_buffer.text))
        
        if context_marker.marker_type == 'circle' then
            imgui.InputFloat("Radius", marker_edit_buffer.radius, 10.0, 50.0, '%.1f')
        end

        if imgui.Button("Save", imgui.new('ImVec2', -1, 0)) then
            context_marker.label = safe_str(marker_edit_buffer.text)
            if context_marker.marker_type == 'circle' then
                context_marker.radius = marker_edit_buffer.radius[0]
            end
            send_map_request('update_marker', context_marker)
            show_marker_edit_modal[0] = false
        end
    end
    imgui.End()
end

function renderSimplexUnitSelector()
    if not UI.show_simplex_unit_selector[0] then return end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 400, 500), imgui.Cond.FirstUseEver)
    local sw, sh = getScreenResolution()
    imgui.SetNextWindowPos(imgui.new('ImVec2', sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.new('ImVec2', 0.5, 0.5))

    if imgui.Begin("Select Unit for Simplex Channel", UI.show_simplex_unit_selector) then
        imgui.Text("Select a unit to request a private channel with.")
        imgui.Separator()

        imgui.BeginChild("UnitListSimplex", imgui.new('ImVec2', 0, -40), true)
        
        if data_storage and data_storage.units and #data_storage.units > 0 then
            local my_user_id = core.current_user and core.current_user.id or -1
            local other_units_found = false
            for _, unit in ipairs(data_storage.units) do
                if unit.user_id ~= my_user_id then
                    other_units_found = true
                    local label = string.format("%s - %s (%s)", unit.unitID or "N/A", unit.officer1_name or "N/A", (comboBoxData.status[unit.status + 1] or "Unknown"))
                    if imgui.Button(label, imgui.new('ImVec2', -1, 0)) then
                        log('UI', log_levels.INFO, string.format("Requesting simplex with unit ID %d", unit.id))
                        send_ws_request('tactical', 'request_simplex', { target_unit_id = unit.id })
                        UI.show_simplex_unit_selector[0] = false
                    end
                end
            end
            if not other_units_found then
                imgui.Text("No other active units found.")
            end
        else
            imgui.Text("No other active units found.")
        end

        imgui.EndChild()

        if imgui.Button("Cancel", imgui.new('ImVec2', -1, 0)) then
            UI.show_simplex_unit_selector[0] = false
        end
    end
    imgui.End()
end

function renderMapWindow()
    if not UI.map_window[0] then 
        map_data_loaded = false
        return
    end

    if not map_textures_loaded then
        ensure_map_textures_loaded()
    end

    local function findUnitById(unit_id)
        if not unit_id then return nil end
        for _, unit in ipairs(data_storage.units) do
            if unit.id == unit_id or unit.unitID == unit_id then
                return unit
            end
        end
        return nil
    end

    if not map_data_loaded then
        local now = os.clock()
        if (not map_fetch_state.in_flight) and now >= map_fetch_state.retry_at then
            map_fetch_state.in_flight = true
            send_map_request('fetch_markers', {}, function(data, err)
                map_fetch_state.in_flight = false
                if err then
                    if tostring(err) == "Request timeout" then
                        log('UI', log_levels.WARN, "Map fetch timeout, will retry shortly.")
                        map_fetch_state.retry_at = os.clock() + 3.0
                    else
                        log('UI', log_levels.ERROR, "Failed to fetch map markers: " .. tostring(err))
                        map_fetch_state.retry_at = os.clock() + 2.0
                    end
                    return
                end
                if data and data.payload then
                    log('UI', log_levels.INFO, "Successfully fetched " .. #data.payload .. " markers.")
                    map_markers = {}
                    map_lines = {}
                    for _, marker in ipairs(data.payload) do
                        if marker.marker_type == 'line' then
                            marker.points_data = json.decode(marker.points_data)
                            table.insert(map_lines, marker)
                        else
                            table.insert(map_markers, marker)
                        end
                    end
                    map_data_loaded = true
                    map_fetch_state.retry_at = 0
                else
                    map_fetch_state.retry_at = os.clock() + 2.0
                end
            end)
        end
        if imgui.Begin("Global Map", UI.map_window) then
            imgui.Text("Loading map data...")
            imgui.End()
        end
        return
    end

    local sw, sh = getScreenResolution()
    local window_width = 820
    local window_height = 840
    imgui.SetNextWindowSize(imgui.new('ImVec2', window_width, window_height), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(imgui.new('ImVec2', (sw - window_width) / 2, (sh - window_height) / 2), imgui.Cond.FirstUseEver)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.new('ImVec2', 0, 0))
    if imgui.Begin("Global Map", UI.map_window, imgui.WindowFlags.NoResize + imgui.WindowFlags.MenuBar) then
        imgui.PopStyleVar()

        if imgui.BeginMenuBar() then
            if imgui.Button("Select") then map_interaction_mode = "pan"; active_line_points = {} end
            if imgui.Button("Place Point") then map_interaction_mode = "point"; active_line_points = {} end
            if imgui.Button("Place Circle") then map_interaction_mode = "circle"; active_line_points = {} end
            if imgui.Button("Draw Line") then map_interaction_mode = "line"; active_line_points = {} end
            imgui.EndMenuBar()
        end

        imgui.BeginChild("MapCanvas", imgui.new('ImVec2', -1, -1), false, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)

        local io = imgui.GetIO()
        local canvas_pos = imgui.GetCursorScreenPos()
        local canvas_size = imgui.GetContentRegionAvail()
        local mouse_pos = imgui.GetMousePos()

        if imgui.IsWindowHovered() then
            if io.MouseWheel ~= 0 then
                local old_zoom = map_zoom
                local new_zoom = map_zoom + io.MouseWheel * 0.1
                map_zoom = math.max(map_min_zoom, math.min(map_max_zoom, new_zoom))
                local mouse_x_in_canvas = mouse_pos.x - canvas_pos.x
                local mouse_y_in_canvas = mouse_pos.y - canvas_pos.y
                map_offset_x = mouse_x_in_canvas - (mouse_x_in_canvas - map_offset_x) * (map_zoom / old_zoom)
                map_offset_y = mouse_y_in_canvas - (mouse_y_in_canvas - map_offset_y) * (map_zoom / old_zoom)
            end
        end

        local map_width_zoomed = 820 * map_zoom
        local map_height_zoomed = 820 * map_zoom
        map_offset_x = math.max(map_offset_x, -(map_width_zoomed - canvas_size.x))
        map_offset_x = math.min(map_offset_x, 0)
        map_offset_y = math.max(map_offset_y, -(map_height_zoomed - canvas_size.y))
        map_offset_y = math.min(map_offset_y, 0)

        local draw_list = imgui.GetWindowDrawList()
        if map_tile_textures and map_tile_textures.standard and #map_tile_textures.standard > 0 then
            for y = 0, 3 do
                for x = 0, 3 do
                    local tile_index = y * 4 + x + 1
                    local texture = map_tile_textures.standard[tile_index]
                    if texture then
                        local tile_size = 205 * map_zoom
                        local tile_x = canvas_pos.x + map_offset_x + x * tile_size
                        local tile_y = canvas_pos.y + map_offset_y + y * tile_size
                        draw_list:AddImage(texture, imgui.new('ImVec2', tile_x, tile_y), imgui.new('ImVec2', tile_x + tile_size, tile_y + tile_size))
                    end
                end
            end
        else
            imgui.Text("Map textures not loaded!")
        end

        local hovered_item = nil
        
        local status_colors = { 
            green = 0xFF228B22,
            orange = 0xFF008CFF, 
            blue = 0xFFFF7F50,   
            red = 0xFF3232CD,
            gray = 0xFF808080    
        }
        local patrol_status_color_map = { status_colors.green, status_colors.orange, status_colors.blue, status_colors.red, status_colors.gray }

        for _, unit in ipairs(data_storage.units) do
            if unit.pos_x and unit.pos_y and unit.is_active then
                local map_x_unzoomed = (unit.pos_x + 3000) / 6000 * (205 * 4)
                local map_y_unzoomed = (-unit.pos_y + 3000) / 6000 * (205 * 4)
                local final_map_x = canvas_pos.x + map_offset_x + map_x_unzoomed * map_zoom
                local final_map_y = canvas_pos.y + map_offset_y + map_y_unzoomed * map_zoom
                
                local status_idx = (tonumber(unit.status) or 4) + 1
                local unit_color = patrol_status_color_map[status_idx] or status_colors.gray

                draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 6, 0xFF000000)
                draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 5, unit_color)

                local status_text = comboBoxData.status[status_idx] or "Unknown"
                local unit_text = unit.unitID or 'N/A'
                local text_color_white = 0xFFFFFFFF
                local text_color_gray = 0xFFBBBBBB
                local outline_color = 0xFF000000

                drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 12, final_map_y - 8), unit_text, text_color_white, outline_color)
                drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 12, final_map_y + 4), status_text, text_color_gray, outline_color)

                local dist_sq = (mouse_pos.x - final_map_x)^2 + (mouse_pos.y - final_map_y)^2
                if dist_sq < (10)^2 then hovered_item = {type = 'unit', data = unit} end
            end
        end

        for _, call in ipairs(data_storage.calls) do
            if call.map_pos then
                local call_map_x_unzoomed = (call.map_pos.x + 3000) / 6000 * (205 * 4)
                local call_map_y_unzoomed = (-call.map_pos.y + 3000) / 6000 * (205 * 4)
                local call_final_map_x = canvas_pos.x + map_offset_x + call_map_x_unzoomed * map_zoom
                local call_final_map_y = canvas_pos.y + map_offset_y + call_map_y_unzoomed * map_zoom

                draw_list:AddRectFilled(imgui.new('ImVec2', call_final_map_x - 5, call_final_map_y - 5), imgui.new('ImVec2', call_final_map_x + 5, call_final_map_y + 5), 0xFF0000FF)
                drawOutlinedText(draw_list, imgui.new('ImVec2', call_final_map_x + 8, call_final_map_y - 6), "#" .. tostring(call.id), 0xFFFFFFFF, 0xFF000000)

                if call.assigned_units and #call.assigned_units > 0 then
                    for _, unitID in ipairs(call.assigned_units) do
                        local unit = findUnitById(unitID)
                        if unit and unit.pos_x and unit.pos_y then
                            local unit_map_x_unzoomed = (unit.pos_x + 3000) / 6000 * (205 * 4)
                            local unit_map_y_unzoomed = (-unit.pos_y + 3000) / 6000 * (205 * 4)
                            local unit_final_map_x = canvas_pos.x + map_offset_x + unit_map_x_unzoomed * map_zoom
                            local unit_final_map_y = canvas_pos.y + map_offset_y + unit_map_y_unzoomed * map_zoom
                            
                            draw_list:AddLine(imgui.new('ImVec2', call_final_map_x, call_final_map_y), imgui.new('ImVec2', unit_final_map_x, unit_final_map_y), 0x90FFFFFF, 1.5)
                        end
                    end
                end
            end
        end

        for _, marker in ipairs(map_markers) do
            if marker and marker.points_data then
                local points = json.decode(marker.points_data)
                if not points or not points[1] then goto continue end
                local map_x_unzoomed = (points[1].x + 3000) / 6000 * (205 * 4)
                local map_y_unzoomed = (-points[1].y + 3000) / 6000 * (205 * 4)
                local final_map_x = canvas_pos.x + map_offset_x + map_x_unzoomed * map_zoom
                local final_map_y = canvas_pos.y + map_offset_y + map_y_unzoomed * map_zoom
                local color = marker.is_permanent == 1 and 0xFF00D8FF or 0xFF00FF00
                if marker.marker_type == 'point' then
                    draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 6, 0xFF000000)
                    draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), 5, color)
                    if marker.label then drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 8, final_map_y - 8), marker.label, 0xFFFFFFFF) end
                elseif marker.marker_type == 'circle' and marker.radius then
                    local radius_on_map = marker.radius / 6000 * (205 * 4) * map_zoom
                    local transparent_color = bit.bor(bit.band(color, 0x00FFFFFF), 0x33000000)
                    draw_list:AddCircleFilled(imgui.new('ImVec2', final_map_x, final_map_y), radius_on_map, transparent_color, 32)
                    draw_list:AddCircle(imgui.new('ImVec2', final_map_x, final_map_y), radius_on_map, color, 32, 2.0)
                    if marker.label then drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 8, final_map_y - 8), marker.label, 0xFFFFFFFF) end
                elseif marker.marker_type == 'call_waypoint' or marker.marker_type == 'dispatch_waypoint' then
                    local call_color = 0xFF0000FF -- Red
                    local outline_color = 0xFF000000 -- Black
                    draw_list:AddRect(imgui.new('ImVec2', final_map_x - 6, final_map_y - 6), imgui.new('ImVec2', final_map_x + 6, final_map_y + 6), outline_color, 0.0, 0, 2.0)
                    draw_list:AddRectFilled(imgui.new('ImVec2', final_map_x - 5, final_map_y - 5), imgui.new('ImVec2', final_map_x + 5, final_map_y + 5), call_color)

                    if marker.label then drawOutlinedText(draw_list, imgui.new('ImVec2', final_map_x + 12, final_map_y - 8), marker.label, 0xFFFFFFFF) end

                    local call_data
                    local incident_data
                    local marker_call_id = get_call_id_from_waypoint_marker(marker)
                    if marker_call_id then
                        if marker.source_type == 'incident_call' then
                            for _, inc in ipairs(data_storage.incidents or {}) do
                                if inc.id == marker_call_id then
                                    incident_data = inc
                                    break
                                end
                            end
                        else
                            for _, call in ipairs(data_storage.calls or {}) do
                                if call.id == marker_call_id then
                                    call_data = call
                                    break
                                end
                            end
                        end
                    end

                    local assigned_units = {}
                    if incident_data then
                        assigned_units = normalize_assigned_units(incident_data.assigned_units)
                    elseif call_data then
                        assigned_units = normalize_assigned_units(call_data.assigned_units)
                    end

                    if assigned_units and #assigned_units > 0 then
                        local marker_world_pos = json.decode(marker.points_data)[1]

                        for _, unitID in ipairs(assigned_units) do
                            local unit_data
                            for _, unit in ipairs(data_storage.units) do
                                if tostring(unit.unitID) == tostring(unitID) then
                                    unit_data = unit
                                    break
                                end
                            end

                            if unit_data and unit_data.pos_x and unit_data.pos_y then
                                local unit_map_x_unzoomed = (unit_data.pos_x + 3000) / 6000 * (205 * 4)
                                local unit_map_y_unzoomed = (-unit_data.pos_y + 3000) / 6000 * (205 * 4)
                                local unit_final_map_x = canvas_pos.x + map_offset_x + unit_map_x_unzoomed * map_zoom
                                local unit_final_map_y = canvas_pos.y + map_offset_y + unit_map_y_unzoomed * map_zoom

                                draw_list:AddLine(imgui.new('ImVec2', final_map_x, final_map_y), imgui.new('ImVec2', unit_final_map_x, unit_final_map_y), 0x900000FF, 1.0)

                                local distance = math.sqrt((unit_data.pos_x - marker_world_pos.x)^2 + (unit_data.pos_y - marker_world_pos.y)^2)
                                local mid_x = (final_map_x + unit_final_map_x) / 2
                                local mid_y = (final_map_y + unit_final_map_y) / 2
                                drawOutlinedText(draw_list, imgui.new('ImVec2', mid_x, mid_y), estimate_eta_label(distance), 0xFFFFFFFF)
                            end
                        end
                    end
                end
                local dist_sq = (mouse_pos.x - final_map_x)^2 + (mouse_pos.y - final_map_y)^2
                if dist_sq < (10)^2 then hovered_item = {type = 'marker', data = marker} end
            end
            ::continue::
        end
        
        for _, line in ipairs(map_lines) do
            if #line.points_data >= 2 then
                for i = 1, #line.points_data - 1 do
                    local p1 = line.points_data[i]
                    local p2 = line.points_data[i+1]
                    local map_x1_unzoomed = (p1.x + 3000) / 6000 * (205 * 4)
                    local map_y1_unzoomed = (-p1.y + 3000) / 6000 * (205 * 4)
                    local final_map_x1 = canvas_pos.x + map_offset_x + map_x1_unzoomed * map_zoom
                    local final_map_y1 = canvas_pos.y + map_offset_y + map_y1_unzoomed * map_zoom
                    local map_x2_unzoomed = (p2.x + 3000) / 6000 * (205 * 4)
                    local map_y2_unzoomed = (-p2.y + 3000) / 6000 * (205 * 4)
                    local final_map_x2 = canvas_pos.x + map_offset_x + map_x2_unzoomed * map_zoom
                    local final_map_y2 = canvas_pos.y + map_offset_y + map_y2_unzoomed * map_zoom
                    draw_list:AddLine(imgui.new('ImVec2', final_map_x1, final_map_y1), imgui.new('ImVec2', final_map_x2, final_map_y2), 0xFF00FF00, 2.0)
                end
            end
        end

        if map_interaction_mode == "line" and #active_line_points > 0 then
            if #active_line_points >= 2 then
                for i = 1, #active_line_points - 1 do
                    local p1 = active_line_points[i]
                    local p2 = active_line_points[i+1]
                    local map_x1_unzoomed = (p1.x + 3000) / 6000 * (205 * 4)
                    local map_y1_unzoomed = (-p1.y + 3000) / 6000 * (205 * 4)
                    local final_map_x1 = canvas_pos.x + map_offset_x + map_x1_unzoomed * map_zoom
                    local final_map_y1 = canvas_pos.y + map_offset_y + map_y1_unzoomed * map_zoom
                    local map_x2_unzoomed = (p2.x + 3000) / 6000 * (205 * 4)
                    local map_y2_unzoomed = (-p2.y + 3000) / 6000 * (205 * 4)
                    local final_map_x2 = canvas_pos.x + map_offset_x + map_x2_unzoomed * map_zoom
                    local final_map_y2 = canvas_pos.y + map_offset_y + map_y2_unzoomed * map_zoom
                    draw_list:AddLine(imgui.new('ImVec2', final_map_x1, final_map_y1), imgui.new('ImVec2', final_map_x2, final_map_y2), 0xFF00FF00, 2.0)
                end
            end
            local last_point = active_line_points[#active_line_points]
            local map_x_unzoomed = (last_point.x + 3000) / 6000 * (205 * 4)
            local map_y_unzoomed = (-last_point.y + 3000) / 6000 * (205 * 4)
            local final_map_x = canvas_pos.x + map_offset_x + map_x_unzoomed * map_zoom
            local final_map_y = canvas_pos.y + map_offset_y + map_y_unzoomed * map_zoom
            draw_list:AddLine(imgui.new('ImVec2', final_map_x, final_map_y), mouse_pos, 0xFF00FF00, 2.0)
        end

        imgui.SetCursorPos(imgui.new('ImVec2', 0, 0))
        imgui.InvisibleButton("MapInteractionLayer", canvas_size)

        if imgui.IsItemActive() and map_interaction_mode == "pan" and imgui.IsMouseDragging(0) then
            map_offset_x = map_offset_x + io.MouseDelta.x
            map_offset_y = map_offset_y + io.MouseDelta.y
        end

        if map_interaction_mode == 'line' then
            if imgui.IsItemHovered() and imgui.IsMouseClicked(1) then
                if #active_line_points >= 2 then
                    send_map_request('add_marker', { marker_type = 'line', points_data = active_line_points, is_permanent = 0 })
                end
                active_line_points = {}
            end
        else
            if imgui.BeginPopupContextItem("MapContextMenu") then
                if not is_context_menu_open then
                    latched_hovered_item = hovered_item
                    is_context_menu_open = true
                end

                if latched_hovered_item then
                    if latched_hovered_item.type == 'marker' then
                        context_marker = latched_hovered_item.data
                        imgui.Text("Edit Marker #" .. tostring(context_marker.id or '?')); imgui.Separator()
                        if imgui.Selectable("Edit...") then
                            safe_copy(marker_edit_buffer.text, context_marker.label or "")
                            marker_edit_buffer.radius[0] = context_marker.radius or 100.0
                            show_marker_edit_modal[0] = true
                        end
                        local toggle_text = context_marker.is_permanent == 1 and "Make Temporary" or "Make Permanent"
                        if imgui.Selectable(toggle_text) then
                            context_marker.is_permanent = 1 - (context_marker.is_permanent or 0)
                            send_map_request('update_marker', context_marker)
                        end
                        if imgui.Selectable("Delete") then
                            send_map_request('remove_marker', { id = context_marker.id })
                        end
                    elseif latched_hovered_item.type == 'unit' then
                        map_context_menu_unit = latched_hovered_item.data
                        imgui.Text("Unit: " .. (map_context_menu_unit.unitID or "N/A")); imgui.Separator()
                        if map_context_menu_unit.pos_x and map_context_menu_unit.pos_y and imgui.Selectable("Copy Coords") then 
                            setClipboardText(string.format("%.2f, %.2f", map_context_menu_unit.pos_x, map_context_menu_unit.pos_y)) 
                        end
                    end
                else
                    if imgui.Selectable("Clear Temporary Markers") then
                        send_map_request('clear_temporary_markers', {})
                    end
                end
                imgui.EndPopup()
            else
                is_context_menu_open = false
                latched_hovered_item = nil
            end
        end

        if imgui.IsItemHovered() and imgui.IsMouseClicked(0) and not is_context_menu_open then
            local world_x, world_y = screenToWorld(mouse_pos.x, mouse_pos.y, canvas_pos)
            if map_interaction_mode == "point" then
                send_map_request('add_marker', { marker_type = 'point', label = 'Marker', points_data = {{x=world_x, y=world_y}}, is_permanent = 0 })
            elseif map_interaction_mode == "circle" then
                send_map_request('add_marker', { marker_type = 'circle', label = 'Area', points_data = {{x=world_x, y=world_y}}, radius = 100.0, is_permanent = 0 })
            elseif map_interaction_mode == "line" then
                table.insert(active_line_points, {x=world_x, y=world_y})
            end
        end

        imgui.EndChild()

    else
        imgui.PopStyleVar()
    end
    imgui.End()
    renderMarkerEditModal()
end

function addNotification(title, message, duration, actions, sound_trigger)
    duration = duration or 15
    table.insert(active_notifications, 1, {
        id = os.clock(),
        title = title,
        message = message,
        expiry_time = os.clock() + duration,
        actions = actions or {}
    })

    local trigger_to_play = resolve_notification_sound_trigger(title, sound_trigger)
    play_interface_trigger(trigger_to_play)

    while #active_notifications > 3 do
        table.remove(active_notifications)
    end
end

trigger_notification_action = function(action_index)
    if not active_notifications or #active_notifications == 0 then
        return false
    end
    local notif = active_notifications[1]
    if not notif.actions or not notif.actions[action_index] then
        return false
    end
    local action = notif.actions[action_index]
    if action and action.callback then
        local ok, err = pcall(action.callback)
        if not ok then
            log('UI', log_levels.ERROR, "Notification action callback failed: " .. tostring(err))
        end
        notif.expiry_time = 0
        return true
    end
    return false
end

function renderNotifications(is_cursor_visible)
    if #active_notifications == 0 then return end

    local sw, sh = getScreenResolution()
    local padding = 15
    local window_width = 380
    local window_height = 140
    local start_x = sw - window_width - padding
    local start_y = padding + 50

    local current_time = os.clock()

    local i = 1
    while i <= #active_notifications do
        if current_time >= active_notifications[i].expiry_time then
            table.remove(active_notifications, i)
        else
            i = i + 1
        end
    end

    for i, notif in ipairs(active_notifications) do
        local window_pos_y = start_y + (i - 1) * (window_height + padding)
        imgui.SetNextWindowPos(imgui.new('ImVec2', start_x, window_pos_y))
        imgui.SetNextWindowSize(imgui.new('ImVec2', window_width, window_height))

        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.1, 0.1, 0.15, 0.95))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 5.0)

        local window_flags = imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoFocusOnAppearing

        if not is_cursor_visible then
            window_flags = window_flags + imgui.WindowFlags.NoMouseInputs
        end
        
        if imgui.Begin("Notification##" .. notif.id, nil, window_flags) then
            imgui.PushFont(fonts[22])
            imgui.TextColored(imgui.ImVec4(1.0, 0.65, 0.0, 1.0), notif.title)
            imgui.PopFont()
            imgui.Separator()

            imgui.TextWrapped(notif.message)
            
            local cursor_y = imgui.GetWindowHeight() - 40
            imgui.SetCursorPosY(cursor_y)
            imgui.Separator()

            if notif.actions and #notif.actions > 0 then
                local num_buttons = #notif.actions
                local button_width = (window_width - (padding * (num_buttons + 1))) / num_buttons
                local button_size = imgui.new('ImVec2', button_width, 25)
                
                for _, action in ipairs(notif.actions) do
                    local key_name = "N/A"
                    if action.bind_id then
                        local bind_keys = get_bind_keys_by_id(action.bind_id)
                        if bind_keys and #bind_keys > 0 then
                            key_name = BinderManager.keysToString(bind_keys)
                        end
                    elseif action.key then
                        key_name = vkeys.tostring and vkeys.tostring(action.key) or "N/A"
                        key_name = key_name:gsub("VK_", "")
                    end
                    
                    if imgui.Button(string.format("%s [%s]", action.label, key_name), button_size) then
                        if is_cursor_visible then
                            local ok, err = pcall(action.callback)
                            if not ok then
                                log('UI', log_levels.ERROR, "Notification action callback failed: " .. tostring(err))
                            end
                            notif.expiry_time = 0 
                        end
                    end

                    if action.key and imgui.IsKeyPressed(action.key, false) then
                        local ok, err = pcall(action.callback)
                        if not ok then
                            log('UI', log_levels.ERROR, "Notification action callback failed: " .. tostring(err))
                        end
                        notif.expiry_time = 0
                    end
                    imgui.SameLine()
                end
            end
        end
        imgui.End()

        imgui.PopStyleColor()
        imgui.PopStyleVar()
    end
end

imgui.OnFrame(
    function()
        return true
    end,
    function(self)
        if autoupdate and autoupdate.draw_window then
            autoupdate.draw_window()
        end
        
        BinderManager.checkHotkeys()
        cleanup_stale_request_callbacks()

        if not interface_sounds_initialized then
            local now = os.clock()
            if now >= interface_sounds_bootstrap_next_ts then
                ensure_interface_sounds_loaded(true)
                interface_sounds_bootstrap_next_ts = now + 2.0
            end
        end

        if core and core.isAuthenticated and core.isAuthenticated() and alpr_passive_scan_enabled and not UI.alpr_window[0] then
            if cadui_module.isPlayerInPatrolCar() then
                local now_ms = os.clock() * 1000
                if now_ms - last_alpr_scan_time > 1000 then
                    updateALPRData()
                    last_alpr_scan_time = now_ms
                end
            else
                alpr_passive_hud_until = 0
            end
        end

        local passive_alpr_hud_visible = should_render_passive_alpr_hud()
        local should_draw_windows = #active_notifications > 0 or UI.mdt[0] or UI.login_window[0] or UI.alpr_window[0] or passive_alpr_hud_visible or UI.alpr_log_window[0] or UI.bolo_editor[0] or UI.bolo_creator_window[0] or UI.map_window[0] or (UI.unit_mini_hud[0] and core and core.isAuthenticated and core.isAuthenticated())

        if UI.mdt[0] then
            BinderManager.handleKeyBindingInput()
        end

        local now_clock = os.clock()

        if pending_checkpoint_source and source_uses_checkpoint(pending_checkpoint_source.source_type) and (now_clock - checkpoint_tracker.pending_started_at) > 20 then
            log('UI', log_levels.WARN, 'Checkpoint interception timeout for source: ' .. tostring(pending_checkpoint_source.dedupe_key))
            pending_checkpoint_source = nil
        end

        if pending_checkpoint_source and source_uses_checkpoint(pending_checkpoint_source.source_type) then
            local active, x, y, z = get_active_checkpoint_xyz()
            if active then
                local source = pending_checkpoint_source
                pending_checkpoint_source = nil
                log('UI', log_levels.INFO, string.format('Polled active checkpoint at %.2f, %.2f, %.2f for %s', x, y, z, tostring(source.dedupe_key)))
                try_sync_dispatch_checkpoint(x, y, z, source)
            end
        end

        if checkpoint_tracker.dedupe_key and source_uses_checkpoint(checkpoint_tracker.source_type) then
            if now_clock - checkpoint_tracker.last_sync >= 2.0 then
                local active, x, y, z = get_active_checkpoint_xyz()
                checkpoint_tracker.last_sync = now_clock
                if active then
                    checkpoint_tracker.last_checkpoint_seen_at = now_clock
                    local should_sync = true
                    if checkpoint_tracker.last_pos then
                        local dx = (x or 0) - (checkpoint_tracker.last_pos.x or 0)
                        local dy = (y or 0) - (checkpoint_tracker.last_pos.y or 0)
                        local dist = math.sqrt(dx * dx + dy * dy)
                        should_sync = dist >= 8.0
                    end

                    if should_sync then
                        try_sync_dispatch_checkpoint(x, y, z, {
                            source_type = checkpoint_tracker.source_type,
                            source_id = checkpoint_tracker.source_id,
                            dedupe_key = checkpoint_tracker.dedupe_key,
                            label = checkpoint_tracker.call_id and ('Call #' .. tostring(checkpoint_tracker.call_id)) or nil
                        })
                    end
                end
            end
        end

        local other_windows_active = UI.mdt[0] or UI.login_window[0] or UI.alpr_log_window[0] or UI.bolo_editor[0] or UI.bolo_creator_window[0] or UI.map_window[0]
        local show_cursor = other_windows_active or (UI.alpr_window[0] and alpr_interaction_mode) or (key_being_bound ~= nil)
        
        self.HideCursor = not show_cursor
        if sampShowCursor and type(sampShowCursor) == 'function' then
            sampShowCursor(show_cursor)
        end

        if not should_draw_windows then
            return
        end
        if fonts[18] then imgui.PushFont(fonts[18]) end

        if UI.mdt[0] then
            renderMDTWindow()
        end
        if UI.login_window[0] then
            renderLoginWindow()
        end        
        if UI.alpr_window[0] or passive_alpr_hud_visible then
            renderALPRHud()
        end
        if UI.alpr_manager[0] then
            renderALPRManager()
        end
        if UI.alpr_log_window[0] then
            renderALPRLogWindow()
        end
        if UI.bolo_editor[0] then
            drawBoloEditor()
        end
        if UI.bolo_creator_window[0] then
            drawBoloCreatorWindow()
        end
        if UI.map_window[0] then
            renderMapWindow()
        end
        if UI.unit_mini_hud[0] and core and core.isAuthenticated and core.isAuthenticated() then
            renderUnitMiniHud()
        end
        renderSimplexUnitSelector()
        renderNotifications(show_cursor)
        if fonts[18] then imgui.PopFont() end
    end
)
function addWantedPlate(plate)
    if not plate or plate == "" then return end
    send_ws_request('data', 'add_wanted_plate', { plate = plate }, function(data, err) 
        if err then addUnitLogEntry("ERROR", "Failed to add wanted plate: " .. err) return end
        addUnitLogEntry("SYSTEM", "Added plate to wanted list: " .. plate)
        forceDataRefresh()
        safe_copy(new_wanted_plate_buffer, "")
    end)
end

function removeWantedPlate(id)
    if not id then return end
    send_ws_request('data', 'remove_wanted_plate', { id = id }, function(data, err) 
        if err then addUnitLogEntry("ERROR", "Failed to remove wanted plate: " .. err) return end
        addUnitLogEntry("SYSTEM", "Removed plate from wanted list.")
        forceDataRefresh()
    end)
end

function updateCallStatus(call_id, action, unit_id)
    log('UI', log_levels.INFO, string.format("Attempting to %s call %s for unit %s", action, call_id, unit_id))
    local payload = {
        call_id = call_id,
        unit_id = unit_id
    }
    send_ws_request('calls', action, payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to update call status: " .. tostring(err))
            addUnitLogEntry("ERROR", "Failed to update call status: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Call status updated successfully. Refreshing data.")
            if action == 'clear' and call_id then
                send_map_request('close_dispatch_marker', { dedupe_key = "dispatch:call_911:" .. tostring(call_id) })
                if checkpoint_tracker.dedupe_key == ("dispatch:call_911:" .. tostring(call_id)) then
                    clear_checkpoint_tracker()
                end
                revertToBaseRadioSlot()
            end
            forceDataRefresh()
        end
    end)
end

function addCallLogEntry(call_id, note_text)
    log('UI', log_levels.INFO, string.format("Attempting to add note to call %s", call_id))
    local payload = {
        call_id = call_id,
        note = note_text,
        unit_id = safe_str(unitInfoBuffers.unitID)
    }
    send_ws_request('calls', 'add_note', payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to add call note: " .. tostring(err))
            addUnitLogEntry("ERROR", "Failed to add call note: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Successfully added call note. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function addBoloNote(bolo_id, note_text)
    log('UI', log_levels.INFO, string.format("Attempting to add note to BOLO %s", bolo_id))
    local payload = {
        bolo_id = bolo_id,
        note = note_text,
        unit_id = safe_str(unitInfoBuffers.unitID)
    }
    send_ws_request('bolos', 'add_note', payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to add BOLO note: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Successfully added BOLO note. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function updateBoloStatus(bolo_id, status)
    log('UI', log_levels.INFO, string.format("Attempting to update BOLO %s status to %s", bolo_id, status))
    local payload = {
        bolo_id = bolo_id,
        status = status,
        unit_id = safe_str(unitInfoBuffers.unitID)
    }
    send_ws_request('bolos', 'update_status', payload, function(data, err) 
        if err then
            log('UI', log_levels.ERROR, "Failed to update BOLO status: " .. tostring(err))
        else
            log('UI', log_levels.INFO, "Successfully updated BOLO status. Refreshing data.")
            forceDataRefresh()
        end
    end)
end

function broadcastUnitStatus(extra_params)
    extra_params = extra_params or {}
    updateCurrentLocation()
    local payload = {
        unitID = safe_str(unitInfoBuffers.unitID),
        unitType = unitInfoBuffers.unitType[0],
        officer1_name = safe_str(unitInfoBuffers.officer1_name),
        officer2_name = safe_str(unitInfoBuffers.officer2_name),
        status = unitInfoBuffers.status[0],
        vehiclePlate = safe_str(unitInfoBuffers.vehiclePlate),
        division = unitInfoBuffers.division[0],
        base_radio_slot = unitInfoBuffers.base_radio_slot[0],
        notes = safe_str(unitInfoBuffers.notes),
        location = currentLocation,
        current_channel_id = tonumber(UI.unit_mini_hud_last_slot),
        is_active = (unitInfoBuffers.status[0] ~= 4),
        vehicleId = assigned_vehicle_id,
        ar15 = vehicleEquipment.ar15[0],
        ll40mm = vehicleEquipment.ll40mm[0],
        beanbag = vehicleEquipment.beanbag[0],
        riot_shield = vehicleEquipment.riot_shield[0],
        spikes = vehicleEquipment.spikes[0],
        narcan = vehicleEquipment.narcan[0],
        pit_auth = vehicleEquipment.pit_auth[0],
        aed = vehicleEquipment.aed[0],
        user_id = core.current_user and core.current_user.id or nil
        
    }
    for k, v in pairs(extra_params) do payload[k] = v end

    local action = 'form_or_update_crew'

    log('UI', log_levels.INFO, "--- BROADCASTING UNIT STATUS ---")
    log('UI', log_levels.INFO, "Action: " .. action)
    log('UI', log_levels.INFO, "Payload: " .. json.encode(payload))

    send_ws_request('unit', action, payload, function(data, err) 
        if err then
            addUnitLogEntry("ERROR", "Failed to broadcast unit status: " .. err)
        elseif data and data.success and data.payload then
            log('UI', log_levels.INFO, "Unit status broadcast successful, payload received.")
            events.trigger('cad:unit_updated', data.payload)
        end
    end)
end

function addUnitLogEntry(event_type, details)
    if not unitActivityLog or type(unitActivityLog) ~= "table" then unitActivityLog = {} end

    local allowed_unit_log_types = { ["STATUS"] = true, ["CALL"] = true, ["ERROR"] = true, ["OFFICER"] = true, ["ALPR"] = true, ["REQUEST"] = true, ["VEHICLE"] = true }
    
    if not allowed_unit_log_types[event_type] then return end
    
    local entry = { time = os.date("%H:%M:%S"), event = event_type, details = details }

    table.insert(unitActivityLog, 1, entry)
    if #unitActivityLog > 50 then table.remove(unitActivityLog, #unitActivityLog) end
end

function setUnitActiveStatus(isActive)
    local status_code = isActive and 0 or 4
    unitInfoBuffers.status[0] = status_code
    local log_message = isActive and "Unit is now ON DUTY" or "Unit is now OFF DUTY"
    addUnitLogEntry("STATUS", log_message)
    broadcastUnitStatus({ is_active = isActive and 'true' or 'false' })
    
    if isActive then
        revertToBaseRadioSlot()
    end
end



function validateTokenOnStartup()
    log('UI', log_levels.DEBUG, 'validateTokenOnStartup: Starting token validation.')
    if not token or token == "" then
        log('UI', log_levels.DEBUG, 'validateTokenOnStartup: No token found. Waiting for user login.')
        return
    end

    copas.addthread(function()
        log('UI', log_levels.DEBUG, 'validateTokenOnStartup: Thread created, validating stored token.')
        local params = { action = "validateToken", token = token }
        local data, err = copas.await(copas.http.request{ url = get_server_url(), params = params, method = "GET" })

        if data and data.success then
            log('UI', log_levels.INFO, 'validateTokenOnStartup: Token is valid. Pre-loading data.')
            onSuccessfulLogin()
        else
            log('UI', log_levels.WARN, 'validateTokenOnStartup: Stored token is invalid. Clearing token.')
            token = ""
            settings.set("user_settings", "token", "")
            settings.save()
        end
    end)
end

cadui_module.shutdown = function()
    log('UI', log_levels.INFO, 'Shutting down UI background threads.')
    threads_started = false
end

cadui_module.toggleMDT = function()
    if not core.isAuthenticated() then
        log('UI', log_levels.INFO, "MDT toggled but user not coreenticated. Showing login window.")
        UI.login_window[0] = not UI.login_window[0]
        return
    end
    UI.mdt[0] = not UI.mdt[0]
    log('UI', log_levels.INFO, "MDT window toggled " .. (UI.mdt[0] and "ON" or "OFF"))
    if UI.mdt[0] then
        forceDataRefresh()
    end
end

local original_sampSendChat = sampSendChat
function sampSendChat(msg)
    if msg then
        local slotNum = msg:match("^/slot%s+(%d+)")
        if slotNum then
            events.trigger('radio:local_channel_changed', tonumber(slotNum))
        end
    end
    original_sampSendChat(msg)
end

cadui_module.initialize = function(deps)
    events = deps.events
    core = deps.core
    cad_websocket = deps.websocket
    json = deps.json
    settings = deps.settings
    copas = deps.copas
    log = deps.log
    log_levels = deps.log_levels
    safe_str = deps.safe_str
    cars = deps.cars
    safe_copy = deps.safe_copy
    autoupdate = deps.autoupdate


    if settings then
        local subs = settings.get('radio_settings', 'subscriptions', {true, true, true, true})
        
        for i=1, 4 do
            if subs[i] ~= nil then
                radio_subscription_state[i] = subs[i]
            else
                radio_subscription_state[i] = true
            end
        end

        alpr_camera_config.front[0] = settings.get('alpr_settings', 'cam_front', true)
        alpr_camera_config.rear[0] = settings.get('alpr_settings', 'cam_rear', true)
        alpr_camera_config.sides[0] = settings.get('alpr_settings', 'cam_sides', true)
        alpr_passive_scan_enabled = settings.get('alpr_settings', 'passive_scan', true)
        UI.unit_mini_hud[0] = settings.get('ui_settings', 'unit_mini_hud', true)
        UI.unit_mini_hud_last_slot = tonumber(settings.get('ui_settings', 'last_slot_used', 1)) or 1
        UI.unit_mini_hud_pos_x = tonumber(settings.get('ui_settings', 'unit_mini_hud_pos_x', UI.unit_mini_hud_pos_x)) or UI.unit_mini_hud_pos_x
        UI.unit_mini_hud_pos_y = tonumber(settings.get('ui_settings', 'unit_mini_hud_pos_y', UI.unit_mini_hud_pos_y)) or UI.unit_mini_hud_pos_y
        local stored_lspd_assignments = settings.get('ui_settings', 'lspd_call_assignments', {})
        if type(stored_lspd_assignments) == "table" then
            cadui_module.lspd_call_assignments_store = stored_lspd_assignments
        else
            cadui_module.lspd_call_assignments_store = {}
        end
    end

    radioConfig = {
        userCallsign = "Unknown",
        notificationsEnabled = settings.get("radio_settings", "notifications", true),
        chatEnabled = false,
        radioVolume = settings.get("radio_settings", "volume", 0.5),
        logStatusChanges = settings.get("log_settings", "status_changes", true),
        logDataChanges = settings.get("log_settings", "data_changes", true),
        logAllEvents = settings.get("log_settings", "all_events", false)
    }

    local saved_username = settings.get("user_settings", "username", "")
    if saved_username ~= "" then
        ffi.copy(core.login_window.username, saved_username)
    end

    events.register('core_ui:message', handle_websocket_message)
    events.register('ui:show_notification', function(payload)
        if payload and payload.title and payload.message then
            log('UI', log_levels.INFO, 'Received ui:show_notification event. Displaying notification.')
            addNotification(payload.title, payload.message, payload.duration or 10, payload.actions, payload.sound_trigger)
        end
    end)

    events.register('cad:assist_request', function(incident)
        log('UI', log_levels.INFO, "Received assist_request event for incident #" .. tostring(incident.id))
        
        local message = string.format("Unit: %s\nLocation: %s\nChannel: 912.%s",
            tostring(incident.primary_unit_id or "N/A"),
            tostring(incident.location or "N/A"),
            tostring(incident.tactical_channel or "N/A")
        )
        
        local actions = {
            {
                label = "Accept",
                bind_id = "popup_accept",
                callback = function()
                    send_ws_request('tactical', 'accept_assist', { incident_id = incident.id })
                    optimistic_accept_assist(incident.id)
                    cadui_module.touchIncidentWaypoint(incident.id, 'assist_request_accept')
                    if incident.tactical_channel then
                        setRadioChannel(incident.tactical_channel)
                        addUnitLogEntry("INCIDENT", "Accepted assist for incident #" .. incident.id .. " and switched to channel " .. incident.tactical_channel)
                    else
                        addUnitLogEntry("INCIDENT", "Accepted assist for incident #" .. incident.id .. " (no channel specified).")
                    end
                    
                    unitInfoBuffers.status[0] = 1 
                    broadcastUnitStatus()
                    addUnitLogEntry("STATUS", "Status auto-set to ENROUTE for incident #" .. tostring(incident.id))
                end
            },
            {
                label = "Decline",
                bind_id = "popup_decline",
                callback = function()
                    addUnitLogEntry("INCIDENT", "Declined assist for incident #" .. incident.id .. " via notification.")
                end
            }
        }
        
        addNotification("ASSISTANCE REQUEST", message, 20, actions, "assist_request")
    end)

    events.register('cad:simplex_request', function(data)
        log('UI', log_levels.INFO, "Received simplex_request event")
        
        local message = string.format("Unit %s invites you to a private simplex channel.\nChannel: 912.%s",
            tostring(data.requestingUnitName or "N/A"),
            tostring(data.channel or "N/A")
        )
        
        local actions = {
            {
                label = "Accept",
                bind_id = "popup_accept",
                callback = function()
                    send_ws_request('tactical', 'accept_simplex', { 
                        requester_user_id = data.requestingUserId, 
                        channel = data.channel 
                    })
                end
            },
            {
                label = "Decline",
                bind_id = "popup_decline",
                callback = function()
                    send_ws_request('tactical', 'decline_simplex', {
                        requester_user_id = data.requestingUserId,
                        channel = data.channel
                    })
                end
            }
        }
        
        addNotification("SIMPLEX REQUEST", message, 30, actions, "simplex_request")
    end)

    events.register('cad:lspd_call_assign', function(payload)
        if type(payload) ~= "table" then return end
        local call_id = payload.call_id or payload.server_call_id or payload.callNumber
        if not call_id then return end
        local label = "LSPD"

        local applied_now = cadui_module.addLspdAssignedUnitToCall(call_id, label)
        if applied_now then
            addUnitLogEntry("CALL", string.format("Added external assignee '%s' to call #%s.", label, tostring(call_id)))
        else
            addUnitLogEntry("CALL", string.format("Queued external assignee '%s' for call #%s (waiting call sync).", label, tostring(call_id)))
        end
    end)
    
    events.register('auth_login_success', function()
        log('UI', log_levels.INFO, "Login success event received. User is authenticated.")
        UI.login_window[0] = false
        is_first_unit_update_after_login = true

        if core and core.current_user and core.current_user.full_name then
            fill_full_name_buffers(core.current_user.full_name)
        end
        
        if core and core.fetchUnitData then
            core.fetchUnitData()
        end

        forceDataRefresh()
        startBackgroundThreads()
    end)

    events.register('core_logout', function()
        log('UI', log_levels.INFO, "Logout event received. Closing MDT and stopping threads.")
        threads_started = false
        UI.mdt[0] = false
        UI.login_window[0] = true
    end)
    
    events.register('cad:data_refreshed', function(payload)
        log('UI', log_levels.INFO, 'cad:data_refreshed event received. Updating data_storage.')
        
        if payload.calls then
            if type(payload.calls) == "table" then
                local new_calls_count = 0
                for i, call in ipairs(payload.calls) do
                    if type(call.description) == "string" then
                        local ok, decoded = pcall(json.decode, call.description)
                        if ok then 
                            payload.calls[i].description = decoded 
                        else
                            payload.calls[i].description = {}
                        end
                    end
                    if type(call.event_log) == "string" then
                        local ok, decoded = pcall(json.decode, call.event_log)
                        if ok then 
                            payload.calls[i].event_log = decoded 
                        else
                            payload.calls[i].event_log = {}
                        end
                    end

                    local units = call.assigned_units
                    if type(units) == 'string' then
                        local ok, decoded = pcall(json.decode, units)
                        units = ok and decoded or { units }
                    elseif type(units) == 'number' then
                        units = { tostring(units) }
                    elseif type(units) ~= 'table' then
                        units = {}
                    end
                    payload.calls[i].assigned_units = units
                end

                local incoming_call_ids = make_call_ids_snapshot(payload.calls)
                if calls_snapshot_ready then
                    for call_id, _ in pairs(incoming_call_ids) do
                        if not known_call_ids[call_id] then
                            new_calls_count = new_calls_count + 1
                        end
                    end
                end

                known_call_ids = incoming_call_ids
                if not calls_snapshot_ready then
                    calls_snapshot_ready = true
                elseif new_calls_count > 0 then
                    log('UI', log_levels.INFO, "Detected " .. tostring(new_calls_count) .. " new 911 call(s). Playing call_created sound.")
                    play_interface_trigger("call_created")
                end

                if checkpoint_tracker.source_type == 'call_911' and checkpoint_tracker.call_id then
                    for _, call in ipairs(payload.calls) do
                        if tonumber(call.id) == tonumber(checkpoint_tracker.call_id) and is_call_resolved_status(call.status) then
                            send_map_request('close_dispatch_marker', { dedupe_key = "dispatch:call_911:" .. tostring(checkpoint_tracker.call_id) })
                            clear_checkpoint_tracker()
                            break
                        end
                    end
                end
            end
            data_storage.calls = payload.calls
            cadui_module.applyPendingLspdAssignments()
        end

        if payload.bolos then
            if type(payload.bolos) == "table" then
                for i, bolo in ipairs(payload.bolos) do
                    if type(bolo.event_log) == "string" then
                        local ok, decoded = pcall(json.decode, bolo.event_log)
                        if ok then payload.bolos[i].event_log = decoded 
                        else payload.bolos[i].event_log = {} end
                    elseif type(bolo.event_log) ~= 'table' then
                        payload.bolos[i].event_log = {}
                    end
                end
            end
            data_storage.bolos = payload.bolos
        end

        if payload.units then
            data_storage.units = payload.units
            if core and core.current_user then
                for _, unit in ipairs(data_storage.units) do
                    if is_unit_for_current_user(unit) then
                        core.current_unit = unit 
                        events.trigger('cad:unit_updated', unit)
                        break
                    end
                end
            end
        end

        local wp = payload.wanted_plates
        local wp_key = "wanted_plates"
        if not wp then
            wp = payload.wantedPlates
            wp_key = "wantedPlates"
        end
        if not wp then
            wp = payload.wantedplates
            wp_key = "wantedplates"
        end
        if not wp then
            wp = payload.wanted_plates_list
            wp_key = "wanted_plates_list"
        end
        if not wp then
            wp = payload.wantedPlatesList
            wp_key = "wantedPlatesList"
        end
        if wp then
            data_storage.wanted_plates = wp
            wanted_plates_list = as_array(data_storage.wanted_plates)
        else
        end

        if payload.incidents then
            if type(payload.incidents) == "table" then
                for i, incident in ipairs(payload.incidents) do
                    if type(incident.assigned_units) == "string" then
                        local ok, decoded = pcall(json.decode, incident.assigned_units)
                        if ok then payload.incidents[i].assigned_units = decoded else payload.incidents[i].assigned_units = {} end
                    end
                    if type(incident.event_log) == "string" then
                        local ok, decoded = pcall(json.decode, incident.event_log)
                        if ok then payload.incidents[i].event_log = decoded else payload.incidents[i].event_log = {} end
                    end
                end
            end
            data_storage.incidents = payload.incidents or {}
        else
            data_storage.incidents = {}
        end

        log('UI', log_levels.INFO, string.format('Data storage updated. Calls: %d, BOLOs: %d, Units: %d', #(data_storage.calls or {}), #(data_storage.bolos or {}), #(data_storage.units or {})))
    end)

    events.register('radio:sync_state', function(server_channels)
        for i, channel in ipairs(fixed_radio_channels) do
            if server_channels[channel.id] ~= nil then
                radio_subscription_state[i] = server_channels[channel.id]
            end
        end
    end)

    events.register('websocket_message', function(msg)
        if msg.type == 'auth_response' and msg.success then
            if msg.user and msg.user.subscriptions then
                local subs = msg.user.subscriptions
                print("CAD UI: Получены подписки от сервера: " .. table.concat(subs, ", "))
                
                events.trigger('radio:set_batch_state', subs)
            else
                events.trigger('radio:set_batch_state', {})
            end
        end
    end)

    if sampRegisterChatCommand then
        sampRegisterChatCommand("cadsound", function(arg)
            local input = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if input == "" then
                addNotification("SOUND TEST", "Usage: /cadsound <sound_id> or /cadsound tr:<trigger_id>", 6)
                return
            end
            local ok = false
            if input:sub(1, 3) == "tr:" then
                ok = play_interface_trigger(input:sub(4))
            else
                ok = play_interface_sound(input)
            end
            if ok then
                addNotification("SOUND TEST", "Played: " .. input, 4)
            else
                addNotification("SOUND TEST", "Failed to play: " .. input, 6)
            end
        end)

        sampRegisterChatCommand("ps", function(arg)
            local input = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
            if not core or not core.isAuthenticated or not core.isAuthenticated() then
                if sampAddChatMessage then
                end
                return
            end

            if input == "10-8" or input == "108" or input == "clear" or input == "available" then
                setUnitActiveStatus(true)
                if sampAddChatMessage then
                end
            elseif input == "enroute" or input == "10-97" or input == "1097" then
                unitInfoBuffers.status[0] = 1
                broadcastUnitStatus()
                addUnitLogEntry("STATUS", "En Route")
                if sampAddChatMessage then
                end
            elseif input == "c6" or input == "code6" or input == "code-6" or input == "onscene" then
                unitInfoBuffers.status[0] = 2
                broadcastUnitStatus()
                addUnitLogEntry("STATUS", "Code 6 (On Scene)")
                if sampAddChatMessage then
                end
            elseif input == "10-6" or input == "106" or input == "busy" then
                unitInfoBuffers.status[0] = 3
                broadcastUnitStatus()
                addUnitLogEntry("STATUS", "Busy")
                if sampAddChatMessage then
                end
            elseif input == "10-7" or input == "107" or input == "out" or input == "offduty" or input == "oos" then
                setUnitActiveStatus(false)
                if sampAddChatMessage then
                end
            else
                if sampAddChatMessage then
                end
            end
        end)

        if autoupdate and autoupdate.register_commands then
            autoupdate.register_commands()
        end

    end

    events.trigger('radio:ui_request_sync')

    events.register('cad:unit_updated', function(unit_data)
        if not unit_data or isEditingUnitInfo then return end
        if unitInfoBuffers and unitInfoBuffers.status and unitInfoBuffers.status[0] == 4 then
            local incoming_status = tonumber(unit_data.status)
            if incoming_status and incoming_status ~= 4 then
                unitInfoBuffers.status[0] = incoming_status
                log('UI', log_levels.INFO, 'cad:unit_updated: applied incoming status while Out of Service: ' .. tostring(incoming_status))
            else
                log('UI', log_levels.INFO, 'cad:unit_updated skipped: local status is Out of Service.')
            end
            return
        end
        if core and core.current_unit then
            local server_channel = tonumber(core.current_unit.current_channel_id)
            if server_channel and server_channel > 0 then
                UI.unit_mini_hud_last_slot = server_channel
            end
        end
        log('UI', log_levels.INFO, 'cad:unit_updated event received. Syncing UI buffers.')
        safe_copy(unitInfoBuffers.unitID, unit_data.unitID or "")
        unitInfoBuffers.unitType[0] = unit_data.unitType or 0
        safe_copy(unitInfoBuffers.officer1_name, unit_data.officer1_name or "")
        safe_copy(unitInfoBuffers.officer2_name, unit_data.officer2_name or "")
        safe_copy(unitInfoBuffers.officer1_phone, unit_data.officer1_phone or "")
        safe_copy(unitInfoBuffers.officer2_phone, unit_data.officer2_phone or "")
        unitInfoBuffers.status[0] = unit_data.status or 4
        safe_copy(unitInfoBuffers.vehiclePlate, unit_data.vehiclePlate or "")
        unitInfoBuffers.division[0] = unit_data.division or 0
        if unit_data.base_radio_slot and tonumber(unit_data.base_radio_slot) > 0 then
            unitInfoBuffers.base_radio_slot[0] = tonumber(unit_data.base_radio_slot)
        end
        safe_copy(unitInfoBuffers.notes, unit_data.notes or "")
        local function to_bool(val) return (val == 1 or val == true) end

        vehicleEquipment.ar15[0] = to_bool(unit_data.ar15)
        vehicleEquipment.ll40mm[0] = to_bool(unit_data.ll40mm)
        vehicleEquipment.beanbag[0] = to_bool(unit_data.beanbag)
        vehicleEquipment.riot_shield[0] = to_bool(unit_data.riot_shield)
        vehicleEquipment.spikes[0] = to_bool(unit_data.spikes)
        vehicleEquipment.narcan[0] = to_bool(unit_data.narcan)
        vehicleEquipment.pit_auth[0] = to_bool(unit_data.pit_auth)
        vehicleEquipment.aed[0] = to_bool(unit_data.aed)
        assigned_vehicle_id = unit_data.vehicleId or nil

        if is_first_unit_update_after_login then
            log('UI', log_levels.INFO, 'First unit update after login. Broadcasting status.')
            broadcastUnitStatus()
            is_first_unit_update_after_login = false
        end
    end)

    

    

    divisionOptions_c = imgui.new['const char*'][#comboBoxData.division](comboBoxData.division)
    unitTypeOptions_c = imgui.new['const char*'][#comboBoxData.unitType](comboBoxData.unitType)
    shiftOptions_c = imgui.new['const char*'][#comboBoxData.shift](comboBoxData.shift)
    
    boloTypes_c = imgui.new['const char*'][#boloTypes](boloTypes)

    events.register('auth:discord_verified', function(data)
        discord_auth.is_loading = false
        discord_auth.discord_id = data.discord_id
        discord_auth.avatar_url = data.avatar_url
        discord_auth.state = 'selection'
        core.fetchCharacters(data.discord_id)
    end)

    events.register('auth:characters_list', function(characters)
        discord_auth.characters = characters
    end)

    events.register('auth:character_created', function()
        discord_auth.state = 'selection'
        core.fetchCharacters(discord_auth.discord_id)
    end)

    events.register('auth:discord_error', function(err)
        discord_auth.is_loading = false
        discord_auth.error_message = err
        registration_buffers.error = err
    end)

    events.register('radio:local_channel_changed', function(channel)
        if channel and tonumber(channel) then
            UI.unit_mini_hud_last_slot = tonumber(channel)
            log('UI', log_levels.DEBUG, 'Radio slot synced from external source: ' .. tostring(channel))
        end
    end)

    log('UI', log_levels.INFO, "Module initialized.")
end

cadui_module.checkHotkeys = BinderManager.checkHotkeys
cadui_module.playSound = play_interface_sound
cadui_module.playSoundTrigger = play_interface_trigger
cadui_module.soundRegistry = interface_sound_files
cadui_module.soundTriggers = interface_sound_triggers

return cadui_module
