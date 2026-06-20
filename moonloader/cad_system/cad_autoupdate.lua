
local M = {}
local json = require('dkjson')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local ok_lfs, lfs = pcall(require, 'lfs')
local ok_imgui, imgui = pcall(require, 'mimgui')

local CFG = {
  gh_owner  = "badtotheboneh",
  gh_repo   = "cad-system",
  gh_branch = "main",
}
CFG.version_url = ("https://raw.githubusercontent.com/%s/%s/%s/version.json"):format(
  CFG.gh_owner, CFG.gh_repo, CFG.gh_branch)
CFG.raw_base = ("https://raw.githubusercontent.com/%s/%s/%s/moonloader/"):format(
  CFG.gh_owner, CFG.gh_repo, CFG.gh_branch)
CFG.repo_url = ("https://github.com/%s/%s"):format(CFG.gh_owner, CFG.gh_repo)

local DL_POLL_MS      = 250
local DL_STABLE_TICKS = 3
local DL_TIMEOUT_FILE = 30
local DL_TIMEOUT_META = 15

local anim_alpha      = 0.0
local anim_from       = 0.0
local anim_to         = 0.0
local anim_running    = false
local anim_start_time = 0.0

M.version = "1.0.0"
local upd = {
  available = false,
  required  = false,
  latest    = nil,
  changelog = nil,
  url       = nil,
  busy      = false,
  status    = nil,
}

local ui_state = {
  show_window  = false,
  anim_closing = false,
  p_open       = imgui.new.bool(true),
  log_lines    = {},
  max_logs     = 100,
  progress     = 0,
  progress_text= "",
  current_file = "",
  failed_files = {},
}

local ffi_cache = {
  win_padding = imgui.new('ImVec2', 16, 14),
  item_spacing = imgui.new('ImVec2', 8, 7),
  progress_size = imgui.new('ImVec2', 0, 6),
  
  col_win_bg = imgui.new('ImVec4', 0.09, 0.09, 0.11, 0.97),
  col_title_bg = imgui.new('ImVec4', 0.09, 0.09, 0.11, 1.00),
  col_border = imgui.new('ImVec4', 0.20, 0.20, 0.24, 1.00),
  
  btn_primary = { imgui.new('ImVec4', 0.18, 0.56, 0.18, 1.00), imgui.new('ImVec4', 0.24, 0.70, 0.24, 1.00), imgui.new('ImVec4', 0.14, 0.44, 0.14, 1.00) },
  btn_secondary = { imgui.new('ImVec4', 0.20, 0.20, 0.23, 1.00), imgui.new('ImVec4', 0.28, 0.28, 0.32, 1.00), imgui.new('ImVec4', 0.15, 0.15, 0.18, 1.00) },
  btn_danger = { imgui.new('ImVec4', 0.55, 0.18, 0.12, 1.00), imgui.new('ImVec4', 0.72, 0.22, 0.14, 1.00), imgui.new('ImVec4', 0.42, 0.14, 0.10, 1.00) },
  
  col_progress_hist = imgui.new('ImVec4', 0.22, 0.70, 0.22, 1.00),
  col_progress_bg = imgui.new('ImVec4', 0.16, 0.16, 0.19, 1.00),
  
  win_title = u8"  CAD Update Manager"
}

local function ui_add_log(msg)
  local timestamp = os.date("%H:%M:%S")
  table.insert(ui_state.log_lines, 1, "[" .. timestamp .. "] " .. msg)
  if #ui_state.log_lines > ui_state.max_logs then
    table.remove(ui_state.log_lines)
  end
end

local log_fn = function(msg)
  print("[CAD-UPDATE] " .. msg)
  ui_add_log(msg)
end
M.set_logger = function(fn) log_fn = fn end

local function chat_msg(msg)
  if type(sampAddChatMessage) == 'function' then
    sampAddChatMessage("{FFAA00}[CAD-UPDATE] " .. msg, -1)
  else
    print("[CAD-UPDATE] " .. msg)
  end
end

local function update_animation()
  if not anim_running then return end

  local now     = os.clock()
  local elapsed = now - anim_start_time
  local duration= 0.2
  local p       = math.min(1, elapsed / duration)

  anim_alpha = anim_from + (anim_to - anim_from) * p

  if p >= 1 then
    anim_alpha   = anim_to
    anim_from    = anim_alpha
    anim_running = false

    if ui_state.anim_closing then
      ui_state.show_window  = false
      ui_state.anim_closing = false
    end
  end
end

