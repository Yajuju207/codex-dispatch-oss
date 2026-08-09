# Codex Dispatch 配置

Codex Dispatch OSS v0.1 使用本机专属的 `config.local.json`。配置加载器只读取文件并返回规范化对象，不会创建目录、修改配置或接触生产安装。

## 创建本机配置

在仓库根目录执行：

```powershell
Copy-Item .\config.example.json .\config.local.json
```

然后编辑 `config.local.json`，至少把下列占位值换成本机真实值：

- `workspace.root`：存放待发现项目的现有目录；
- `controlPlane.repository`：私有 GitHub 控制仓库，格式为 `owner/repository`；
- `controlPlane.issueAssignee`：接收通知的 GitHub 用户名；
- `runtime.stateDirectory`：计划用于运行时状态的本机目录。

`config.local.json` 已被 `.gitignore` 忽略，不应提交。`config.example.json` 只用于复制模板；加载器会明确拒绝把它直接当作运行配置。

## 加载配置

从包含 `config.local.json` 的当前目录加载：

```powershell
$config = .\scripts\Load-CodexDispatchConfig.ps1
```

指定配置文件：

```powershell
$config = .\scripts\Load-CodexDispatchConfig.ps1 `
    -Path 'C:\path\to\config.local.json'
```

也可以指定一个已经存在的目录；加载器会在该目录内查找 `config.local.json`：

```powershell
$config = .\scripts\Load-CodexDispatchConfig.ps1 `
    -Path 'C:\path\to\codex-dispatch-settings'
```

相对的 `workspace.root` 以 `config.local.json` 所在目录为基准。路径中可使用 Windows `%VARIABLE%` 环境变量。加载成功后，`workspace.root` 会被规范化为现有目录的绝对路径。

## 统一返回对象

加载器固定返回以下六个顶层属性：

```text
workspace
controlPlane
routing
codex
privacy
safety
```

示例：

```powershell
$config.workspace.root
$config.controlPlane.repository
$config.routing.fast.enabled
$config.codex.command
$config.privacy.exposeLocalPathsInIssues
$config.safety.restrictToWorkspaceRoot
```

配置文件中的 `version` 用于兼容性校验。当前 `config.example.json` 中的 `runtime` 是后续运行时状态层的保留配置；v0.1 统一加载对象暂不返回该节。其他未知顶层属性也不会进入返回对象。

## 校验规则

加载器在返回对象前执行以下检查：

1. 文件名必须是 `config.local.json`；
2. `config.example.json` 不能直接运行；
3. `.runner`、`.runner_migrated`、`.credentials*`、`.env*`、`*.token`、`*.secret`、`auth.json` 等敏感文件会被拒绝；
4. `config.local.json` 本身不能是 symlink、junction 或其他 reparse point；
5. JSON 顶层和六个必需配置节必须是对象；
6. 如果提供 `version`，目前只能是 `1`；
7. `workspace.root` 必须存在且必须是目录；
8. 当 `workspace.allowReparsePoints=false` 或省略时，工作区根目录不能是 reparse point；
9. `controlPlane.provider` 如果提供，必须是 `github`；
10. `controlPlane.repository` 必须是有效的 `owner/repository` 形式。

缺失或非法配置会抛出以 `Codex Dispatch 配置错误：` 开头的中文异常。例如：

```text
Codex Dispatch 配置错误：找不到配置文件：...
Codex Dispatch 配置错误：workspace.root 不存在或不是目录：...
Codex Dispatch 配置错误：controlPlane.repository 格式无效：...
```

## 安全边界

- 不要把 GitHub token、Codex 登录信息或 Runner 身份材料放入 `config.local.json`；
- 不要将 `config.local.json` 放在 GitHub Actions Runner 的安装或凭据目录中；
- 不要把真实生产路径写入 `config.example.json`；
- 客户端或 workflow 应只使用加载后的配置对象，不应从用户任务文本生成本机路径；
- 加载器拒绝敏感文件名和配置 symlink，但不能判断普通 JSON 字段是否被人为填入了秘密；提交前仍需 secret scanning。

## 运行最小测试

从仓库根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
    -File .\tests\Test-Load-CodexDispatchConfig.ps1
```

测试使用系统临时目录中的合成配置，覆盖正常配置、缺失配置、非法工作区路径、模板误用、敏感文件拒绝和非法 GitHub 仓库格式。测试结束会删除自身创建的临时目录。
