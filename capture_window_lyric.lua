local ffi = require("ffi")
local bit = require("bit")
local obs = obslua

local is_64bit = ffi.abi("64bit")

ffi.cdef[[
typedef int BOOL;
typedef unsigned int UINT;
typedef void* HWND;
typedef unsigned short wchar_t;
typedef intptr_t LONG_PTR;
typedef long LONG;
typedef unsigned long DWORD;
typedef void* HANDLE;

typedef struct { long left; long top; long right; long bottom; } RECT;

BOOL EnumWindows(BOOL (*lpEnumFunc)(HWND, LONG_PTR), LONG_PTR);
BOOL IsWindowVisible(HWND hwnd);
int GetClassNameW(HWND hwnd, wchar_t* lpClassName, int nMaxCount);
int GetWindowTextW(HWND hWnd, wchar_t* lpString, int nMaxCount);

LONG_PTR GetWindowLongPtrW(HWND hWnd, int nIndex);
LONG_PTR SetWindowLongPtrW(HWND hWnd, int nIndex, LONG_PTR);
LONG GetWindowLongW(HWND hWnd, int nIndex);
LONG SetWindowLongW(HWND hWnd, int nIndex, LONG dwNewLong);

BOOL SetWindowPos(HWND, HWND, int, int, int, int, UINT);
HWND GetDesktopWindow();
DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);

HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
BOOL CloseHandle(HANDLE hObject);
BOOL QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, wchar_t* lpExeName, DWORD* lpdwSize);

int WideCharToMultiByte(UINT CodePage, DWORD dwFlags, const wchar_t* lpWideCharStr, int cchWideChar,
                        char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, BOOL* lpUsedDefaultChar);
]]

local WIN = {
    GWL_EXSTYLE = -20,
    GWL_HWNDPARENT = -8,
    WS_EX_TOOLWINDOW = 0x00000080,
    WS_EX_APPWINDOW  = 0x00040000,
    SWP_NOMOVE = 0x0002,
    SWP_NOSIZE = 0x0001,
    SWP_NOZORDER = 0x0004,
    SWP_FRAMECHANGED = 0x0020,
    CP_UTF8 = 65001,
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000,
}

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

local DEFAULT_CONFIG = {
    patterns_pwt=[[
process=cloudmusic.exe class=DesktopLyrics title=桌面歌词
process=QQMusic.exe class=TXGuiFoundation title=桌面歌词
process=KuGou.exe class=kugou_ui title=桌面歌词 - 酷狗音乐
process=kwmusic.exe class=KwDeskLyricWnd title=
process=foobar2000.exe class=uie_eslyric_desktop_wnd_class title=
process=foobar2000.exe class=floating_eslyric_wnd_class title=
]],
    patterns_pwf=[[
process=WeSing.exe class=ATL: title=CLyricRenderWnd
process=WeSing.exe class=ATL: title=CScoreWnd
]]
}

local state = {
    enable_timer = false,
    interval = 10,
    enable_pwt = true,
    enable_pwf = true,
    patterns_pwt = {},
    patterns_pwf = {},
    log_history = {},
    is_loaded = false,
}

local process_cache = {}
local process_original_cache = {}
local hwnd_cache = {}
local processed_hwnds = {}

local function log_info(msg)
    obs.script_log(obs.LOG_INFO, msg)
    table.insert(state.log_history, msg)
    if #state.log_history > 500 then table.remove(state.log_history, 1) end
end

local function parse_lines(text)
    local arr = {}
    for line in tostring(text):gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^%-%-") then
            table.insert(arr, line)
        end
    end
    return arr
end

local utf16_buf = ffi.new("wchar_t[512]")
local function utf16_to_utf8(wstr,len)
    if len<=0 then return "" end
    local n = kernel32.WideCharToMultiByte(WIN.CP_UTF8,0,wstr,len,nil,0,nil,nil)
    local buf = ffi.new("char[?]", n+1)
    kernel32.WideCharToMultiByte(WIN.CP_UTF8,0,wstr,len,buf,n,nil,nil)
    return ffi.string(buf)
end

local function GetLong(hwnd,i)
    if is_64bit then return tonumber(user32.GetWindowLongPtrW(hwnd,i))
    else return tonumber(user32.GetWindowLongW(hwnd,i)) end
end

local function SetLong(hwnd,i,v)
    if is_64bit then user32.SetWindowLongPtrW(hwnd,i,ffi.cast("LONG_PTR",v))
    else user32.SetWindowLongW(hwnd,i,ffi.cast("LONG",v)) end
end

local function get_class(hwnd)
    local len = user32.GetClassNameW(hwnd, utf16_buf, 256)
    return len>0 and utf16_to_utf8(utf16_buf,len) or ""
end

local function get_title(hwnd)
    local len = user32.GetWindowTextW(hwnd, utf16_buf, 256)
    return len>0 and utf16_to_utf8(utf16_buf,len) or ""
end

