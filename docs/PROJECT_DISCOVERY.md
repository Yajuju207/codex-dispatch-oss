# Project Discovery Engine v0.1

`scripts/Discover-CodexProjects.ps1` 从本机 `config.local.json` 读取工作区设置，并发现该工作区内的本地 Git 项目。它面向 Windows PowerShell 5.1，不访问网络，也不更改仓库。

## 使用方式

在包含 `config.local.json` 的目录中运行：

```powershell
.\scripts\Discover-CodexProjects.ps1
```

也可以显式指定配置文件，并将同一结果写为 JSON：

```powershell
.\scripts\Discover-CodexProjects.ps1 `
    -ConfigPath .\config.local.json `
    -OutputPath .\projects.json
```

脚本复用 `Load-CodexDispatchConfig.ps1`。`config.example.json` 仍然只是模板，不能作为运行配置。唯一获准的扫描根目录是加载器返回的 `workspace.root`。

## 扫描规则

- `workspace.scanDepth=1` 时只检查 `workspace.root` 的直接子目录。
- 更大的值只允许继续进入尚未发现 `.git` 标记的分组目录，最大值为 32。
- 名为 `.git` 的目录（Windows 下大小写不敏感）永远不会进入扫描队列，也不会被识别为项目或枚举其内部内容。
- 一旦目录包含 `.git` 文件或目录，它就是候选项；脚本不会枚举其源码内容，也不会进入 `.git`。
- 不含 `.git` 的目录不会产生结果记录。
- 候选项按目录名排序；同名项再按规范化本地路径排序，因此输出稳定。
- 脚本只运行本地只读命令：`git rev-parse --show-toplevel` 和 `git remote get-url origin`。不会运行 fetch、pull、push，也不会访问远端。

## 状态与字段

每条记录包含：

- `name`：候选目录名。
- `localPath`：候选目录的规范化绝对路径。
- `status`：`ok`、`invalid_git` 或安全拒绝状态 `unsafe_path`。
- `gitRoot`：Git 验证得到的工作树根目录；无法验证时为 `null`。
- `origin`：本地 Git 配置中的 origin；不存在时为 `null`。HTTPS user-info 会在输出前移除。
- `githubRepository`：可识别 GitHub 地址对应的 `owner/repository`；非 GitHub、缺失或无法解析时为 `null`。
- `reason`：非 `ok` 状态的简短原因。

目录仅有 `.git` 标记但不是有效工作树时，脚本返回 `invalid_git`，而不是抛出 Git 的原生错误。

v0.1 支持以下 GitHub origin 格式：

```text
https://github.com/owner/repository.git
https://github.com/owner/repository
git@github.com:owner/repository.git
ssh://git@github.com/owner/repository.git
```

## 路径与 reparse point 安全

每个候选目录和 Git 返回的工作树根目录都必须位于规范化的 `workspace.root` 内。v0.1 采取保守策略：

- `workspace.root` 本身是 reparse point 时停止并报告统一项目发现错误。
- 子目录是符号链接、junction 或其他 reparse point 时，发出警告并跳过，不遍历目标。
- `.git` 标记是 reparse point 时返回 `unsafe_path`，且不调用 Git。
- 普通 `.git` 文件的 `gitdir:` 会在调用 Git 前解析；目标必须存在、位于 `workspace.root` 内且整条路径链不含 reparse point，否则分别返回 `invalid_git` 或 `unsafe_path`。

因此，即使配置允许 reparse point，发现器也不会借其越过扫描根目录。

## JSON 输出

`-OutputPath` 的父目录必须已经存在且不能是 reparse point。如果输出文件已经存在且自身是 reparse point，脚本会拒绝写入。文件使用 UTF-8（无 BOM）写入，JSON 顶层始终为数组：一个项目仍是单元素数组，没有项目则是 `[]`。

不指定 `-OutputPath` 时，脚本只向成功输出流返回 PowerShell 对象，不创建文件。配置、路径和运行错误统一以 `Codex Dispatch 项目发现错误：` 开头。

## 隐私边界

发现器不读取源码文件、Git 对象内容、环境文件、运行器目录或身份材料，也不把机器专属路径写入仓库文档。`localPath` 和 `gitRoot` 只存在于本机运行结果中；是否将导出的 JSON 分享到其他系统由操作者自行决定。
