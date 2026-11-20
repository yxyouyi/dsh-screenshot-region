# dsh-screenshot-region

DeepSeek Harness 输入框旁的**一键原生框选截图**：点一下按钮 → 屏幕定格 → 拖一个框 → 松手，**只有框内那块图**进入对话框草稿，可以继续打字再发送。

> 这是 [dsh-plugin-screenshot](https://github.com/Durandalw/dsh-plugin-screenshot)（MIT）的整理版：把「先截整屏、再在页面里二次框选」改成 Windows 原生覆盖层的一次性框选，并修掉了几个会让流程卡死的缺陷。差异见下文「相对上游的改动」。

## 为什么需要它

原先的截图插件把选择框画在 DSH 页面里，全屏层挂在输入框插槽内部会被裁掉，鼠标一点又会被当成「选中指针下的整个窗口」，结果是：要么看不到可框选的画面，要么直接得到一张整屏图。本版把选择动作交给 Windows 原生窗口，和页面层级、DPI、输入框布局彻底解耦。

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带）或 PowerShell 7
- DeepSeek Harness `>= 0.2.0-rc.1`，Node `>= 20`

## 安装

```powershell
# 在 DSH profile 目录下（例如 desktop）
dsh plugin --profile desktop add dsh-screenshot-region
```

或把本包打包后交给 **Plugins → 添加插件**：

```powershell
npm pack                                              # 生成 dsh-screenshot-region-0.4.0.tgz
```

安装后在 **Plugins** 页确认 bundle 已启用，然后：

- 改了**宿主半身**（`lib/index.js`、`scripts/*.ps1`）→ 重启 DSH
- 只改了**浏览器半身**（`lib/client.js`）→ 刷新页面（`Ctrl+R`）

## 使用

| 操作 | 效果 |
|---|---|
| 点输入框左下的截图图标 | 屏幕定格，进入框选 |
| 按住左键拖一个框，松手 | 完成，框内图片插入输入框草稿 |
| `Esc` / 右键 | 取消 |
| 拖动不足 8px | 不生效（防止误点截整屏） |
| 点图标右侧 `▾` | 选择截图时「隐藏本窗口 / 保留本窗口」，选择会被记住 |

默认「保留本窗口」：定格画面就是你屏幕上看到的样子，框选所见即所得。

## 配置

在 profile 的 `cordis.patch.yml` 覆盖该行：

```yaml
- id: dsh-screenshot-region
  name: 'dsh-screenshot-region'
  config:
    # 完成后的动作：clipboard（同时写入剪贴板）| attach（只插入对话框）
    defaultAction: clipboard
    # 显式指定 PowerShell，便携版或改名安装时使用
    # shellPath: 'D:\tools\pwsh\pwsh.exe'
```

`snapThreshold` / `ignoreWindowPatterns` / `longShot*` 是上游遗留项，仅旧的页面内浮层使用，本版的原生框选不读取它们。

## 附带的模型工具

宿主半身还向 Agent 暴露两个工具：

- `screenshot_capture` — 全屏 / 指定窗口 / 指定矩形截图
- `screenshot_list_windows` — 列出顶层窗口及其矩形

## 自检与开发

`scripts/region.ps1` 支持两种不必真的拖鼠标的验证方式：

```powershell
# 1) 只验证截图 + 裁剪链路：裁剪指定矩形，不弹任何窗口
powershell -STA -File scripts/region.ps1 -OutFile out.png -Rect "100,100,400,300"

# 2) 验证覆盖层本身：建窗口 + 强制走一遍重绘后退出，不上屏
powershell -STA -File scripts/region.ps1 -OutFile out.png -SelfTest
```

第二种用于拦截「窗口一建就报错」这类问题（例如受保护属性赋值失败）。两个命令都应输出 `{"status":"ok",...}`。

打包与安装：

```powershell
npm pack --pack-destination build
# 再用 plugin_manager install_bundle 指向 build 下的 tgz；升级后重启 DSH 清理旧路由
```

## 已知限制

- 仅 Windows；依赖 PowerShell 与 Win32/GDI。
- 多显示器按虚拟桌面整体截取，框选坐标与真实屏幕像素一致（启动即 `SetProcessDPIAware`）。
- 覆盖层默认 180 秒无操作自动取消。
- 升级安装后请重启 DSH：旧实例注册的 HTTP 路由不会立刻释放，同前缀的热替换可能报 `duplicate exact route`。

## 相对上游的改动

1. **新增** `scripts/region.ps1`：原生全屏框选层（定格画面、拖动选区、尺寸提示、`Esc`/右键取消、超时自动退出）。
2. **新增** 宿主路由 `POST /dsh-shot/region` 与 `runInteractive()`（带 `-STA`，把「用户按了 Esc」当正常结果而非失败）。
3. **客户端**：主按钮改为调用 `/region` 并直接插入结果，去掉「先出整屏图」的一步。
4. **修复** 页面内浮层未 portal 到 `document.body` 导致被输入框裁剪。
5. **修复** 单击被当成「选中整个窗口」，误点直接截整屏。
6. **修复** `Form.DoubleBuffered` 属受保护属性、PowerShell 直接赋值抛错（报错文本只有 `DoubleBuffered`）。
7. **修复** `region.ps1` 缺少 UTF-8 BOM，Windows PowerShell 5.1 按 GBK 读取导致脚本解析失败。
8. **修复** 宿主包解析不到 `@deepseek-ai/dsh-tools` 时整条 entry 加载失败 → 改为可选依赖并降级。
9. **修复** 「隐藏本窗口」截完返回时会把窗口状态改掉（最大化被还原成普通大小、最小化被拉起）→ 隐藏前记录 `GetWindowPlacement` 的 `showCmd`，按原状态还原。

## 许可

MIT。上游 `dsh-plugin-screenshot` 作者保留其版权；本版的修改与原生框选层同样以 MIT 发布，见 [LICENSE](./LICENSE)。

## English

One-step region screenshot for the DeepSeek Harness composer on Windows. Click the camera-frame button in the composer tool row, drag a rectangle on the frozen desktop, release — only that rectangle is attached to the draft. `Esc` or right-click cancels; a click without a drag does nothing. The optional `▾` menu switches between hiding and keeping the Harness window during capture.

This is a cleaned-up fork of `dsh-plugin-screenshot` (MIT): the selection UI moved from an in-page overlay to a native Win32/WinForms overlay, plus fixes for the clipped overlay, click-to-capture, a protected `DoubleBuffered` assignment, a missing UTF-8 BOM and an optional host dependency. Requires DSH `>= 0.2.0-rc.1` and Windows PowerShell 5.1+.
