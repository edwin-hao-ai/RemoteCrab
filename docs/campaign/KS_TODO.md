# Kickstarter 上线待办清单

> 生成时间：2026-09-29
> 项目草稿：https://www.kickstarter.com/projects/1755279085/1224057860
> 状态：**未上线、未提交审核、未公开**（KS 确认 "Nothing is public until you launch"）

这份文档只写**还需要你做的事**。已经完成的部分在最后一节。

---

## 🔴 阻塞项（不做就上不了线）

### 1. 上传两个视频

**为什么我做不了**：Kickstarter 的上传走 XHR + 进度条，程序化注入文件会触发上传但被服务器拒绝（页面显示 "upload failed"，网络抓包显示请求根本没发出）。我试了 `upload` 工具和 CDP `DOM.setFileInputFiles` 原生 API，两种都失败。**必须你手动拖。**

| 位置 | 文件 | 规格 |
|---|---|---|
| **Project video** | `/tmp/ks-promo.mp4` | 1920×1080 · 3.3MB · 56s |
| **Discovery video** | `build/ks-graphics/discovery-9x16.mp4` | 1080×1920 · 2.0MB · 56s |

路径：
- Project video 备用：`~/Videos/RemoteCrab/final/remotecrab-promo-50s-en.mp4`（16MB 原版）
- Discovery video 绝对路径：`/Users/edwinhao/iBridge/build/ks-graphics/discovery-9x16.mp4`

**操作提示**：
- Project video 的上传框可能需要先把那一段**滚进视口**才会渲染出来
- 上传后 KS 建议用它的编辑器加字幕/翻译（视频本身已有英文字幕）
- 如果 3.3MB 那版报 failed，试 16MB 原版

---

### 2. 建 5 个 Reward tiers

**为什么我做不了**：填了标题、描述、金额、上限，但 Save 按钮**点下去没有任何反应也没有报错**。我定位到是缺少 `Digital reward (no shipping)` 这个必选 radio，不勾它 Save 静默失败；勾了之后仍然不保存。试过 JS 点击和 CDP 原生鼠标事件两种方式。**建议手动建。**

**必勾项**（不勾就静默失败）：每一档都要选 **`Digital reward (no shipping)`**

| 档位 | 价格 | 上限 | 勾选 |
|---|---|---|---|
| Digital Supporter | $1 | 不限 | Digital reward |
| Founding Member | $39 | 1,000 | Digital reward + **Limited** |
| Founder's Edition | $149 | 200 | Digital reward + **Limited** |
| Studio | $399 | 50 | Digital reward + **Limited** |
| Team | $999 | 20 | Digital reward + **Limited** |

**描述文案**：`docs/campaign/KS_REWARDS.html`（每档一个 `<h2>` 块，格式已适配 KS 编辑器）

**Items 已建好**（Rewards → Items tab，6 个，可直接勾选关联）：
Perpetual Pro licence (personal) / Roadmap vote / Numbered CNC aluminium badge / Founder badge in app / Private supporter channel / Roadmap call (quarterly)

⚠️ **一个待你决定的取舍**：$149 档的铝制徽章需要配置运费（实体物不能选 Digital reward）。两个方案：
- **A**：$149 纯数字权益，铝徽章挪到单独一档 $199 或作为 $35 加购
- **B**：$149 含徽章，选 "Ships to anywhere" 并填运费（最终到手价变高，可能影响转化）

我倾向 **A**，两档转化率互不干扰。

---

### 3. Payment 验证

**为什么我做不了**：银行账户 + 税表 + 证件属于法律和财务凭据，必须你本人填写。

需要准备（**全部在实体名下、且账户国家 = 美国**）：

- [ ] 美国 checking account（支持 direct deposit，**不接受 wire / 储蓄账户 / 虚拟银行**）
- [ ] W-9（公司填 EIN，个人填 SSN/ITIN）
- [ ] 政府签发证件（股东/实控人护照或驾照）
- [ ] 实体名下信用卡
- [ ] 公司注册文件（articles of organization / EIN 确认函 CPN 或 147C）

⚠️ **最大的未知数**：KS 条款要求项目国家、实控人证件、居住地一致。如果你的美国公司是**通过非美国本地设立**的（比如母公司或实控人仍在中国），实控人证件可能过不了。**如果卡在这里，改用香港主体**（Indiegogo 对创建者所在地更宽松，没有这个限制）。

---

### 4. AI 披露必答项

Kickstarter 新增的强制问题：
> Will your project involve the development of AI technology or use AI content?

**必须如实勾选，否则审核会被退回。** 你的产品实际用到：
- SFSpeechRecognizer / on-device SpeechAnalyzer（语音识别）
- 路线图里的 AI agent 路由

三个选项：
- `My project seeks funding for AI technology.` — 主张是为 AI 技术募资
- `I plan to use AI-generated content in my project.` — 主张会用 AI 生成内容
- **`I am incorporating AI in my project in another way.`** — 我倾向这个（语音识别 + agent 集成）

这是法律声明，请你自己判断。

---

## 🟡 建议在上线前处理

### 5. 修正项目地点

**Basics → Project location**，现在填的是 **San Francisco, CA** —— 这是我**猜的**，我不知道你美国公司在哪个州。

### 6. 决定用哪张 Project image

Kickstarter 明确警告：
> "Avoid images with banners, badges, or text — they are illegible at smaller sizes, and can be penalized by the Facebook algorithm."

我准备了两版，**当前上传的是带文字版**：

