# Capture Window Lyric

采集窗口歌词（OBS Lua 脚本）

## 功能

- 输出窗口信息
- 枚举系统窗口
- 根据规则匹配歌词窗口（进程 / 类名 / 标题）
- 调整窗口样式（任务栏 / 父窗口）
- 支持多播放器（网易云 / QQ音乐 / 酷狗 / 酷我 / foobar / 全民K歌）

## 使用

1. 打开 OBS 工具 → 脚本
2. 添加 `capture_window_lyric.lua`
3. 配置匹配规则
4. 点击“运行”

## 规则

每行一个规则

规则示例：

process=cloudmusic.exe class=DesktopLyrics title=桌面歌词

process=QQMusic.exe class=TXGuiFoundation title=桌面歌词

process=KuGou.exe class=kugou_ui title=桌面歌词 - 酷狗音乐

process=kwmusic.exe class=KwDeskLyricWnd title=

process=foobar2000.exe class=uie_eslyric_desktop_wnd_class title=

process=foobar2000.exe class=floating_eslyric_wnd_class title=

process=WeSing.exe class=ATL: title=CLyricRenderWnd

process=WeSing.exe class=ATL: title=CScoreWnd

## 作者

Alcg：https://space.bilibili.com/11662625

## 许可

MIT