local function get_process_cached(hwnd)
    local key = tonumber(ffi.cast("intptr_t", hwnd))
    if process_cache[key] then return process_cache[key] end

    local pid = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd,pid)

    local hProc = kernel32.OpenProcess(WIN.PROCESS_QUERY_LIMITED_INFORMATION,0,pid[0])
    if hProc == nil or hProc == ffi.NULL then
        process_cache[key] = "unknown"
        process_original_cache[key] = "unknown.exe"
        return "unknown"
    end

    local size = ffi.new("DWORD[1]",512)
    kernel32.QueryFullProcessImageNameW(hProc,0,utf16_buf,size)
    kernel32.CloseHandle(hProc)

    local full = utf16_to_utf8(utf16_buf,size[0])
    local original_name = full:match("([^\\/:]+)$") or "unknown.exe"
    local simple_name = original_name:gsub("%.exe$", ""):gsub("%.EXE$", "") or original_name

    process_original_cache[key] = original_name
    process_cache[key] = simple_name

    return simple_name
end

local function get_original_process_name(hwnd)
    local key = tonumber(ffi.cast("intptr_t", hwnd))
    if not process_original_cache[key] then
        get_process_cached(hwnd)
    end
    return process_original_cache[key] or "unknown.exe"
end

local function set_taskbar_visible(hwnd, safe_parent)
    local ex = GetLong(hwnd, WIN.GWL_EXSTYLE) or 0
    ex = bit.band(ex, bit.bnot(WIN.WS_EX_APPWINDOW))
    ex = bit.band(ex, bit.bnot(WIN.WS_EX_TOOLWINDOW))
    SetLong(hwnd, WIN.GWL_EXSTYLE, ex)

    if safe_parent then
        local desktop_hwnd = ffi.cast("intptr_t", user32.GetDesktopWindow())
        local current_owner = GetLong(hwnd, WIN.GWL_HWNDPARENT) or 0
        if current_owner ~= desktop_hwnd then
            SetLong(hwnd, WIN.GWL_HWNDPARENT, desktop_hwnd)
        end
    end

    user32.SetWindowPos(hwnd, ffi.NULL, 0,0,0,0,
        bit.bor(WIN.SWP_NOMOVE,WIN.SWP_NOSIZE,WIN.SWP_NOZORDER,WIN.SWP_FRAMECHANGED))
end

local function wildcard_match(str, pattern)
    if not pattern or pattern=="" then return true end
    pattern = pattern:gsub("([%^%$%(%)%%%.%[%]%+%-])","%%%1")
    pattern = pattern:gsub("%*",".*"):gsub("%?",".")
    return str:lower():match("^"..pattern:lower().."$") ~= nil
end

local function match_pattern_rule(pname, cls, title, pattern)
    local proc_pat  = pattern:match("process=([^%s]*)") or ""
    local class_pat = pattern:match("class=([^%s]*)") or ""
    local title_pat = pattern:match("title=(.*)") or ""

    local proc_pat_simple = proc_pat:gsub("%.exe$", ""):gsub("%.EXE$", "")
    local pname_simple = pname:gsub("%.exe$", ""):gsub("%.EXE$", "")
    local proc_match = false
    if proc_pat ~= "" then
        proc_match = wildcard_match(pname, proc_pat) or 
                     wildcard_match(pname_simple, proc_pat_simple)
    else
        proc_match = true
    end
    if not proc_match then return false end

    if class_pat ~= "" then
        local cls_prefix = cls:match("^[^:]*") or cls
        local pat_prefix = class_pat:match("^[^:]*") or class_pat
        if not wildcard_match(cls_prefix, pat_prefix) then return false end
    end

    if not wildcard_match(title, title_pat) then return false end

    return true
end

local function find_windows()
    local windows = {}
    local cb = ffi.cast("BOOL(*)(HWND,LONG_PTR)",function(hwnd,lParam)
        if user32.IsWindowVisible(hwnd)==0 then return 1 end
        local simple_name = get_process_cached(hwnd)
        local original_name = get_original_process_name(hwnd)
        table.insert(windows,{
            hwnd=hwnd,
            process=simple_name,
            process_original=original_name,
            class=get_class(hwnd),
            title=get_title(hwnd)
        })
        return 1
    end)
    user32.EnumWindows(cb,0)
    cb:free()
    return windows
end

local function process_windows(windows)
    local matched_pwt, matched_pwf = {}, {}

    for _,win in ipairs(windows) do
        local hwnd = win.hwnd
        local key = tonumber(ffi.cast("intptr_t", hwnd))
        if state.enable_pwt then
            for _,pattern in ipairs(state.patterns_pwt) do
                if match_pattern_rule(win.process_original, win.class, win.title, pattern) then
                    set_taskbar_visible(hwnd, true)
                    table.insert(matched_pwt, win)
                    hwnd_cache[key] = true
                    break
                end
            end
        end
        if state.enable_pwf then
            for _,pattern in ipairs(state.patterns_pwf) do
                if match_pattern_rule(win.process_original, win.class, win.title, pattern) then
                    set_taskbar_visible(hwnd, false)
                    table.insert(matched_pwf, win)
                    hwnd_cache[key] = true
                    break
                end
            end
        end
    end
    return matched_pwt, matched_pwf
end

