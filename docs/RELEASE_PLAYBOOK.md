# Release Playbook

## 目的

这份文档是 AIUsage 的正式发版操作手册，用来避免每次发布时重复踩坑。

对于这个仓库，“发布完成”不只是本地提交成功，而是以下事项全部完成：

- `main` 已推送到 GitHub
- 对应版本 tag 已推送
- GitHub Actions `Release Build` 成功
- GitHub Releases 页面已生成 `dmg` 和 `zip`
- `appcast.xml` 已由工作流更新并回写到 `main`
- Release Notes 已填写为用户可读版本
- 本地仓库已重新同步远端 `main`

只要上述任意一项没完成，都不能算真正发版完成。

## 发布前硬规则

1. 不要只做本地 commit 就汇报“发布完成”。
2. 不要在 GitHub Release 失败后直接跳版本号，先修当前版本并重发同一个 tag。
3. 每次发版前都必须跑本地验证，尤其是 Claude Code 代理相关链路。
4. GitHub Actions 成功后，必须把工作流自动提交的 `appcast.xml` 拉回本地。
5. Release Notes 不能留默认模板，必须补成用户能看懂的更新说明。

## 标准发版流程

### 1. 准备版本号

需要同步更新的文件：

- `AIUsage/Info.plist`
- `AIUsage.xcodeproj/project.pbxproj`
- `README.md`
- `README.zh-CN.md`

建议先确认工作区干净：

```bash
git status -sb
```

### 2. 本地预检

这是发版前的最低验证集：

```bash
cd QuotaBackend && swift test
cd ..
./scripts/run_claude_proxy_regression.sh
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Release build CODE_SIGNING_ALLOWED=NO
./scripts/package-release.sh <version>
```

说明：

- `swift test` 负责后端和包级测试。
- `run_claude_proxy_regression.sh` 负责 Claude 代理关键链路回归。
- `xcodebuild ... Release` 用于提前暴露 Release-only 编译问题。
- `package-release.sh` 虽然本地无法完全替代 GitHub 的签名流程，但能提前发现绝大多数构建和打包问题。

### 3. 提交、推送与打 tag

```bash
git add <changed-files>
git commit -m "Release <version>"
git push origin main
git tag -a v<version> -m "Release <version>"
git push origin v<version>
```

示例：

```bash
git commit -m "Release 0.3.4"
git push origin main
git tag -a v0.3.4 -m "Release 0.3.4"
git push origin v0.3.4
```

### 4. 盯 GitHub Actions

```bash
gh run list --workflow "Release Build" --limit 3
gh run watch <run_id> --interval 10 --exit-status
```

如果失败，先看失败日志：

```bash
gh run view <run_id> --log-failed
gh run view <run_id> --job <job_id> --log
```

### 5. 发布成功后必须做的核对

```bash
gh release view v<version> --json tagName,name,body,url,assets
git fetch origin
git pull --ff-only origin main
git status -sb
```

必须确认：

- Release 页面有 `AIUsage-<version>-macOS.dmg`
- Release 页面有 `AIUsage-<version>-macOS.zip`
- Release 不是 draft
- `appcast.xml` 已被工作流更新
- 本地 `main` 与 `origin/main` 一致

## Release Notes 处理

GitHub workflow 目前只会生成默认的 changelog 链接，不会自动写好面向用户的更新说明。

所以发版成功后，必须手动补正文：

```bash
gh release edit v<version> --notes "<notes>"
```

推荐结构：

```md
## <version> 更新内容

### 重点修复
- ...

### 稳定性与验证
- ...

### 维护与优化
- ...

**Full Changelog**: https://github.com/sylearn/AIUsage/compare/v<prev>...v<version>
```

## 失败后如何正确补救

如果 GitHub Release workflow 失败，不要直接放弃，也不要新开一个版本号来掩盖问题。

正确做法：

1. 在 `main` 上修复问题。
2. 本地重新跑验证。
3. 提交修复。
4. 把同一个版本 tag 强制移动到最新提交。
5. 重新 push `main` 和 tag。
6. 重新观察 `Release Build`。

命令：

```bash
git add <changed-files>
git commit -m "<fix message>"
git push origin main
git tag -fa v<version> -m "Release <version>"
git push origin v<version> --force
```

这一步是 AIUsage 仓库非常重要的固定动作，因为发布工作流是由 tag 触发的。

## 本仓库最常见的发版坑

### 1. 本地能过，不代表 GitHub runner 能过

GitHub runner 的 Xcode 版本和本地不一定一致，严格性也可能不同。

已经踩过的真实问题：

- `@MainActor` / actor isolation 在 CI 上更严格
- `String.dropFirst()` 返回 `Substring`，某些拼接在 CI 的 Release 构建里直接报错

结论：

- 不能只看本地 Debug 构建
- 一定要跑本地 Release 构建
- 一旦 CI 失败，要直接读失败日志，不要凭印象猜

### 2. Release workflow 不只构建 App，还会构建 QuotaServer helper

Claude Code 代理相关逻辑依赖 `QuotaBackend/QuotaServer`。

这意味着：

- 主 App 能编译，不代表 Release workflow 一定能过
- `QuotaServer` 的 Release 构建兼容性也必须验证
- Claude 代理回归测试必须作为发版前必跑项

### 3. `appcast.xml` 的最终真相在远端

发版成功后，GitHub Actions 会自动更新 `appcast.xml` 并回写到 `origin/main`。

这意味着：

- 本地发版前的 `appcast.xml` 不是最终结果
- 工作流成功后，必须执行 `git pull --ff-only origin main`
- 如果忘记拉回本地，之后继续开发很容易造成版本状态混乱

### 4. Release Notes 不会自动写好

工作流默认只会留下：

```md
**Full Changelog**: ...
```

这对最终用户基本没有帮助，所以每次都要手动补。

### 5. 本地打包成功，不代表签名和 appcast 一定没问题

本地能验证：

- 构建是否通过
- 打包脚本是否正常
- 代理功能是否回归

GitHub 才能最终验证：

- Sparkle 签名
- Release 资产上传
- `appcast.xml` 更新

所以本地验证和 GitHub 发布缺一不可。

### 6. `codesign` 会被包内扩展属性绊倒

如果本地打包阶段出现下面这种错误：

```text
resource fork, Finder information, or similar detritus not allowed
```

通常不是业务代码问题，而是 `.app` 或嵌套框架里残留了 Finder / File Provider 扩展属性。

这次真实遇到的属性包括：

- `com.apple.FinderInfo`
- `com.apple.fileprovider.fpfs#P`

经验结论：

- 不能只依赖一次 `xattr -cr`
- 打包脚本里要显式清理这些属性后再 `codesign`
- 不要删掉 `scripts/package-release.sh` 里的 detritus 清理逻辑

## 推荐发布命令清单

把下面这组命令当成默认手顺：

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

## 0.3.4 的直接教训

这次发布过程中，真实踩到的坑包括：

- GitHub runner 上暴露了 `ProxyViewModel` 的 actor isolation 问题
- GitHub runner 上暴露了 `QuotaHTTPServer+Passthrough.swift` 的 `Substring` 拼接问题
- 第一次发布成功生成产物前，没有及时补 Release Notes
- 发布成功后，远端 `main` 因 `appcast.xml` 自动更新而领先本地一个 commit

因此，从 `0.3.4` 开始，后续发布必须默认执行：

- 本地 Release build
- Claude 代理回归脚本
- 成功后手动补 Release Notes
- 成功后立即 `git pull --ff-only origin main`
