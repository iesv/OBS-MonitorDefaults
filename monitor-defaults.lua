-- OBS-MonitorDefaults 3.0.0
-- Author: haliluya.net
-- SPDX-License-Identifier: GPL-2.0-or-later

local obs = obslua
local band = require("bit").band
-- Select UI text once; source callbacks do not perform translation lookups.
local text = ({
    ["zh-CN"] = {
        version = "版本：",
        author = "作者", refresh = "刷新来源类型", keep = "保留 OBS 默认",
        off = "关闭监听", only = "仅监听（输出静音）", both = "监听并输出",
        missing = "未找到某个类型？先添加该类型的来源，再刷新列表。",
        startup = "自动全屏", program = "输出全屏", multiview = "多视图全屏",
        disabled = "不启用", display = "显示器 %d",
    },
    ["zh-TW"] = {
        version = "版本：",
        author = "作者", refresh = "重新整理來源類型", keep = "保留 OBS 預設",
        off = "關閉監聽", only = "僅監聽（輸出靜音）", both = "監聽並輸出",
        missing = "找不到某個類型？先新增該類型的來源，再重新整理清單。",
        startup = "自動全螢幕", program = "輸出全螢幕", multiview = "多視圖全螢幕",
        disabled = "不啟用", display = "顯示器 %d",
    },
})[obs.obs_get_locale()] or {
    version = "Version: ",
    author = "Author", refresh = "Refresh Source Types", keep = "Keep OBS Default",
    off = "Monitor Off", only = "Monitor Only (mute output)", both = "Monitor and Output",
    missing = "Add a source of the missing type, then refresh the list.",
    startup = "Auto Fullscreen", program = "Program Output", multiview = "Multiview Output",
    disabled = "Disabled", display = "Display %d",
}
local types, modes, seen, pending = {}, {}, {}, {}
local media = {}
local running, ready, handler = false, false, nil
local ffi, native
local apply_pending
local startup_enabled, startup_done, startup_pending = false, false, false
local projectors = {
    {key = "projector_program", kind = "StudioProgram", label = text.program, monitor = 0},
    {key = "projector_multiview", kind = "Multiview", label = text.multiview, monitor = 0},
}

-- FFI enumerates type IDs unavailable through the Lua bindings.
pcall(function()
    ffi = require("ffi")
    ffi.cdef [[bool obs_enum_input_types2(size_t, const char **, const char **);]]
    for _, name in ipairs({"", "obs", "@rpath/libobs.framework/Versions/A/libobs"}) do
        local ok, library = pcall(function()
            local library = name == "" and ffi.C or ffi.load(name)
            assert(library.obs_enum_input_types2)
            return library
        end)
        if ok then native = library; break end
    end
end)

