# 发布指南（运维手册）

本仓库的维护者：`youyi <yxyouyi@163.com>`

发布分两条路，通常先发 GitHub（插件市场需要仓库链接），再发 npm（让 `dsh plugin add` 能装）。

## 一、发 GitHub

首次：

```powershell
cd D:\Documents\deepseek-harness\default-workspace\dsh-screenshot-region
git remote add origin https://github.com/<你的GitHub用户名>/dsh-screenshot-region.git
git push -u origin main
```

后续改版：

```powershell
npm pack --pack-destination build        # 先确认包内容
git add -A
git commit -m "fix: ..."
git tag v0.4.1
git push --follow-tags
```

> 仓库里 `.gitignore` 已排除 `node_modules/`、`build/`、`*.tgz`，不要把打好的 tarball 提交进去。

## 二、发 npm

前置：npm 账号，并**把 registry 切到官方源**（当前机器配的是 `registry.npmmirror.com`，镜像站不能发布）。

```powershell
npm config set registry https://registry.npmjs.org/
npm login                                   # 浏览器/OTP 登录
npm whoami                                  # 确认身份
```

发布：

```powershell
cd D:\Documents\deepseek-harness\default-workspace\dsh-screenshot-region
npm publish                                 # publishConfig 已设 access=public
```

`dsh-screenshot-region` 这个名字在 npmjs 上目前**未被占用**（2026-11-20 核对）。若被别人抢注，改成带 scope 的名字：

```powershell
# 包名与 cordis.patch.yml 的 name 必须一致，两处一起改
npm pkg set name=@你的用户名/dsh-screenshot-region
# 同时修改 cordis.patch.yml 里的 id / name
npm publish --access public
```

发布后自检：

```powershell
npm view dsh-screenshot-region version dist.tarball
# 在干净的 DSH profile 里安装验证
dsh plugin --profile <profile> add dsh-screenshot-region
```

## 三、提交到插件市场（可选）

- [dshhub.org](https://dshhub.org) — 提交 GitHub 仓库链接
- [dshplugin.online](https://dshplugin.online) — 同上

市场页会读取仓库的 `README.md`、`docs/DETAIL.md`、`package.json` 的 `dsh` 段与 `description`。

## 四、发布前检查清单

- [ ] `npm pack --dry-run` 里没有多余文件（应只有 lib、6 个 ps1、patch、README、CHANGELOG、LICENSE、docs）
- [ ] `scripts/region.ps1` 以 **UTF-8 带 BOM** 保存（Windows PowerShell 5.1 否则按 GBK 解析）
- [ ] `region.ps1 -SelfTest` 与 `-Rect "10,10,200,120"` 均返回 `{"status":"ok"}`
- [ ] `lib/client.js` 与 `lib/index.js` 的 `PREFIX` 一致
- [ ] `cordis.patch.yml` 的 `id` / `name` 与 `package.json` 的 `name` 完全一致
- [ ] 版本号已 bump，`CHANGELOG.md` 有对应条目

## 五、已知维护注意

- **升级后要重启 DSH**：同一前缀的 HTTP 路由在旧实例退出前不会释放，热替换可能报 `duplicate exact route`。
- 改了 `lib/client.js` 只需刷新页面；改了 `lib/index.js` 或 `scripts/*.ps1` 需重启 DSH（脚本是每次现读，宿主逻辑不是）。
- 本包是 `dsh-plugin-screenshot@0.3.5`（MIT）的衍生版，`LICENSE` 已保留上游版权与修改声明，请勿删除。
