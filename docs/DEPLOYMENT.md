# 从零部署指南

> 面向**拿到这份代码、想自己搭一套**的人。
> 你不需要信任我提供的任何服务 —— 域名、邮箱、账号全部自己来，本工具只是个壳。
>
> 本仓库**不包含任何密钥、密码、账号数据**。所有数据只存在你自己机器的
> `~/Library/Application Support/TypelessSwitchboard/` 与 macOS Keychain 里。

---

## 0. 先搞清楚这套东西由什么组成

```
┌─────────────────────────┐
│  Typeless Switchboard   │  ← 本仓库，macOS App，装在你电脑上
│  （本工具）              │
└────────┬────────────────┘
         │ HTTPS
         ▼
┌─────────────────────────┐
│  邮箱 API（自建）         │  ← 你要搭的部分，用来收注册验证码
└────────┬────────────────┘
         │ 收信
         ▼
┌─────────────────────────┐
│  你的域名 + DNS          │  ← 你要买的部分
└─────────────────────────┘
```

**三样东西，缺一不可**：

| 组成 | 你要做什么 | 成本 |
|---|---|---|
| 一个域名 | 买一个，DNS 托管到 Cloudflare | 约 ¥30~80/年（.xyz / .top 更便宜） |
| 一个能收信的邮箱 API | 部署 Cloudflare Worker（下文有完整代码） | **免费**（Cloudflare 免费额度足够） |
| Typeless 账号 | 用生成的邮箱去官网注册 | 免费额度每周 8000 字 |

---

## 1. 买域名

### 在哪买