| 版本 | 文件 | 取舍 |
|---|---|---|
| **A 带文字**（当前） | `00-project-hero-1024x576.png` | 浏览流里冲击力强，但可能被算法降权 |
| **B 无文字** | `00-project-hero-notext-1024x576.png` | 安全，但卡片本身平淡（靠标题和副标题传达） |

替换位置：Basics → Project image → 图片下方的上传/删除按钮

### 7. 官网同步定价表

**这条有硬时限。** Story 里写了 "$39 during the campaign, $99 after" 和"上线前注册的用户 Pro 免费用 12 个月"。

这个承诺**必须在上线前就出现在官网上**，事后补就是 bait-and-switch，是最容易被公开声讨的翻车方式。

- [ ] 官网加上 `docs/campaign/KICKSTARTER_REMOTE_CRAB.md` §4.5 的定价表
- [ ] 官网加上"上线前注册 → Pro 免费 12 个月"的承诺，并开始收集注册
- [ ] 这条同时是 pre-launch 名单的来源（见下一节）

---

## 🟢 上线前 30 天的准备（决定成败）

### 8. Pre-launch 名单 —— 这是成败的唯一决定因素

**残酷的算术**：$39 均价、目标 $25,000 = 需要约 640 个 backer。这需要 **3000–5000** 的 pre-launch 名单（按 5–8% 转化率）。现在手上大概只有需求量的 1/5 到 1/10。

- [ ] 在官网加邮件收集（同时承接第 7 条的注册承诺）
- [ ] 建 Kickstarter pre-launch 页，收集 "notify me"
- [ ] 目标：上线前 **3000+ 关注者**（低于 1000 达不到目标）
- [ ] Product Hunt / 少数派 / V2EX 各跑一轮 —— 这是免费的流量池

### 9. 上线时间

- **硬闸门：iOS 1.0 没过审不要上线。** 你的 1.0 现在还在 WAITING_FOR_REVIEW，backer 点进 App Store 看到空白页会当成骗局。
- KS 数据显示 30 天以内的活动成功率更高（已设 30 天）
- 建议**周二或周三**上午 9:00 PT 上线
- 目标：10 月中下旬（审核通过后推 6–8 周）

### 10. 税务

募资进美国实体是**美国税务申报事件**（视实体类型可能涉及 1099-MISC），汇回中国是另一笔境内税务。**上线前找会计师确认，别等钱到账再处理。**

### 11. 铝制徽章加工报价

$149 档含实体徽章，需要提前拿到加工报价——这个报价是真实成本，要算进预算。**上线前就要拿到，不是活动开始后。**

---

## ✅ 已完成（无需再动）

| 项目 | 验证方式 |
|---|---|
| 分类 Technology / Apps（附加 Software） | 刷新确认 |
| 国家 the United States | 刷新确认 |
| 标题 + 副标题 | 刷新确认 |
| 目标金额 $25,000 | 刷新确认 |
| 活动周期 30 天 | 刷新确认 |
| Project image（带文字版） | 截图确认 |
| Story 正文 5350 字符 | 刷新确认 |
| Story Risks 1495 字符 | 刷新确认 |
| Story 内 3 张叙事图（各 659×412） | 刷新确认 |
| FAQ 4 组 | 刷新确认 |
| Items 6 个 | 刷新确认 |
| TEST LINE 残留已清除 | 刷新确认 |

---

## 📁 素材位置

```
/Users/edwinhao/iBridge/
├── build/ks-graphics/                        ← 所有图片和竖版视频
│   ├── 00-project-hero-1024x576.png          ← 当前上传的卡片图
│   ├── 00-project-hero-notext-1024x576.png   ← 无文字备选
│   ├── 00-discovery-9x16.png
│   ├── 01-agent-router.png                   ← Story 已插入
│   ├── 02-peripherals.png                    ← Story 已插入
│   ├── 03-context-modes.png                  ← Story 已插入
│   └── discovery-9x16.mp4                    ← Discovery 竖版视频
├── scripts/
│   ├── kickstarter-graphics.py               ← 5+1 张图，可重跑
│   └── kickstarter-discovery-video.sh        ← 竖版视频，可重跑
├── docs/campaign/
│   ├── KICKSTARTER_REMOTE_CRAB.md            ← 完整文案 + 上线检查表
│   └── KS_REWARDS.html                       ← 5 档描述，复制粘贴用
└── ~/Videos/RemoteCrab/final/
    └── remotecrab-promo-50s-en.mp4           ← 主视频原版（16MB）
```

**图片素材全部来自 `build/asc-raw/` 的真机截图**，没有用 `screenshots/` 那批 V0.2 设计 mockup（老 iBridge 品牌 + macOS 紫色 aqua 风格，backer 一眼能看出是渲染图）。

---

## ⚠️ 最后一件事：提交审核前请通读全文

**"Mac" 这个词在 Kickstarter 上可以用**（课 53 的 5.2.5 是 App Store 审核的规则，第三方平台不适用，这是指代第三方产品的正当使用）。但 **App Store 提交的那份文案必须继续用"电脑"** —— 两套话术，不要互相污染。

另外 Story 里有一段刻意写的风险声明（Apple 竞争 / 私有 API / 单人项目 / 日期承诺），语气偏直接。**这是刻意的** —— 行业数据表明承诺型文案对软件众筹无效甚至有害，backer 读到的是"这人在说实话"。但你上线前应该自己读一遍，确认接受这个语气。