-- 单独的输出窗口信息函数
local function print_windows_info()
    process_cache = {}
    process_original_cache = {}
    hwnd_cache = {}
    
    local windows = find_windows()
    log_info("可见窗口信息数量："..#windows)
    for i,v in ipairs(windows) do
        log_info(string.format("[%d] process=%s class=%s title=%s", i,v.process_original,v.class,v.title))
    end
end

local function run_detection()
    process_cache = {}
    process_original_cache = {}
    hwnd_cache = {}
    
    local windows = find_windows()
    local matched_pwt, matched_pwf = process_windows(windows)

    log_info("桌面歌词pwt数量: "..#matched_pwt)
    for i,v in ipairs(matched_pwt) do
        log_info(string.format("[%d] process=%s class=%s title=%s", i,v.process_original,v.class,v.title))
    end

    log_info("桌面歌词pwf数量: "..#matched_pwf)
    for i,v in ipairs(matched_pwf) do
        log_info(string.format("[%d] process=%s class=%s title=%s", i,v.process_original,v.class,v.title))
    end
end

local function tick() 
    local success, err = pcall(run_detection)
    if not success then
        log_info("定时检测异常: " .. tostring(err))
    end
end

function script_load(settings)
    state.is_loaded = true
    log_info("脚本开始加载")
    
    script_defaults(settings)
    
    state.enable_timer = obs.obs_data_get_bool(settings,"timer")
    state.interval = obs.obs_data_get_int(settings,"interval")
    state.enable_pwt = obs.obs_data_get_bool(settings,"enable_pwt")
    state.enable_pwf = obs.obs_data_get_bool(settings,"enable_pwf")
    state.patterns_pwt = parse_lines(obs.obs_data_get_string(settings,"patterns_pwt"))
    state.patterns_pwf = parse_lines(obs.obs_data_get_string(settings,"patterns_pwf"))

    log_info("脚本加载完成")
end

function script_unload()
    log_info("脚本开始卸载")
    
    obs.timer_remove(tick)
    log_info("已停止定时检测定时器")
    
    process_cache = {}
    process_original_cache = {}
    hwnd_cache = {}
    processed_hwnds = {}
    log_info("已清空所有缓存数据")
    
    state.is_loaded = false
    state.log_history = {}
    log_info("脚本卸载完成")
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings,"timer",false)
    obs.obs_data_set_default_int(settings,"interval",10)
    obs.obs_data_set_default_bool(settings,"enable_pwt",true)
    obs.obs_data_set_default_bool(settings,"enable_pwf",true)
    obs.obs_data_set_default_string(settings,"patterns_pwt",DEFAULT_CONFIG.patterns_pwt)
    obs.obs_data_set_default_string(settings,"patterns_pwf",DEFAULT_CONFIG.patterns_pwf)
end

function script_properties()
    local p = obs.obs_properties_create()
    obs.obs_properties_add_button(p,"run","运行",function() 
        local success, err = pcall(run_detection)
        if not success then
            log_info("手动检测异常: " .. tostring(err))
        end
        return true 
    end)
    -- 添加输出窗口信息按钮
    obs.obs_properties_add_button(p,"print_windows_info","输出窗口信息",function()
        local success, err = pcall(print_windows_info)
        if not success then
            log_info("输出窗口信息异常: " .. tostring(err))
        end
        return true
    end)
    obs.obs_properties_add_bool(p,"timer","定时运行")
    obs.obs_properties_add_int(p,"interval","检测间隔(秒)",1,60,1)

    obs.obs_properties_add_bool(p,"enable_pwt","启用规则（每行一个 格式：process=进程名 class=类名 title=标题名）")
    obs.obs_properties_add_text(p,"patterns_pwt","桌面歌词pwt",obs.OBS_TEXT_MULTILINE)
    obs.obs_properties_add_bool(p,"enable_pwf","启用规则（每行一个 格式：process=进程名 class=类名 title=标题名）")
    obs.obs_properties_add_text(p,"patterns_pwf","桌面歌词pwf",obs.OBS_TEXT_MULTILINE)
    return p
end

function script_update(settings)
    if not state.is_loaded then return end
    
    state.enable_timer = obs.obs_data_get_bool(settings,"timer")
    state.interval = obs.obs_data_get_int(settings,"interval")

    state.enable_pwt = obs.obs_data_get_bool(settings,"enable_pwt")
    state.enable_pwf   = obs.obs_data_get_bool(settings,"enable_pwf")

    state.patterns_pwt = parse_lines(obs.obs_data_get_string(settings,"patterns_pwt"))
    state.patterns_pwf = parse_lines(obs.obs_data_get_string(settings,"patterns_pwf"))

    obs.timer_remove(tick)
    if state.enable_timer then
        obs.timer_add(tick,state.interval*1000)
        log_info(string.format("已启动定时检测，间隔: %d 秒", state.interval))
    end
end

function script_description()
    return [[
<p>capture window lyric<br>采集窗口歌词</p>
v <a href="https://github.com/Alcg0711/capture_window_lyric">1.1.1</a>
by <a href="https://space.bilibili.com/11662625">Alcg</a>
]]
end