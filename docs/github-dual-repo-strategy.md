# GitHub 双版本策略：公开版 vs 私密版

> v2.5.2 引入。回应用户原问：「分享给其他小伙伴用 → 公开版也要保持更新」、「我自己长期存储的版本 → 私密版」。

## 一、结论先行：推荐"单一仓库 + 两类 Release"

**不是**两个独立 repo，**而是同一份代码 + 两类 GitHub Release**：

- 仓库始终保持公开（这样你的项目能被发现、star、贡献）
- Release 分两类：
  - `private-v2.x.x` —— 给你自己用的：包含全量配置包示例、个人备份
  - `public-v2.x.x` —— 公开版：只附脱敏示例包（`kind: publicEdition`）

**为什么不推荐两个独立 repo**：

1. 同步成本翻倍（每次 commit 要推两个地方）
2. 公开版如果忘记同步，PR/issue 跑到落后版本上
3. 朋友发现仓库后一眼能看出"我用的就是最新版"——体验更顺

**为什么必须保持单一 repo**：

- Typeless Switchboard 是 macOS 单机工具，不带服务端，所有"功能"都在 `.app` 里
- 你的「个人数据」只存在你本机的 `~/Library/Application Support/TypelessSwitchboard/store.json` 和 keychain 里，**代码 repo 里本来就不应该有任何 PII**
- 公开版代码 ≠ 公开你的数据 —— 数据走配置包导出来传播，不走仓库

## 二、仓库结构

```
fufu1209/Typeless.git         ← 唯一仓库，始终公开
├── Sources/                  ← 完整代码（公开）
├── Tests/                    ← 完整测试（公开）
├── docs/                     ← 完整文档（公开）
├── scripts/                  ← 构建脚本（公开）
├── templates/                ← AppIcon.svg 等
├── Resources/AppIcon.icns
├── README.md                 ← 主文档，公开
├── LICENSE                   ← 选 MIT（推荐）或 Apache 2.0
├── .gitignore                ← 排除 store.json、keychain、.app
├── docs/github-dual-repo-strategy.md   ← 本文件
└── releases/                 ← release 资产（git lfs 或 GitHub Release）
    ├── private-v2.5.2.zip   ← 你自己用的：含真实配置示例、完整排障包
    └── public-v2.5.2.zip   ← 给朋友的：含脱敏示例、README 强调「先配 MoeMail Key」
```

## 三、必须强制执行的"不提交 PII"规则

**.gitignore 关键项**（本仓库已设）：

```gitignore
# 用户专属数据（v1.1.0 时误提交的硬编码 /Users/fucaixie/BC/... 已删）
.DS_Store
*.log
*.app/
.build/
DerivedData/

# 任何包含真实邮箱 / 密码 / token 的文件
**/store.json
**/*.real-config.json
**/personal-*
**/secrets.*
**/env.local
**/.envrc
```

**README 顶部加声明**：

> ⚠️ 本仓库**只包含代码**，不包含任何用户的账号、密码、token、配置。
> 你的所有数据保存在你本机的 `~/Library/Application Support/TypelessSwitchboard/` 和 macOS Keychain。
> 「公开版」和「私密版」的差别仅在 **Release 附带的示例配置包**：
> - `public-v*.zip` 的示例包是脱敏的（`demo1@example.com`），可放心分发
> - `private-v*.zip` 的示例包含你真实账号的备份，**只给你自己用**

## 四、release 自动化（GitHub Actions）

`/Users/fucaixie/WorkBuddy/Worktrees/Typeless/main-fb72c3e3/.github/workflows/release.yml`（待建）：

```yaml
name: Release
on:
  push:
    tags: ['v*.*.*']

jobs:
  build:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: 编译 + 测试
        run: |
          swift build -c release
          swift run OperationalFeatureChecks
          bash scripts/test-operational-features.sh
      - name: 打包 .app
        run: bash scripts/build-app.sh --install
      - name: 生成脱敏示例包（自动）
        run: |
          # 在 CI 上用一个临时账号池跑一遍 exportPublicBundle
          # 或者直接放一个 example/public-sample-bundle.json 到仓库
          cp templates/public-sample-bundle.json release-assets/
      - name: 准备私密 release 资产
        run: |
          # 私密资产由你本机构建后手动上传（Action 不接触你的真实 store.json）
          echo "请手动上传你的 private-v*.zip 到 Release 页"
      - name: 公开 Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            TypelessSwitchboard.app.zip
            release-assets/public-sample-bundle.json
          body_path: RELEASE_TEMPLATE.md
```

## 五、给别人用的最小步骤

你的朋友拿到 `public-v2.5.2.zip` 后：

1. 解压得到 `TypelessSwitchboard.app`
2. 拖到 `/Applications/`
3. 打开 → 第一次会弹 keychain 授权（点"始终允许"）
4. 切到「注册与邮箱」tab → 填他自己的 MoeMail API Key
5. 切到「账号池」tab → 「导入配置包」→ 选 `public-sample-bundle.json`
   - 他会得到一组 `demo1@example.com` 占位账号，可看清结构
6. 他按自己的需求生成新账号、调整阈值

**关键**：朋友的 keychain 和 store.json 与你的完全独立，互不干扰。

## 六、私密版怎么留档

你的私密备份**不进 repo**，而是：

- 定期跑「导出完整配置包」→ 文件落到 `~/Downloads/TypelessSwitchboard-bundle-full-YYYYMMDD-HHMMSS.json`
- 备份到你的私有网盘（iCloud Drive / 自己的 Cloudflare R2 / OneDrive）
- **绝不**把这些文件 commit 到任何 repo
- 包含敏感内容的文件**必须**用 `git filter-repo` 或 BFG 清理历史（如果误提交过）

## 七、当前状态

| 状态 | 完成 |
|---|---|
| 公开版 / 私密版 文件结构划分 | ✅（v2.5.2） |
| 脱敏导出 `exportPublicBundle` | ✅（v2.5.2） |
| 完整包导入去重 | ✅（v2.5.2） |
| 307 条真实断言 | ✅（v2.5.2） |
| Release 工作流 | ⏳ 待建 |
| README 顶部 PII 声明 | ⏳ 待补 |
| LICENSE 选型（MIT/Apache2） | ⏳ 待决定 |
| 切到 GitHub 个人版/企业版 connector 验证 release API | ⏳ |

## 八、与用户原话的对应

> **用户原文**：「1. 一份是我们自己长期存储的个人隐私版，包含所有配置文件和配置信息 2. 另一份是公开版，公开版也要同时保持更新 这样处理你觉得会不会好一点？」

**回答**：方案可用，但更优解是**单 repo + 两类 Release**，原因：
- 单一 repo → 公开版天然保持最新（git push 即同步）
- 两类 Release → 私密版用你自己的备份链（iCloud / R2），不污染仓库
- 公开版配置包永远从代码自动生成（脱敏），不可能泄露真数据
- 你的真实数据**从来就不在仓库里**（store.json 在 gitignore 里）—— 这条铁律