local function c32(r, g, b, a)
  local ri = math.min(255, math.floor(r * 255 + 0.5))
  local gi = math.min(255, math.floor(g * 255 + 0.5))
  local bi = math.min(255, math.floor(b * 255 + 0.5))
  local ai = math.min(255, math.floor(a * anim_alpha * 255 + 0.5))
  return ai * 16777216 + bi * 65536 + gi * 256 + ri
end

function M.initialize(deps)
  if deps and deps.log and deps.log_levels then
    local custom_log = deps.log
    local log_levels = deps.log_levels
    M.set_logger(function(msg)
      custom_log('AUTOUPDATE', log_levels.DEBUG, msg)
    end)
  end
end

function M.set_version(version)
  if version and #version > 0 then
    M.version = version
    log_fn("Current installed version set to: " .. version)
  end
end

function M.get_version()
  return M.version
end

local function cmpVer(a, b)
  local function ver_tuple(s)
    local t = {}
    for n in s:gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
  end
  local ta, tb = ver_tuple(a), ver_tuple(b)
  for i = 1, math.max(#ta, #tb) do
    local va, vb = (ta[i] or 0), (tb[i] or 0)
    if va < vb then return -1 end
    if va > vb then return 1 end
  end
  return 0
end

local function file_size(path)
  if ok_lfs then
    return lfs.attributes(path, 'size')
  end
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:seek('end')
  f:close()
  return s
end

local function get_file_sha256(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  
  local ok_openssl, openssl = pcall(require, 'openssl')
  if not ok_openssl then
    f:close()
    return nil
  end
  
  local body = f:read('*a')
  f:close()
  
  if body then
    return openssl.digest.new('sha256'):update(body):final()
  end
  return nil
end

local function ensure_dirs(path)
  if not ok_lfs then return end
  local dir = path:match('^(.*)[/\\][^/\\]+$')
  if not dir then return end
  local acc
  for part in dir:gmatch('[^/\\]+') do
    acc = acc and (acc .. '/' .. part) or part
    lfs.mkdir(acc)
  end
end

local function wait_for_file(path, expected_size, timeout_sec)
  local deadline    = os.clock() + timeout_sec
  local stable_count= 0
  local last_size   = -1

  while os.clock() < deadline do
    wait(DL_POLL_MS)
    local s = file_size(path)

    if s then
      if expected_size and s > 0 then
        if s == last_size then
          stable_count = stable_count + 1
          if stable_count >= DL_STABLE_TICKS then
            return true
          end
        else
          stable_count = 0
        end
        last_size = s
      else
        if s == last_size and s > 0 then
          stable_count = stable_count + 1
          if stable_count >= DL_STABLE_TICKS then
            return true
          end
        else
          stable_count = 0
          last_size    = s
        end
      end
    end
  end

  return falseт
end

local function wait_for_json(path, validator, timeout_sec)
  local deadline = os.clock() + timeout_sec

  while os.clock() < deadline do
    wait(DL_POLL_MS)

    local s1 = file_size(path)
    if s1 and s1 > 0 then
      wait(DL_POLL_MS)
      local s2 = file_size(path)
      if s2 and s2 == s1 then
        local f = io.open(path, 'r')
        if f then
          local raw = f:read('*a')
          f:close()
          if raw and #raw > 0 then
            local data, _, err = json.decode(raw)
            if data and (not validator or validator(data)) then
              return data
            end
          end
        end
      end
    end
  end

  return nil
end

local function apply_version_info(data)
  if type(data) ~= 'table' or type(data.latest) ~= 'string' then
    log_fn("Invalid version.json structure")
    return
  end

  upd.latest    = data.latest
  upd.changelog = type(data.changelog) == 'string' and data.changelog or nil
  upd.url       = type(data.url)       == 'string' and data.url       or nil
  upd.available = cmpVer(M.version, data.latest) < 0
  upd.required  = type(data.min_supported) == 'string' and
                  cmpVer(M.version, data.min_supported) < 0

  if upd.required then
    log_fn("⚠️  REQUIRED UPDATE: " .. M.version .. " → " .. data.latest)
    log_fn("Changelog: " .. (upd.changelog or "No details"))
  elseif upd.available then
    log_fn("✓ Update available: " .. M.version .. " → " .. data.latest)
    if upd.changelog then log_fn("Changes: " .. upd.changelog) end
  else
    log_fn("✓ Already up-to-date: " .. M.version)
  end
end

function M.check_version()
  if ok_lfs then lfs.mkdir(getWorkingDirectory() .. '/config') end

  local tmp = getWorkingDirectory() .. '/config/cad_version.json'
  os.remove(tmp)

  log_fn("Checking version from: " .. CFG.version_url)
  downloadUrlToFile(CFG.version_url, tmp)

  lua_thread.create(function()
    local data = wait_for_json(tmp,
      function(d) return type(d) == 'table' and type(d.latest) == 'string' end,
      DL_TIMEOUT_META)

    if data then
      apply_version_info(data)
    else
      log_fn("Timeout or invalid JSON waiting for version.json")
    end
  end)
end

local function sync_resources(cb, force_all)
  local function finish(ok)
    upd.busy = false
    if cb then cb(ok) end
  end

  local wd   = getWorkingDirectory()
  local mtmp = wd .. '/config/cad_manifest.json'

  if ok_lfs then lfs.mkdir(wd .. '/config') end
  os.remove(mtmp)

  log_fn("Downloading manifest...")
  downloadUrlToFile(CFG.raw_base .. 'resource/manifest.json', mtmp)

  lua_thread.create(function()
    local manifest = wait_for_json(mtmp,
      function(d) return type(d) == 'table' and type(d.files) == 'table' end,
      DL_TIMEOUT_META)

    if not manifest then
      log_fn("Failed to load manifest (timeout or invalid JSON)")
      finish(false)
      return
    end

  local todo = {}
    for _, item in ipairs(manifest.files) do
      if type(item.path) == 'string' then
        if force_all then
          todo[#todo + 1] = item
        else
          local local_path = (wd .. '/' .. item.path):gsub('\\', '/')
          
          local local_sha = get_file_sha256(local_path)
          
          if local_sha and item.sha256 and local_sha:lower() == item.sha256:lower() then
          else
            todo[#todo + 1] = item
          end
        end
      end
    end

    if #todo == 0 then
      log_fn("All resources up-to-date")
      finish(true)
      return
    end

    log_fn(("Syncing %d resources (force_all=%s)..."):format(#todo, tostring(force_all or false)))
    upd.status = ('Resources: 0/%d...'):format(#todo)

    local success_count = 0
    ui_state.failed_files = {}

    for i, item in ipairs(todo) do
      local lp = wd .. '/' .. item.path

      if item.path:find("cad_main%.lua$") then
        log_fn(("[SKIP] %s пропущен (исключен из обновлений)"):format(item.path))
        success_count = success_count + 1
        ui_state.progress = i / #todo
      else
        ensure_dirs(lp)
        os.remove(lp)

        ui_state.current_file  = item.path
        ui_state.progress      = (i - 1) / #todo
        ui_state.progress_text = ("Загрузка: %d/%d - %s"):format(i, #todo, item.path)
        upd.status             = ('Resources: %d/%d...'):format(i - 1, #todo)

        log_fn(("[%d/%d] Downloading: %s (expect %s bytes)"):format(
          i, #todo, item.path, tostring(item.size)))

        downloadUrlToFile(CFG.raw_base .. item.path, lp)

        local ok = wait_for_file(lp, item.size, DL_TIMEOUT_FILE)

        local downloaded_sha = get_file_sha256(lp)
        local hash_ok = downloaded_sha and item.sha256 and (downloaded_sha:lower() == item.sha256:lower())

        if ok and hash_ok then
          success_count = success_count + 1
          log_fn(("Downloaded & Verified: %s"):format(item.path))
        else
          if not ok then
            log_fn(("FAILED (Timeout/Size unstable): %s"):format(item.path))
          local actual = file_size(lp) or 0
          else
            log_fn(("FAILED (Hash mismatch): %s | Expected: %s, Got: %s"):format(
              item.path, tostring(item.size)))
          end
          ui_state.failed_files[#ui_state.failed_files + 1] = item.path
        end

        ui_state.progress = i / #todo
      end
    end

    ui_state.current_file  = ""
    ui_state.progress      = 1.0
    ui_state.progress_text = "Завершено!"

    if success_count == #todo then
      log_fn(("Resources synchronized: %d/%d"):format(success_count, #todo))
      finish(true)
    else
      log_fn(("ERROR: Only %d/%d files downloaded successfully"):format(success_count, #todo))
      upd.status = ("Ошибка: %d/%d файлов не загружено"):format(#todo - success_count, #todo)
      finish(false)
    end
  end)
end

local function save_version(version_str)
  if not version_str or version_str == "" then return end
  M.version = version_str
  local wd = getWorkingDirectory()
  if ok_lfs then lfs.mkdir(wd .. '/config') end
  local vf = io.open(wd .. '/config/cad_installed_version.txt', 'w')
  if vf then
    vf:write(version_str)
    vf:close()
    log_fn("✓ Saved version " .. version_str .. " to config file")
  else
    log_fn("WARNING: Could not write version file")
  end
end

function M.do_update()
  if upd.busy then
    log_fn("Update already in progress")
    return
  end

  if not (upd.available or upd.required) then
    log_fn("No updates available")
    return
  end

  M.show_ui()
  upd.busy   = true
  upd.status = 'Syncing resources...'
  ui_state.progress    = 0
  ui_state.log_lines   = {}
  ui_state.failed_files= {}

  sync_resources(function(success)
    if success then
      upd.status = 'Updates loaded. Restart script to apply.'
      log_fn("✓ Modules updated successfully")
      log_fn("Please restart the game or reload scripts to apply updates")
      chat_msg("Modules updated successfully! Restart to apply changes.")
      if upd.latest then save_version(upd.latest) end
    else
      upd.status = 'Update failed. Check logs.'
      log_fn("ERROR: Failed to sync modules")
      if #ui_state.failed_files > 0 then
        chat_msg("ERROR: " .. #ui_state.failed_files .. " file(s) failed to download")
        for _, fp in ipairs(ui_state.failed_files) do
          log_fn("  ✗ " .. fp)
        end
      else
        chat_msg("ERROR: Failed to sync modules")
      end
    end
  end)
end

function M.do_update_force()
  if upd.busy then
    log_fn("Update already in progress")
    return
  end

  if not upd.latest then
    log_fn("WARNING: Latest version unknown (check_version not done yet). Version file will NOT be updated.")
  end

  M.show_ui()
  upd.busy   = true
  upd.status = 'Force syncing ALL resources...'
  ui_state.progress    = 0
  ui_state.log_lines   = {}
  ui_state.failed_files= {}
  log_fn("⚠️  FORCE UPDATE: Will download ALL files from manifest!")

  sync_resources(function(success)
    if success then
      upd.status = 'Force update completed. Restart script to apply.'
      log_fn("✓ ALL files synchronized successfully")
      log_fn("Please restart the game or reload scripts to apply updates")
      chat_msg("Force update completed! Restart to apply changes.")
      if upd.latest then
        save_version(upd.latest)
      else
        log_fn("NOTE: version file not updated (latest version unknown)")
      end
    else
      upd.status = 'Force update failed. Check logs.'
      log_fn("ERROR: Failed to force sync modules")
      chat_msg("ERROR: " .. #ui_state.failed_files .. " file(s) failed during force update")
    end
  end, true)
end

function M.get_state()
  return {
    available    = upd.available,
    required     = upd.required,
    latest       = upd.latest,
    current      = M.version,
    changelog    = upd.changelog,
    busy         = upd.busy,
    status       = upd.status,
    failed_files = ui_state.failed_files,
  }
end

function M.has_update()  return upd.available or upd.required end
function M.is_required() return upd.required end
function M.get_status()  return upd.status end

function M.show_ui()
  ui_state.show_window  = true
  ui_state.anim_closing = false
  ui_state.p_open[0]    = true
  anim_from    = anim_alpha
  anim_to      = 1.0
  anim_running = true
  anim_start_time = os.clock()
end

function M.hide_ui()
  ui_state.anim_closing = true
  anim_from    = anim_alpha
  anim_to      = 0.0
  anim_running = true
  anim_start_time = os.clock()
end

function M.is_ui_open()
  return anim_alpha > 0.01
end

local function btn_primary(label, w, h)
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6.0)
  imgui.PushStyleColor(imgui.Col.Button,        ffi_cache.btn_primary[1])
  imgui.PushStyleColor(imgui.Col.ButtonHovered, ffi_cache.btn_primary[2])
  imgui.PushStyleColor(imgui.Col.ButtonActive,  ffi_cache.btn_primary[3])
  local clicked = imgui.Button(label, imgui.new('ImVec2', w, h))
  imgui.PopStyleColor(3)
  imgui.PopStyleVar(1)
  return clicked
end

local function btn_secondary(label, w, h)
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6.0)
  imgui.PushStyleColor(imgui.Col.Button,        ffi_cache.btn_secondary[1])
  imgui.PushStyleColor(imgui.Col.ButtonHovered, ffi_cache.btn_secondary[2])
  imgui.PushStyleColor(imgui.Col.ButtonActive,  ffi_cache.btn_secondary[3])
  local clicked = imgui.Button(label, imgui.new('ImVec2', w, h))
  imgui.PopStyleColor(3)
  imgui.PopStyleVar(1)
  return clicked
end

local function btn_danger(label, w, h)
  imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6.0)
  imgui.PushStyleColor(imgui.Col.Button,        ffi_cache.btn_danger[1])
  imgui.PushStyleColor(imgui.Col.ButtonHovered, ffi_cache.btn_danger[2])
  imgui.PushStyleColor(imgui.Col.ButtonActive,  ffi_cache.btn_danger[3])
  local clicked = imgui.Button(label, imgui.new('ImVec2', w, h))
  imgui.PopStyleColor(3)
  imgui.PopStyleVar(1)
  return clicked
end

local function thin_separator()
  imgui.PushStyleColor(imgui.Col.Separator, ffi_cache.col_border)
  imgui.Separator()
  imgui.PopStyleColor()
end

local WIN_W = 360

function M.draw_window()
  update_animation()

  if not ok_imgui or anim_alpha < 0.01 then return end
  if not ui_state.show_window then return end

  imgui.PushStyleVarFloat(imgui.StyleVar.Alpha,          anim_alpha)
  imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding,  10.0)
  imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding,  ffi_cache.win_padding)
  imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing,    ffi_cache.item_spacing)
  
  imgui.PushStyleColor(imgui.Col.WindowBg,     ffi_cache.col_win_bg)
  imgui.PushStyleColor(imgui.Col.TitleBg,      ffi_cache.col_title_bg)
  imgui.PushStyleColor(imgui.Col.TitleBgActive,ffi_cache.col_title_bg)
  imgui.PushStyleColor(imgui.Col.Border,       ffi_cache.col_border)

  local io = imgui.GetIO()
  if not io then
    for i = 1, 4 do imgui.PopStyleColor() end
    imgui.PopStyleVar(4)
    return
  end

  local has_errors   = #ui_state.failed_files > 0
  local has_changelog= upd.changelog and upd.changelog ~= ""
  local win_h
  if upd.busy then
    win_h = 190
  elseif has_errors then
    win_h = 240 + math.min(#ui_state.failed_files, 4) * 18
  elseif has_changelog then
    win_h = 230
  else
    win_h = 200
  end

  imgui.SetNextWindowPos(imgui.new('ImVec2', io.DisplaySize.x / 2 - WIN_W / 2, io.DisplaySize.y / 2 - win_h / 2), imgui.Cond.Always)
  imgui.SetNextWindowSize(imgui.new('ImVec2', WIN_W, win_h), imgui.Cond.Always)

  local flags = imgui.WindowFlags.NoMove
              + imgui.WindowFlags.NoResize
              + imgui.WindowFlags.NoScrollbar
              + imgui.WindowFlags.NoCollapse
  local visible = imgui.Begin(ffi_cache.win_title, ui_state.p_open, flags)

  if not ui_state.p_open[0] or not visible then
    imgui.End()
    for i = 1, 4 do imgui.PopStyleColor() end
    imgui.PopStyleVar(4)
    if not ui_state.p_open[0] then M.hide_ui() end
    return
  end


  local C_TEXT    = imgui.ImVec4(0.88, 0.88, 0.90, 1.00)
  local C_DIM     = imgui.ImVec4(0.45, 0.45, 0.50, 1.00)
  local C_GREEN   = imgui.ImVec4(0.27, 0.82, 0.27, 1.00)
  local C_YELLOW  = imgui.ImVec4(0.95, 0.80, 0.20, 1.00)
  local C_ORANGE  = imgui.ImVec4(1.00, 0.50, 0.18, 1.00)
  local C_RED     = imgui.ImVec4(1.00, 0.30, 0.30, 1.00)
  local C_BLUE    = imgui.ImVec4(0.40, 0.75, 1.00, 1.00)

  local inner_w = WIN_W - 32

  local cur_ver    = M.version  or "unknown"
  local latest_ver = upd.latest or "—"

  imgui.TextColored(C_DIM,  u8"Installed")
  imgui.SameLine()
  imgui.TextColored(C_TEXT, u8" " .. cur_ver)
  imgui.SameLine()
  local label_latest = u8"Latest  " .. latest_ver
  local rw = #("Latest  " .. latest_ver) * 7
  imgui.SetCursorPosX(16 + inner_w - rw)
  imgui.TextColored(C_DIM,  u8"Latest")
  imgui.SameLine()
  if upd.available or upd.required then
    imgui.TextColored(C_GREEN, u8" " .. latest_ver)
  else
    imgui.TextColored(C_DIM,   u8" " .. latest_ver)
  end

  imgui.Spacing()
  thin_separator()
  imgui.Spacing()

  if upd.busy then
    local blink = math.floor(os.clock() * 2) % 2 == 0
    local dot   = blink and "*" or "o"
    imgui.TextColored(C_YELLOW, u8(dot .. " UPDATING..."))

    imgui.Spacing()

    ffi_cache.progress_size.x = inner_w
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 4.0)
    imgui.PushStyleColor(imgui.Col.PlotHistogram, ffi_cache.col_progress_hist)
    imgui.PushStyleColor(imgui.Col.FrameBg,       ffi_cache.col_progress_bg)
    imgui.ProgressBar(ui_state.progress, ffi_cache.progress_size, u8"")
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(1)

    imgui.Spacing()
    local pct_str = math.floor(ui_state.progress * 100) .. "%"
    imgui.SetCursorPosX(16 + inner_w - #pct_str * 7)
    imgui.TextColored(C_DIM, u8(pct_str))

    if ui_state.current_file ~= "" then
      local fname = ui_state.current_file
      if #fname > 40 then fname = "..." .. fname:sub(-37) end
      imgui.TextColored(C_BLUE, u8("  " .. fname))
    end

  else
    if has_errors then
      imgui.TextColored(C_RED,    u8"[X] Update failed")
    elseif upd.required then
      imgui.TextColored(C_ORANGE, u8"[!] Required update")
    elseif upd.available then
      imgui.TextColored(C_GREEN,  u8"[UP] Update available")
    elseif upd.status and (upd.status:find("loaded") or upd.status:find("completed")) then
      imgui.TextColored(C_GREEN,  u8"[V] Done - restart to apply")
    else
      imgui.TextColored(C_GREEN,  u8"[V] Up to date")
    end

    if has_errors then
      imgui.Spacing()
      imgui.TextColored(C_DIM, u8"Failed files:")
      local shown = 0
      for _, fp in ipairs(ui_state.failed_files) do
        if shown >= 4 then
          imgui.TextColored(C_RED, u8("  ... and " .. (#ui_state.failed_files - 4) .. " more"))
          break
        end
        local short = fp
        if #short > 38 then short = "..." .. short:sub(-35) end
        imgui.TextColored(C_RED, u8("  [X] " .. short))
        shown = shown + 1
      end
    end

    if has_changelog and not has_errors then
      imgui.Spacing()
      imgui.TextColored(C_DIM, u8"What's new:")
      local cl = upd.changelog
      if #cl > 80 then cl = cl:sub(1, 77) .. "..." end
      imgui.TextWrapped(u8(cl))
    end

    imgui.Spacing()
    thin_separator()
    imgui.Spacing()

    local GAP    = 8
    local BTN_H  = 28

    if upd.available or upd.required then
      local w1 = 140
      local w2 = math.floor((inner_w - w1 - GAP * 2) / 2)
      local w3 = inner_w - w1 - w2 - GAP * 2

      imgui.SetCursorPosX(16)
      if btn_primary(u8"  Update", w1, BTN_H) then
        M.do_update()
      end
      imgui.SameLine(0, GAP)
      if btn_secondary(u8"Check", w2, BTN_H) then
        M.check_version()
      end
      imgui.SameLine(0, GAP)
      if btn_danger(u8"Force", w3, BTN_H) then
        M.do_update_force()
      end
    else
      local w1 = math.floor((inner_w - GAP) / 2)
      local w2 = inner_w - w1 - GAP

      imgui.SetCursorPosX(16)
      if btn_secondary(u8"Check for updates", w1, BTN_H) then
        M.check_version()
      end
      imgui.SameLine(0, GAP)
      if btn_danger(u8"Force sync", w2, BTN_H) then
        M.do_update_force()
      end
    end
  end

  imgui.End()
  for i = 1, 4 do imgui.PopStyleColor() end
  imgui.PopStyleVar(4)
end

function M.register_commands()
  if type(sampRegisterChatCommand) ~= 'function' then return end

  sampRegisterChatCommand("cadupdate", function()
    if not ok_imgui then
      if type(sampAddChatMessage) == 'function' then
        sampAddChatMessage("{FF4444}[CAD] ImGui not available", -1)
      end
      return
    end
    M.show_ui()
  end)
end

return M
