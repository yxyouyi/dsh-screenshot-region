# Changelog

## 0.4.0 — 2026-11-20

首个整理发布版，基于上游 `dsh-plugin-screenshot@0.3.5`（MIT）。

### 新增

- `scripts/region.ps1`：Windows 原生全屏框选层。定格桌面、拖动选区、尺寸提示、`Esc`/右键取消、超时自动退出，隐藏/恢复本窗口在同一个进程内完成（`finally` 保证恢复）。
- 宿主路由 `POST /dsh-shot/region`，配合 `runInteractive()`（`-STA` 启动，取消不算错误）。
- 客户端 `startRegion()`：按钮点一下即进入框选，只有框内图片进入草稿，不再出现中间的全屏图。
- `scripts/region.ps1 -Rect "x,y,w,h"`：不弹窗口的裁剪自检。
- `scripts/region.ps1 -SelfTest`：建窗口并强制重绘一次的自检，拦截「窗口一建就报错」。

### 修复

- 页面内浮层没有被 portal 到 `document.body`，被输入框插槽裁剪，用户看不到可框选画面。
- 单击（拖动不足 6px）会选中指针下的整个窗口，误点即截整屏；现在必须真实拖动。
- `Form.DoubleBuffered` 是受保护属性，PowerShell 直接赋值抛出的错误文本只有 `DoubleBuffered`；改为反射赋值，失败则退化为无双缓冲（仅有轻微闪烁）。
- `region.ps1` 缺少 UTF-8 BOM 时，Windows PowerShell 5.1 按 GBK 读取，中文字符串会破坏脚本解析。
- 宿主包解析不到 `@deepseek-ai/dsh-tools` 时整条 entry 加载失败；改为可选依赖，解析不到就只提供浏览器半身。

### 变更

- 截图默认不再隐藏 Harness 窗口：定格画面与所见一致，`▾` 可切换。
- `▾` 选择「保留本窗口」时跳过窗口枚举，覆盖层少等约 2 秒。
- 包名改为 `dsh-screenshot-region`，路由前缀为 `/dsh-shot`，与上游共存时互不冲突。