-- Read and edit only metadata; all patches keep the original byte lengths.
local open_file = io.open
pcall(function()
    if ffi == nil or ffi.os ~= "Windows" then return end
    ffi.cdef [[
        int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, wchar_t *, int);
        void *_wfopen(const wchar_t *, const wchar_t *);
        size_t fread(void *, size_t, size_t, void *);
        size_t fwrite(const void *, size_t, size_t, void *);
        int _fseeki64(void *, int64_t, int);
        int64_t _ftelli64(void *);
        int fflush(void *);
        int fclose(void *);
    ]]
    local kernel, crt = ffi.load("kernel32"), ffi.load("ucrtbase")
    local whence = {set = 0, cur = 1, ["end"] = 2}
    local methods = {}
    function methods:read(count)
        if count == 0 then return "" end
        local buffer = ffi.new("uint8_t[?]", count)
        local size = tonumber(crt.fread(buffer, 1, count, self.handle))
        if size > 0 then return ffi.string(buffer, size) end
    end
    function methods:seek(origin, offset)
        if crt._fseeki64(self.handle, offset or 0, whence[origin or "cur"]) == 0 then
            local position = tonumber(crt._ftelli64(self.handle))
            if position >= 0 then return position end
        end
    end
    function methods:write(data)
        if tonumber(crt.fwrite(data, 1, #data, self.handle)) == #data then return self end
    end
    function methods:flush() return crt.fflush(self.handle) == 0 end
    function methods:close()
        local result = crt.fclose(self.handle) == 0
        self.handle = nil
        return result
    end
    open_file = function(path, mode)
        local wide = ffi.new("wchar_t[?]", #path + 1)
        if kernel.MultiByteToWideChar(65001, 8, path, #path, wide, #path) == 0 then return end
        local flags = ffi.new("wchar_t[?]", #mode + 1)
        for index = 1, #mode do flags[index - 1] = mode:byte(index) end
        local file = crt._wfopen(wide, flags)
        if file ~= nil then return setmetatable({handle = file}, {__index = methods}) end
    end
end)

local metadata_limit = 16 * 1024 * 1024
local function number(data, base, reverse)
    if data == nil then return end
    local value = 0
    for index = 1, #data do
        local byte = data:byte(reverse and #data - index + 1 or index)
        if base == 128 and byte >= 128 then return end
        value = value * base + byte
    end
    return value
end

local function read_at(file, offset, count)
    if file:seek("set", offset) == nil then return end
    local data = file:read(count)
    if data ~= nil and #data == count then return data end
end

local function add_patch(patches, offset, original, replacement)
    assert(#original == #replacement, "metadata length changed")
    patches.bytes = (patches.bytes or 0) + #original
    assert(patches.bytes <= metadata_limit, "metadata exceeds 16 MiB")
    patches[#patches + 1] = {offset = offset, original = original, replacement = replacement}
end

local function id3_patches(file, offset, limit, patches)
    local header = assert(read_at(file, offset, 10), "truncated ID3 header")
    assert(header:sub(1, 3) == "ID3", "missing ID3 header")
    local version, revision, flags = header:byte(4, 6)
    assert(version >= 2 and version <= 4 and revision == 0, "unsupported ID3 version")
    -- Skip whole-tag unsynchronisation, compression, CRCs and footers.
    assert(flags == 0 or (version >= 3 and flags == 32), "unsupported ID3 flags")
    local size = assert(number(header:sub(7, 10), 128), "invalid ID3 size")
    patches.inspected = (patches.inspected or 0) + size
    assert(patches.inspected <= metadata_limit and offset + 10 + size <= limit, "invalid ID3 bounds")
    local body = assert(read_at(file, offset + 10, size), "truncated ID3 tag")
    local kept, removed, position = {}, 0, 1
    local width = version == 2 and 6 or 10
    while position <= #body do
        if body:byte(position) == 0 then
            assert(not body:sub(position):find("[^%z]"), "invalid ID3 padding")
            kept[#kept + 1] = body:sub(position)
            break
        end
        assert(position + width - 1 <= #body, "truncated ID3 frame")
        local id_width = version == 2 and 3 or 4
        local id = body:sub(position, position + id_width - 1)
        assert(id:match("^[A-Z0-9]+$"), "invalid ID3 frame ID")
        local length = assert(number(body:sub(position + id_width, position + width - (version == 2 and 1 or 3)),
            version == 4 and 128 or 256), "invalid ID3 frame size")
        local finish = position + width + length - 1
        assert(length > 0 and finish <= #body, "invalid ID3 frame bounds")
        if id == "APIC" or (version == 2 and id == "PIC") then
            removed = removed + width + length
        else
            kept[#kept + 1] = body:sub(position, finish)
        end
        position = finish + 1
    end
    if removed > 0 then add_patch(patches, offset + 10, body, table.concat(kept) .. string.rep("\0", removed)) end
    return offset + 10 + size
end

local function flac_patches(file, size, patches)
    assert(read_at(file, 0, 4) == "fLaC", "invalid FLAC signature")
    local offset = 4
    for index = 1, 4096 do
        local header = assert(read_at(file, offset, 4), "truncated FLAC metadata")
        local kind = band(header:byte(1), 127)
        local length = number(header:sub(2), 256)
        local finish = offset + 4 + length
        assert(kind < 127 and finish <= size and finish <= metadata_limit, "invalid FLAC metadata bounds")
        assert(index ~= 1 or (kind == 0 and length == 34), "invalid FLAC STREAMINFO")
        assert(index == 1 or kind ~= 0, "duplicate FLAC STREAMINFO")
        if kind == 6 then
            assert(length >= 32, "invalid FLAC picture block")
            local picture = assert(read_at(file, offset + 4, length), "truncated FLAC picture")
            add_patch(patches, offset, header .. picture,
                string.char(band(header:byte(1), 128) + 1) .. header:sub(2) .. string.rep("\0", length))
        end
        offset = finish
        if header:byte(1) >= 128 then
            local sync = assert(read_at(file, offset, 2), "missing FLAC audio")
            assert(sync:byte(1) == 255 and band(sync:byte(2), 254) == 248, "invalid FLAC audio signature")
            return
        end
    end
    error("too many FLAC metadata blocks")
end

local function chunk_patches(file, size, extension, patches)
    local header = assert(read_at(file, 0, 12), "truncated audio container")
    local wave = extension == "wav"
    assert(wave and header:sub(1, 4) == "RIFF" and header:sub(9) == "WAVE" or
        not wave and header:sub(1, 4) == "FORM" and (header:sub(9) == "AIFF" or header:sub(9) == "AIFC"),
        "unsupported audio container")
    local limit = number(header:sub(5, 8), 256, wave) + 8
    assert(limit <= size and limit >= 12, "invalid audio container size")
    local offset, audio, format, count = 12, false, false, 0
    while offset < limit do
        count = count + 1
        assert(count <= 4096, "too many audio chunks")
        local chunk = assert(read_at(file, offset, 8), "truncated audio chunk")
        local id, length = chunk:sub(1, 4), number(chunk:sub(5), 256, wave)
        local finish = offset + 8 + length
        assert(finish <= limit, "invalid audio chunk bounds")
        if id:lower() == "id3 " then id3_patches(file, offset + 8, finish, patches) end
        if id == (wave and "data" or "SSND") and length > 0 then audio = true end
        if id == (wave and "fmt " or "COMM") then format = true end
        offset = finish + length % 2
    end
    assert(audio and format and offset == limit, "invalid audio chunks")
end

local function m4a_patches(file, size, patches)
    local audio, video, media_data, boxes = false, false, false, 0
    local function walk(start, limit, parent, depth)
        assert(depth <= 6, "MP4 nesting too deep")
        local offset = start
        while offset < limit do
            boxes = boxes + 1
            assert(boxes <= 65536, "too many MP4 boxes")
            local header = assert(read_at(file, offset, 8), "truncated MP4 box")
            local length, kind, width = number(header:sub(1, 4), 256), header:sub(5), 8
            if length == 1 then
                length, width = number(assert(read_at(file, offset + 8, 8), "truncated MP4 large size"), 256), 16
            elseif length == 0 then length = limit - offset end
            local finish = offset + length
            assert(length >= width and length <= 9007199254740991 and finish <= limit, "invalid MP4 bounds")
            local content = offset + width
            if parent == "root" and kind == "mdat" and length > width then media_data = true end
            if parent == "mdia" and kind == "hdlr" then
                local handler = assert(read_at(file, content, 12), "truncated MP4 handler"):sub(9)
                if handler == "soun" then audio = true end
                if handler == "vide" then video = true end
            elseif parent == "ilst" and kind == "covr" then
                assert(length <= metadata_limit, "MP4 cover exceeds 16 MiB")
                local original = assert(read_at(file, offset, length), "truncated MP4 cover")
                add_patch(patches, offset, original,
                    original:sub(1, 4) .. "free" .. original:sub(9, width) .. string.rep("\0", length - width))
            elseif (parent == "root" and kind == "moov") or (parent == "moov" and (kind == "trak" or kind == "udta" or kind == "meta")) or
                   (parent == "trak" and (kind == "mdia" or kind == "udta")) or
                   (parent == "udta" and kind == "meta") or (parent == "meta" and kind == "ilst") then
                if kind == "meta" then
                    assert(read_at(file, content, 4) == "\0\0\0\0", "unsupported MP4 metadata version")
                    content = content + 4
                end
                walk(content, finish, kind, depth + 1)
            end
            offset = finish
        end
        assert(offset == limit, "invalid MP4 box alignment")
    end
    local first = assert(read_at(file, 0, 8), "truncated M4A file")
    assert(first:sub(5) == "ftyp", "unsupported M4A signature")
    walk(0, size, "root", 0)
    assert(audio and not video and media_data, "M4A must contain audio without video tracks")
end

local function remove_cover(path)
    local extension = path:lower():match("%.([a-z0-9]+)$")
    if extension ~= "mp3" and extension ~= "flac" and extension ~= "wav" and
       extension ~= "aif" and extension ~= "aiff" and extension ~= "m4a" then return false end
    if path:find("%z") then return nil, "invalid filename" end
    local file = open_file(path, "rb")
    if file == nil then return nil, "cannot read file" end
    local size = file:seek("end")
    local patches = {}
    local ok, reason = pcall(function()
        assert(size ~= nil, "cannot read file size")
        if extension == "flac" then flac_patches(file, size, patches)
        elseif extension == "m4a" then m4a_patches(file, size, patches)
        elseif extension == "mp3" then
            local offset = 0
            if read_at(file, 0, 3) == "ID3" then offset = id3_patches(file, 0, size, patches) end
            local frame = assert(read_at(file, offset, 4), "missing MP3 audio")
            local a, b, c = frame:byte(1, 3)
            assert(a == 255 and band(b, 224) == 224 and band(b, 24) ~= 8 and band(b, 6) == 2 and
                band(c, 240) ~= 240 and band(c, 12) ~= 12, "invalid MP3 audio signature")
        else chunk_patches(file, size, extension, patches) end
    end)
    file:close()
    if not ok then return nil, tostring(reason):gsub("^.-:%d+: ", "") end
    if #patches == 0 then return false end
    file = open_file(path, "r+b")
    if file == nil then return nil, "file is locked or read-only" end
    -- Recheck every region before writing; restore metadata if a write fails.
    ok = file:seek("end") == size
    for _, patch in ipairs(patches) do
        if read_at(file, patch.offset, #patch.original) ~= patch.original then ok = false; break end
    end
    if not ok then file:close(); return nil, "file changed during inspection" end
    local function write_all(field)
        for _, patch in ipairs(patches) do
            if file:seek("set", patch.offset) == nil or not file:write(patch[field]) then return false end
        end
        if not file:flush() then return false end
        for _, patch in ipairs(patches) do
            if read_at(file, patch.offset, #patch[field]) ~= patch[field] then return false end
        end
        return true
    end
    local written, result = pcall(write_all, "replacement")
    local restored = true
    if not written or not result then
        local success, value = pcall(write_all, "original")
        restored = success and value
    end
    file:close()
    if not written or not result then
        return nil, restored and "write failed; metadata restored" or "write and recovery failed; check the file"
    end
    return true
end

local function set_media_path(source, path)
    local settings = obs.obs_data_create()
    obs.obs_data_set_string(settings, "local_file", path)
    obs.obs_source_update(source, settings)
    obs.obs_data_release(settings)
end

local function restore_media(source, entry)
    if entry.reload == nil then return end
    local path = entry.reload
    entry.reload, entry.closed = nil, nil
    local settings = obs.obs_source_get_settings(source)
    local restore = obs.obs_data_get_bool(settings, "is_local_file") and obs.obs_data_get_string(settings, "local_file") == ""
    obs.obs_data_release(settings)
    if restore then set_media_path(source, path) end
    return restore
end

local function update_media(source, entry)
    if entry.reload ~= nil then
        if not entry.closed then return end
        if restore_media(source, entry) then return end
    end
    if obs.obs_source_get_monitoring_type(source) ~= obs.OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT then return end
    local settings = obs.obs_source_get_settings(source)
    local path = obs.obs_data_get_bool(settings, "is_local_file") and obs.obs_data_get_string(settings, "local_file") or ""
    obs.obs_data_release(settings)
    if path == "" or path == entry.path then return end
    entry.path = path
    local changed, reason = remove_cover(path)
    if changed then
        -- A normal media restart reuses the decoder and its cached cover.
        entry.reload = path
        set_media_path(source, "")
    elseif reason ~= nil then
        obs.script_log(obs.LOG_WARNING, "Cover removal skipped: " .. reason .. " (" .. path .. ")")
    end
end

local function is_audio(source)
    return source ~= nil and obs.obs_source_get_type(source) == obs.OBS_SOURCE_TYPE_INPUT and
        band(obs.obs_source_get_output_flags(source), obs.OBS_SOURCE_AUDIO) ~= 0
end

local function queue_source(source, mode)
    if not running or not ready then return end
    local uuid = obs.obs_source_get_uuid(source)
    local entry = pending[uuid]
    if entry == nil then
        local weak = obs.obs_source_get_weak_source(source)
        if weak == nil then return end
        local first = next(pending) == nil
        entry = {weak = weak}
        pending[uuid] = entry
        if first then obs.timer_add(apply_pending, 100) end
    end
    if mode ~= nil then
        entry.mode, entry.initial = mode, obs.obs_source_get_monitoring_type(source)
    end
end

local function media_changed(cd)
    local source = obs.calldata_source(cd, "source")
    if source ~= nil and media[obs.obs_source_get_uuid(source)] ~= nil then queue_source(source) end
end

local function media_updated(cd)
    local source = obs.calldata_source(cd, "source")
    local entry = source ~= nil and media[obs.obs_source_get_uuid(source)] or nil
    if entry ~= nil then
        entry.path = nil
        if entry.reload ~= nil then entry.closed = true end
        queue_source(source)
    end
end

local function disconnect_media(entry)
    obs.signal_handler_disconnect(entry.handler, "audio_monitoring", media_changed)
    obs.signal_handler_disconnect(entry.handler, "update", media_updated)
end

local function watch_media(source, uuid)
    if obs.obs_source_get_unversioned_id(source) ~= "ffmpeg_source" then return end
    local weak = obs.obs_source_get_weak_source(source)
    if weak == nil then return end
    local signals = obs.obs_source_get_signal_handler(source)
    media[uuid] = {weak = weak, handler = signals}
    obs.signal_handler_connect(signals, "audio_monitoring", media_changed)
    obs.signal_handler_connect(signals, "update", media_updated)
    queue_source(source)
end

local function media_destroyed(cd)
    local source = obs.calldata_source(cd, "source")
    if source == nil then return end
    local uuid = obs.obs_source_get_uuid(source)
    local entry = media[uuid]
    if entry == nil then return end
    disconnect_media(entry)
    obs.obs_weak_source_release(entry.weak)
    media[uuid] = nil
end

local function clear_media()
    for _, entry in pairs(media) do
        disconnect_media(entry)
        local source = obs.obs_weak_source_get_source(entry.weak)
        if source ~= nil then
            restore_media(source, entry)
            obs.obs_source_release(source)
        end
        obs.obs_weak_source_release(entry.weak)
    end
    media = {}
end

local function add_type(id, registered)
    types[id] = obs.obs_source_get_display_name(registered) or id
end

local function discover_types()
    if native ~= nil then
        local id, family = ffi.new("const char *[1]"), ffi.new("const char *[1]")
        local index = 0
        while native.obs_enum_input_types2(index, id, family) do
            local registered = ffi.string(id[0])
            local flags = obs.obs_get_source_output_flags(registered)
            if band(flags, obs.OBS_SOURCE_AUDIO) ~= 0 and
               band(flags, obs.OBS_SOURCE_CAP_DISABLED + obs.OBS_SOURCE_DEPRECATED) == 0 then
                add_type(ffi.string(family[0]), registered)
            end
            index = index + 1
        end
    else
        for _, id in ipairs({"ffmpeg_source", "vlc_source", "browser_source", "wasapi_input_capture",
                "wasapi_output_capture", "wasapi_process_output_capture", "coreaudio_input_capture",
                "coreaudio_output_capture", "dshow_input", "decklink-input"}) do
            if band(obs.obs_get_source_output_flags(id), obs.OBS_SOURCE_AUDIO) ~= 0 then add_type(id, id) end
        end
    end
    local sources = obs.obs_enum_sources()
    if sources == nil then return end
    for _, source in ipairs(sources) do
        if is_audio(source) then
            add_type(obs.obs_source_get_unversioned_id(source), obs.obs_source_get_id(source))
        end
    end
    obs.source_list_release(sources)
end

local function remember_existing()
    local sources = obs.obs_enum_sources()
    if sources == nil then return end
    for _, source in ipairs(sources) do
        if is_audio(source) then
            seen[obs.obs_source_get_uuid(source)] = true
        end
    end
    obs.source_list_release(sources)
end

apply_pending = function()
    obs.timer_remove(apply_pending)
    local batch = pending
    pending = {}
    for uuid, entry in pairs(batch) do
        local source = obs.obs_weak_source_get_source(entry.weak)
        if source ~= nil then
            if running and ready and not obs.obs_source_removed(source) then
                if entry.mode ~= nil then
                    local current = obs.obs_source_get_monitoring_type(source)
                    if current == entry.initial or current == obs.OBS_MONITORING_TYPE_MONITOR_ONLY then
                        obs.obs_source_set_monitoring_type(source, entry.mode)
                    end
                end
                if media[uuid] ~= nil then update_media(source, media[uuid]) end
            end
            obs.obs_source_release(source)
        end
        obs.obs_weak_source_release(entry.weak)
    end
end

local function cancel_pending()
    obs.timer_remove(apply_pending)
    for _, entry in pairs(pending) do obs.obs_weak_source_release(entry.weak) end
    pending = {}
end

local wait_for_scene
local function start_applying()
    obs.timer_remove(wait_for_scene)
    if not running then return end
    remember_existing()
    ready = true
end

wait_for_scene = function()
    if not running then obs.timer_remove(wait_for_scene); return end
    local scene = obs.obs_frontend_get_current_scene()
    if scene ~= nil then
        obs.obs_source_release(scene)
        start_applying()
    end
end

local function source_created(cd)
    if not running or not ready then return end
    local source = obs.calldata_source(cd, "source") -- Borrowed reference.
    if not is_audio(source) then return end
    local uuid = obs.obs_source_get_uuid(source)
    if seen[uuid] then return end
    seen[uuid] = true
    watch_media(source, uuid)
    local mode = modes[obs.obs_source_get_unversioned_id(source)]
    if mode == nil then return end
    if band(obs.obs_source_get_output_flags(source), obs.OBS_SOURCE_MONITOR_BY_DEFAULT) == 0 then
        obs.obs_source_set_monitoring_type(source, mode)
        if media[uuid] ~= nil then queue_source(source) end
        return
    end
    -- OBS sets native monitoring defaults after creation; defer this batch once.
    queue_source(source, mode)
end

local function apply_projector_settings()
    local config = obs.obs_frontend_get_user_config() -- Borrowed reference.
    if config == nil then
        obs.script_log(obs.LOG_WARNING, "Projector settings unavailable.")
        return
    end
    local changed = false
    for key, value in pairs({HideProjectorCursor = true, ProjectorAlwaysOnTop = true,
            SaveProjectors = false, CloseExistingProjectors = true}) do
        if obs.config_get_bool(config, "BasicWindow", key) ~= value then
            obs.config_set_bool(config, "BasicWindow", key, value)
            changed = true
        end
    end
    if changed and obs.config_save_safe(config, "tmp", nil) ~= 0 then
        obs.script_log(obs.LOG_WARNING, "Could not save projector settings; changes apply to this session.")
    end
end

local function open_startup_projectors()
    obs.timer_remove(open_startup_projectors)
    if not startup_pending then return end
    startup_pending = false
    if not running or not ready or not startup_enabled then return end
    for _, output in ipairs(projectors) do
        if output.monitor > 0 then
            obs.obs_frontend_open_projector(output.kind, output.monitor - 1, "", "")
        end
    end
end

local function cancel_startup_projectors()
    startup_pending = false
    obs.timer_remove(open_startup_projectors)
end

local function frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING or
       event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGED then
        start_applying()
        if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING and running and not startup_done then
            startup_done = true
            if startup_enabled and (projectors[1].monitor > 0 or projectors[2].monitor > 0) then
                startup_pending = true
                obs.timer_add(open_startup_projectors, 2000)
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CHANGING or
           event == obs.OBS_FRONTEND_EVENT_SCENE_COLLECTION_CLEANUP or
           event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN or event == obs.OBS_FRONTEND_EVENT_EXIT then
        ready = false
        cancel_startup_projectors()
        obs.timer_remove(wait_for_scene)
        cancel_pending()
        clear_media()
    end
end

function script_description()
    return "<b>OBS-MonitorDefaults</b><br>" .. text.version .. "3.0.0<br>" .. text.author .. ": haliluya.net"
end

local function refresh_types() return true end

function script_properties()
    discover_types()
    local properties = obs.obs_properties_create()
    obs.obs_properties_add_button(properties, "refresh_types", text.refresh, refresh_types)
    local ordered = {}
    for id, label in pairs(types) do ordered[#ordered + 1] = {id = id, label = label} end
    table.sort(ordered, function(a, b)
        if a.label == b.label then return a.id < b.id end
        return a.label < b.label
    end)
    for _, entry in ipairs(ordered) do
        local choice = obs.obs_properties_add_list(properties, "type_" .. entry.id, entry.label,
            obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
        obs.obs_property_list_add_int(choice, text.keep, 0)
        obs.obs_property_list_add_int(choice, text.off, obs.OBS_MONITORING_TYPE_NONE + 1)
        obs.obs_property_list_add_int(choice, text.only, obs.OBS_MONITORING_TYPE_MONITOR_ONLY + 1)
        obs.obs_property_list_add_int(choice, text.both, obs.OBS_MONITORING_TYPE_MONITOR_AND_OUTPUT + 1)
    end
    if native == nil then
        obs.obs_properties_add_text(properties, "type_discovery", text.missing,
            obs.OBS_TEXT_INFO)
    end
    local startup = obs.obs_properties_create()
    for _, output in ipairs(projectors) do
        local choice = obs.obs_properties_add_list(startup, output.key, output.label,
            obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
        obs.obs_property_list_add_int(choice, text.disabled, 0)
        for monitor = 1, 10 do
            obs.obs_property_list_add_int(choice, string.format(text.display, monitor), monitor)
        end
    end
    obs.obs_properties_add_group(properties, "startup_projectors", text.startup, obs.OBS_GROUP_CHECKABLE, startup)
    return properties
end

function script_update(settings)
    local enabled = obs.obs_data_get_bool(settings, "startup_projectors")
    if enabled and (not startup_enabled or not running) then apply_projector_settings() end
    startup_enabled = enabled
    if startup_pending and not startup_enabled then cancel_startup_projectors() end
    for _, output in ipairs(projectors) do
        local monitor = obs.obs_data_get_int(settings, output.key)
        monitor = monitor >= 1 and monitor <= 10 and monitor or 0
        if startup_pending and output.monitor ~= monitor then cancel_startup_projectors() end
        output.monitor = monitor
    end
    if next(types) == nil then discover_types() end
    modes = {}
    for id in pairs(types) do
        local selected = obs.obs_data_get_int(settings, "type_" .. id)
        if selected >= 1 and selected <= 3 then modes[id] = selected - 1 end
    end
end

function script_load(settings)
    discover_types()
    script_update(settings)
    running, ready, seen, startup_done, startup_pending = true, false, {}, false, false
    handler = obs.obs_get_signal_handler()
    obs.signal_handler_connect(handler, "source_create", source_created)
    obs.signal_handler_connect(handler, "source_destroy", media_destroyed)
    obs.signal_handler_connect(handler, "source_load", media_updated)
    obs.obs_frontend_add_event_callback(frontend_event)
    local scene = obs.obs_frontend_get_current_scene()
    if scene ~= nil then
        obs.obs_source_release(scene)
        start_applying()
    else
        obs.timer_add(wait_for_scene, 100)
    end
end

function script_unload()
    running, ready = false, false
    cancel_startup_projectors()
    obs.timer_remove(wait_for_scene)
    cancel_pending()
    clear_media()
    if handler ~= nil then
        obs.signal_handler_disconnect(handler, "source_create", source_created)
        obs.signal_handler_disconnect(handler, "source_destroy", media_destroyed)
        obs.signal_handler_disconnect(handler, "source_load", media_updated)
        handler = nil
    end
    obs.obs_frontend_remove_event_callback(frontend_event)
    seen = {}
end
