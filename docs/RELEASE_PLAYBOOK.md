# Release Playbook

## 目标

对这个仓库来说，“发布完成”必须同时满足：

- `main` 已推送到 GitHub
- `v<version>` tag 已推送
- GitHub Actions `Release Build` 成功
- GitHub Releases 页面已有 `dmg` 和 `zip`
- `appcast.xml` 已由工作流更新并回写到 `main`
- Release Notes 已补成用户可读版本
- 本地已重新同步远端 `main`

只要缺一项，都不算真正发版完成。

## 发版前

先确认版本号已同步更新：

- `AIUsage/Info.plist`
- `AIUsage.xcodeproj/project.pbxproj`
- `README.md`
- `README.zh-CN.md`

建议先看工作区：

```bash
git status -sb
```

## 本地预检

每次发版前至少跑这四步：

```bash
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
```

含义很简单：

- `swift test` 检查后端与包测试
- `run_claude_proxy_regression.sh` 检查 Claude 代理主链路
- `xcodebuild ... Release` 提前暴露 Release-only 编译问题
- `package-release.sh` 提前暴露本地打包问题

## 标准发版

### 1. 提交并推送

```bash
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
```

### 2. 盯工作流

```bash
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
```

如果失败，先直接看日志：

```bash
gh run view <run_id> --log-failed
```

### 3. 核对 Release

```bash
gh release view v<version> --json tagName,name,body,url,assets
```

必须确认：

- 有 `AIUsage-<version>-macOS.dmg`
- 有 `AIUsage-<version>-macOS.zip`
- Release 不是 draft
- 正文不是默认空模板

### 4. 拉回远端回写

```bash
git fetch origin
git pull --ff-only origin main
git status -sb
```

重点是把工作流自动更新的 `appcast.xml` 拉回本地。

## Release Notes

工作流只会自动生成默认 changelog 链接，所以每次都要手动补正文：

```bash
gh release edit v<version> --notes-file <notes-file>
```

推荐结构：

```md
## <version> 更新内容

### 体验修复
- ...

### 稳定性与维护
- ...

**Full Changelog**: https://github.com/sylearn/AIUsage/compare/v<prev>...v<version>
```

## 失败后的正确做法

如果 `Release Build` 失败，不要直接跳新版本号。

正确流程：

1. 在 `main` 修当前版本问题
2. 重新跑本地预检
3. 提交修复
4. 强制移动同一个 tag
5. 重新推送 `main` 和 tag

命令：

```bash
git add <changed-files>
git commit -m "<fix message>"
git push origin main
git tag -fa v<version> -m "Release <version>"
git push origin v<version> --force
```

## 关键坑点

### 1. 只看本地 Debug 没用

- CI 上的 Release 构建更严格
- 一定要跑本地 Release 构建
- CI 失败时先看日志，不要靠猜

### 2. 不只是主 App，会一起构建 QuotaServer helper

- 主 App 能编译，不代表 Release workflow 一定能过
- Claude 代理相关回归必须每次发版前都跑

### 3. `appcast.xml` 的最终版本在远端

- 发版成功后，工作流会自动回写 `appcast.xml`
- 所以最后一定要 `git pull --ff-only origin main`

### 4. Release Notes 不会自动写好

- 默认只有 `Full Changelog`
- 必须手动补用户可读说明

### 5. `codesign` 容易被扩展属性绊倒

典型报错：

```text
resource fork, Finder information, or similar detritus not allowed
```

常见来源：

- `com.apple.FinderInfo`
- `com.apple.fileprovider.fpfs#P`

经验结论：

- 不要删掉 `scripts/package-release.sh` 里的 detritus 清理逻辑
- 不要在桌面仓库目录里的 staging `.app` 上直接做签名
- 先复制到 `/tmp` 临时目录签名和做 DMG staging，再把最终产物写回 `dist/`

## 最短手顺

```bash
git status -sb
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
gh release view v<version> --json tagName,name,body,url,assets
git fetch origin
git pull --ff-only origin main
git status -sb
```