| 场景 | 推荐 | 说明 |
|---|---|---|
| 只想便宜、不备案 | **Cloudflare Registrar** | 按成本价卖，无溢价，[cloudflare.com/products/registrar](https://www.cloudflare.com/products/registrar/) |
| 国内常用 | 阿里云 / 腾讯云 | 注意：如果 DNS 要托管到 Cloudflare，注册商是谁无所谓 |
| 海外常用 | Namesilo / Porkbun / Spaceship | 常含免费隐私保护 |

> 后缀随便选，`.xyz` `.top` `.cc` 通常最便宜。**不需要备案** —— 你只是收信，不建网站对外服务。

### 买完之后：把 DNS 托管到 Cloudflare

1. 注册 [Cloudflare](https://dash.cloudflare.com/sign-up) → **Add a Site** → 输入你的域名
2. 选 **Free** 套餐
3. Cloudflare 会给你两个 Nameserver 地址（形如 `xxx.ns.cloudflare.com`）
4. 去你的域名注册商后台，把 **Nameserver（DNS 服务器）** 改成这两个
5. 回 Cloudflare 等生效，通常 5 分钟~24 小时（页面会自动检测）

> ⚠️ 改完 Nameserver 后，**域名的 DNS 记录由 Cloudflare 管了**。
> 原来在注册商那里加的记录不会自动带过来，需要的话手动重新加。

---

## 2. 让域名能收信（关键一步）

这一步决定「发给 `*@你的域名.com` 的邮件会不会进你的 Worker」。

### 2.1 开启 Cloudflare Email Routing

1. Cloudflare 控制台 → 你的域名 → **Email** → **Email Routing**
2. 点 **Get Started**，Cloudflare 会自动帮你加好需要的 MX 记录
3. 确认 **Routing Rules** 里已经有 Catch-All 规则（后面会改它的 Action）

### 2.2 需要哪些 DNS 记录

开启 Email Routing 后，Cloudflare 会自动加这几条。**如果你是自己搭邮局，这些要手动加**：

| 类型 | 名称 | 值 | 作用 |
|---|---|---|---|
| MX | `@` | `route1.mx.cloudflare.net` (优先级 1) | 告诉别人往哪发信 |
| MX | `@` | `route2.mx.cloudflare.net` (优先级 11) | 备份 |
| MX | `@` | `route3.mx.cloudflare.net` (优先级 53) | 备份 |
| TXT | `@` | `v=spf1 include:_spf.mx.cloudflare.net ~all` | SPF：声明哪些服务器被授权用你的域名发信 |
| TXT | `*._domainkey` | （Cloudflare 生成 DKIM 后给出） | DKIM：给信件签名，防伪造 |
| TXT | `_dmarc` | `v=DMARC1; p=none;` | DMARC：告诉收件方收到伪造信怎么办 |

**三个概念一句话说明**：
- **SPF**：「这几台服务器发出的信才算我发的」
- **DKIM**：「信封上有我的签名，你验一下」
- **DMARC**：「验不过的信，你按我说的处理（p=none 是只报告不拦截）」

> 你只是**收**验证码，SPF/DKIM/DMARC 主要影响你**发**信的可信度。
> 收信侧只要有 MX 就能工作。但加了没坏处，能提高验证码邮件不被判垃圾的概率。

---

## 3. 部署邮箱 API

### 3.1 这个 API 是什么

本工具需要你的邮箱服务提供 4 个接口。鉴权头统一是 **`X-API-Key`**。

| 方法 | 路径 | 用途 | 返回 |
|---|---|---|---|
| GET | `/api/config` | 自检 + 取可用域名 | `{"domains":["your.com"]}` |
| GET | `/api/emails` | 列出已有邮箱 | `{"emails":[{"id":"..","address":".."}]}` |
| POST | `/api/emails/generate` | 生成一个随机邮箱 | `{"id":"..","address":"..","domain":".."}` |
| GET | `/api/emails/{id}` | 取该邮箱收到的邮件 | `{"messages":[{"id","subject","from","createdAt","text"}]}` |

响应字段名有容错：邮件对象认 `id/_id/messageId`、正文认 `text/body/content/preview`、
时间认 `createdAt/receivedAt/date`，**用哪个都行**（见 `SwitchboardStore+MoeMailHTTP.swift`）。

> ⚠️ 早期版本的 README 把接口 D 写成了 `/api/messages`，与真实实现不符，照抄会跑不通。
> 正确路径是 **`/api/emails/{id}`**。

### 3.2 方案 A：直接用开源项目 MoeMail（推荐）

**MoeMail** 是现成的开源临时邮箱，本工具的配置项 `moeMailBaseURL` 就是为它设计的：

- 仓库：<https://github.com/beilunyang/moemail>
- 技术栈：Next.js + Cloudflare Pages + D1 + KV + Email Worker
- 有 Web 界面，能自己建邮箱、看收件箱

按它的 README 部署到 Cloudflare 即可，然后把地址填进本工具的 `moeMailBaseURL`。

### 3.3 方案 B：Cloudflare Worker 自建（约 100 行）

不想跑完整项目的话，用下面这段 Worker 就够本工具用了：

1. Cloudflare → **Workers & Pages** → **Create** → **Create Worker**
2. 命名 `typeless-moemail-backend` → **Deploy**
3. **Edit Code**，把下面代码整段贴进去 → **Deploy**
4. **Settings** → **Variables** → 加两个环境变量：
   - `API_KEY`：你自己想一个长随机串
   - `DOMAIN`：你的域名

完整代码见 [README.md → 1分钟极速自建方案](../README.md#2-️-1分钟极速自建方案-基于-cloudflare-workers-免费部署)。

### 3.4 把收到的信转给 Worker

1. Cloudflare → 域名 → **Email** → **Email Routing** → **Routing Rules**
2. 编辑 Catch-All 规则：
   - **Action** 选 **Send to Worker**
   - **Worker** 选 `typeless-moemail-backend`
3. 保存

### 3.5 验证

```bash
export MAIL="https://mail.你的域名.com"
export KEY="你设置的 API_KEY"

# 1) 自检
curl -s -H "X-API-Key: $KEY" "$MAIL/api/config"
# 期望：{"domains":["你的域名.com"]}

# 2) 生成邮箱
NEW=$(curl -s -X POST -H "X-API-Key: $KEY" "$MAIL/api/emails/generate")
echo "$NEW"   # 期望含 address 字段

# 3) 往这个地址发一封邮件，然后取信
ID=$(echo "$NEW" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -H "X-API-Key: $KEY" "$MAIL/api/emails/$ID"
# 期望：{"messages":[{...}]}
```

> 上面三条全通了，邮箱这层就齐了。**建议先做这一步再往下走**，
> 否则后面工具报「未取到验证码」时你分不清是邮箱没通还是注册流程的问题。

---

## 4. 关于 25 端口（中国大陆用户注意）

**先说结论：按本文的 Cloudflare 方案，你完全不需要 25 端口。**

原因：收信只需要 **MX 记录** 指向 Cloudflare，入站连接由 Cloudflare 接受。
你的服务器/Worker **从不主动发起 SMTP 连接**，也就用不到 25 出方向。

什么情况才会踩到这个坑：

| 方案 | 要不要 25 出方向 | 国内云厂商是否受影响 |
|---|---|---|
| Cloudflare Email Routing + Worker（本文方案） | ❌ 不需要 | 不受影响 |
| 自建邮局（Mailu / Poste.io / docker-mailserver） | ✅ 发信需要 | **受影响** —— 阿里云/腾讯云/华为云默认封 25 出方向 |
| AWS SES / Resend 等 SaaS | ❌ 不需要（走 HTTPS API） | 不受影响 |

如果你非要自建邮局：
- 阿里云/腾讯云可申请解封 25（通常在工单里，成功率不高，且要求有备案域名）
- 或者用 **SMTP Relay**（走 587/465 端口借道第三方发信）绕开
- 或者干脆只收不发 —— 收信走 993/995 或 Cloudflare，发信交给 SaaS

---

## 5. 安装本工具

```bash
git clone https://github.com/fufu1209/Typeless.git
cd Typeless
./scripts/build-app.sh --install
```

需要 macOS 13+ 与 Swift 6（Xcode 命令行工具即可）。

### 5.1 填配置

打开 App → **注册与邮箱** tab：

| 配置项 | 填什么 |
|---|---|
| MoeMail 服务地址 | 你的 API 地址，如 `https://mail.你的域名.com` |
| MoeMail API Key | 第 3.3 步设置的 `API_KEY` |
| 邮箱域名 | 你的域名 |

填完点「同步域名」，能拉到域名列表就说明通了。

### 5.2 授权

App → **自检排障** tab，把需要的权限都开了：

| 权限 | 干什么用 |
|---|---|
| 辅助功能 | 控制 Typeless 界面（一键换号流程） |
| 自动化 | 用 AppleScript 驱动浏览器完成注册 |
| 输入监听 | 让 Typeless 能全局唤起 |
| 麦克风 | 语音输入本身 |

> 权限是 macOS 系统级的，只能在「系统设置 → 隐私与安全性」里开，App 无权自己打开。

---

## 6. 关于 Typeless 的周额度

**官方口径**（[typeless.com 定价页](https://www.typeless.com/pricing)）：免费版每周 8,000 字。

**额度怎么刷新，官方没有明确说明** —— 定价页与账单 FAQ 都只写「每周」，
没有说「周一 00:00」还是「注册满 7 天」。

本工具的处理方式：

- 默认按**自然周（周一 00:00）**排程
- 但它**会自己观测**：每次拿到新鲜额度就采样，发现数值骤降就记一次真实重置，
  看它落在周一还是散落在七天里，攒够样本后自动校准口径
- 在「额度守护」tab 底部可以看到当前结论：**「周期口径待确认（已观测 N 次）」** 或
  **「已确认按自然周刷新，依据 N 次实测」**
- 如果你的系统时区与实际所在地不一致，那里还能一键改「刷新时区」，**不用重启**

> 换句话说：这件事本工具不替你下定论，它自己学着看，看明白了告诉你。

---

## 7. 常见问题

**Q：一定要 Cloudflare 吗？**
不一定，但最省事。任何能收信 + 提供上述 4 个接口的服务都行，包括你自己写的。

**Q：免费额度够用吗？**
Cloudflare Worker 免费版 10 万请求/天，Email Routing 免费。个人用远远够。

**Q：注册时取不到验证码？**
按顺序排查：① 第 3.5 步的三条 curl 是否全通；② 域名 MX 是否生效
（`dig MX 你的域名.com`）；③ Catch-All 规则的 Action 是不是 **Send to Worker**；
④ 验证码邮件可能被判垃圾，去邮箱原始内容里看。

**Q：换台电脑怎么办？**
App →「账号池」→「导出完整配置包」（或用 CLI `--export-full-bundle`），
新机器导入即可。注意密码在 Keychain、登录态与设备绑定，这两样要在新机器上重建。

---

## 附：相关链接

- MoeMail 开源项目：<https://github.com/beilunyang/moemail>
- Cloudflare Email Routing 文档：<https://developers.cloudflare.com/email-routing/>
- Cloudflare Workers 文档：<https://developers.cloudflare.com/workers/>
- Typeless 官网：<https://www.typeless.com>
