# ChatWeave 协议规范（草案 0.1）

> **状态：草案。** 本文是 ChatWeave 的语言无关协议说明，机器可读的定义在 [`schemas/v0.1/`](../schemas/v0.1/)（JSON Schema draft 2020-12）。两者不一致时以 Schema 为准，并当作缺陷修正。0.x 期间的小版本升级**可能**含破坏性变化，1.0 之后遵守语义化版本。

本文中的关键词“必须 / 不得 / 应当 / 可以”分别对应 RFC 2119 的 MUST / MUST NOT / SHOULD / MAY。

## 0. 三个协议，v1 实现哪些

| 协议 | 回答的问题 | v1（协议 0.1） |
|---|---|---|
| **Content 协议** | Agent 想表达什么（事实、语义） | ✅ 完整实现：消息、内容块、流式事件 |
| **View 协议** | 这些内容怎么排版（组件组合、布局） | ⏸ 只保留字段名（`message.view`、事件 `view.*`），不实现；见第 8 节 |
| **Action 协议** | 用户在界面上的操作怎么回到服务端 | ✅ 最小受控集合：选项选择、确认 / 取消、表单提交 |

v1 里“语义类型 → 组件”的映射是**客户端注册表上的确定性映射**（查表，不调用模型），没有 UI Agent。

## 1. 基本约定

- **编码**：UTF-8 JSON。字段名用 lowerCamelCase（与 A2UI 一致）；块类型、枚举值用 snake_case。
- **ID**：助手 / 系统消息的 `id` 只由服务端生成；用户消息的 `id` 由发送端（客户端）生成，兼作离线排队与重发的幂等键（见第 2 节，[D43](decisions.md)）。两者都推荐 UUIDv7（按时间排序的 UUID）。`blockId` 在所在消息内唯一且**稳定**——一旦分配，不得改指别的块，补丁、动作都按它定位。
- **时间**：ISO 8601（RFC 3339）带时区的 `date-time`，或纯日期 `date`。整个协议只用这一种时间编码，不混用 epoch 毫秒等其他形式；宿主内部用什么格式，进出协议时统一转换。
- **数字**：原始数值，不预先格式化。金额可以用“最小货币单位整数”（例如“分”）并在 `format.minorUnits = true` 中声明，避免浮点误差。
- **宽进严出**：生产方（服务端）必须按 Schema 严格校验后才能发出或持久化；消费方（客户端）解析时忽略未知字段，遇到解析不了的块就用纯文本兜底（第 6 节），**不得因为一个块失败让整条消息失败**。

## 2. 消息（Message）

一条消息 = 有序的内容块列表 + 一段必有的纯文本兜底。定义见 [`message.schema.json`](../schemas/v0.1/message.schema.json)。

```json
{
  "id": "01J9Z8M5V7Q2W3E4R5T6Y7U8I9",
  "protocolVersion": "0.1",
  "conversationId": "conv_42",
  "role": "assistant",
  "status": "complete",
  "rev": 1,
  "createdAt": "2026-10-26T09:30:00Z",
  "completedAt": "2026-10-26T09:30:04Z",
  "fallbackText": "北京今天晴，最高 18°C……（完整纯文本）",
  "blocks": [ { "id": "b1", "type": "markdown", "schemaVersion": 1, "data": { "text": "北京今天**晴**。" } } ],
  "metadata": { "traceId": "…" }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 消息 ID。用户消息由发送端生成（至少 8 个字符，推荐 UUIDv7）；助手 / 系统消息由服务端生成 |
| `protocolVersion` | ✅ | 生成这条消息时使用的协议版本，例如 `"0.1"` |
| `conversationId` | | 宿主的会话标识，库只当作不透明字符串 |
| `role` | ✅ | `assistant` / `user` / `system`。用户消息通常只有一个 markdown 块 |
| `status` | ✅ | `streaming`（生成中）/ `paused`（运行在等用户回答一个中断，回答后**同一条消息**继续，见 4.8）/ `complete`（正常结束）/ `interrupted`（中途停止，已产出的内容保留）/ `error`（没有可用内容，`fallbackText` 说明原因） |
| `blocks` | ✅ | 内容块，最多 64 个 |
| `fallbackText` | ✅ | **整条消息的纯文本版本，任何状态下都必须有**。用于只会显示文本的客户端、系统通知、读屏、搜索 |
| `rev` | ✅ | 持久化版本号：没结束时（生成中、暂停中）为 0；完成时为 1；之后每次变化（例如选项块被回答）+1。**同步时 rev 大的版本获胜** |
| `lastSeq` | | 只出现在没结束的消息的检查点上（`rev = 0`）：这个版本折叠到了哪个 `seq`。暂停中必填。同步下来的检查点只有在 `lastSeq ≥ 本地已应用 seq` 时才替换本地状态（4.8） |
| `interrupt` | | 只在 `paused` 时出现，且必须出现：运行正在等的那个中断 `{id, stepId, blockId, reason}`（4.8） |
| `steps` | | 运行步骤的精简记录（见 4.7）：每步只有 `id`、`label`、`state`、`durationMs`，以及可选的 `summary`、`blockId`（这一步向用户提问用的交互块）、`kind`（`delegate` = 交给子 Agent）、`parentStepId`（子 Agent 的步骤挂在哪个委派步骤下）。**与 `blocks` 分开存放**，不占块位置、不计入 `blockCount`、不进 `fallbackText`；没有步骤时省略。只出现在助手 / 系统消息上 |
| `metadata` | | 宿主自用的不透明数据（如追踪 ID），库不渲染 |
| `view` | | **保留**给 Phase 2 的 View 协议，0.1 中不得出现 |

**持久化版本优先**：流式过程中客户端在内存里拼出的消息只是临时状态；服务端在 `message.end` 时持久化最终消息，经宿主的同步机制下发。断线重连或离线之后，**以持久化版本为准**，临时状态被整体替换。暂停中的消息还没有结束，它的检查点（`rev = 0`、带 `lastSeq`）同样必须持久化，规则见 4.8。

**用户消息的 ID 由发送端生成，乐观副本按同一个 `id` 对账**（[D43](decisions.md)，取代早期草案里单独的 `clientMessageId` 字段）：

- 用户发出消息时，客户端生成 `id`（推荐 UUIDv7），先在本地显示这条乐观消息；离线时它和 `id` 一起进宿主的离线队列。
- 服务端校验格式，确认这个 `id` 在会话内唯一、属于当前发送者，然后**原样采用**，不另发新 ID。同一个 `id` 重复提交且内容相同：按幂等处理，返回第一次的结果（包括同一个助手消息 ID，见 4.6）；同一个 `id` 内容不同：拒绝。`id` 只是定位与去重用的，不代表任何权限。
- 宿主同步下来的持久化消息与本地副本 `id` 相同，客户端**原地替换**（列表里的行身份不变，不闪烁、不重复）。发送失败的消息留在本地并标“未发送”，重试**复用同一个** `id`。
- 客户端**不得**按文本、发送人或时间去猜哪条持久化消息对应哪条本地消息。
- 助手消息和系统消息的 `id` 只由服务端生成，客户端不得指定。

## 3. 内容块（Content Block）

定义见 [`content-block.schema.json`](../schemas/v0.1/content-block.schema.json)。

```json
{
  "id": "b2",
  "type": "metric_group",
  "schemaVersion": 1,
  "data": { "...": "按类型定义" },
  "fallbackText": "今日：最高 18°C，最低 7°C，降水概率 10%",
  "metadata": { "provenance": "tool", "asOf": "2026-10-26T09:00:00Z" }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | ✅ | 稳定块 ID |
| `type` | ✅ | 语义类型：内置类型（3.2）或宿主自定义类型（3.3） |
| `schemaVersion` | ✅ | 该类型 `data` 结构的版本（整数）。只新增可选字段不升版；含义变化或破坏性变化必须升版 |
| `data` | ✅ | 内容主体，结构由类型决定 |
| `fallbackText` | 非 markdown 块必填 | 本块的纯文本版本 |
| `metadata` | | `provenance`（事实来源：`model` 模型 / `tool` 工具结果 / `host` 宿主业务数据 / `adapter` 适配器）、`asOf`（数据时点）、`citations`（引用来源）、`host`（宿主不透明扩展） |

### 3.1 语义与表现分离

块只描述**事实与语义**，不描述表现：没有颜色、像素、字体、栅格列数、圆角。需要表达“好 / 坏 / 需注意”时用语义字段 `assessment.status`（`positive` / `negative` / `warning` / `critical` / `neutral` / `info`），由渲染器映射成设计系统的颜色和图标。

> 例：Agent 说“LDL-C 2.00 mmol/L，在指定风险条件下达标”，写成 `{"label":"LDL-C","value":2.0,"unit":"mmol/L","assessment":{"status":"positive","label":"达标"}}`；用不用绿色、卡片多宽，由渲染器和宿主主题决定。

### 3.2 v1 内置语义类型

| 类型 | 用途 | 默认组件（客户端注册表） | 不支持时的降级 |
|---|---|---|---|
| `markdown` | 普通段落、解释、推理、结论（**默认**） | Markdown 渲染器（安全子集） | 纯文本 |
| `metric` | 单个指标 | 指标卡 | `fallbackText` |
| `metric_group` | 一组相关指标 | 指标网格 | 逐项列表文本 |
| `dataset` | 数据集合（行 × 列） | 表格 | 文本表 / `fallbackText` |
| `time_series` | 随时间变化的数值 | 简单折线图 | 表格（由数据转换）→ `fallbackText` |
| `comparison` | 多个对象在多个维度上的比较 | 对比表 | 表格 → `fallbackText` |
| `status` | 状态与进度（含步骤） | 状态条 / 进度条 | `fallbackText` |
| `choice` | 请用户从选项中选（如澄清问题） | 选项按钮组 | 编号列表文本，提示用户直接回复 |
| `confirmation` | 请用户确认或取消某个操作 | 确认卡 | 文本 +“请在新版本中确认” |
| `form_intent` | 需要用户补充几项结构化信息 | 表单 | 字段清单文本，提示直接回复 |

**命名说明**：类型名描述**语义**而不是组件。例如数据集合叫 `dataset`（默认画成表格，将来也可以画成卡片列表），状态与进度合并为 `status`（有 `progress` 就画进度条）。

下面列出各类型 `data` 的要点；完整约束（长度、数量上限、枚举）见 Schema。

#### `markdown`

```json
{ "text": "北京今天**晴**，适合出门。" }
```
只允许安全子集（见 [rendering.md](rendering.md#3-markdown-安全子集)）。流式时通过 `block.delta` 只追加文本。

#### `metric`

```json
{
  "label": "最高气温", "value": 18, "unit": "°C",
  "format": { "style": "integer" },
  "delta": { "value": 3, "direction": "up", "period": "较昨天" },
  "assessment": { "status": "neutral" },
  "asOf": "2026-10-26"
}
```
`value` 可以是数字、字符串（如 `"A+"`）或 `null`（暂无数据）。`format` 是语义提示（小数 / 整数 / 百分比 / 货币 / 时长、币种、是否最小货币单位），真正的本地化格式由渲染器完成。

#### `metric_group`

```json
{ "title": "今日天气", "metrics": [ { "label": "最高", "value": 18, "unit": "°C" }, { "label": "降水概率", "value": 0.1, "format": { "style": "percent" } } ], "summary": "整体适合户外活动" }
```
1–12 个 `metric`。

#### `dataset`

```json
{
  "title": "未完成的待办",
  "columns": [
    { "key": "title", "label": "事项", "type": "string" },
    { "key": "due", "label": "截止", "type": "date" },
    { "key": "priority", "label": "优先级", "type": "integer" }
  ],
  "rows": [ { "title": "交水费", "due": "2026-10-28", "priority": 1 } ],
  "totalRows": 37,
  "sort": { "key": "due", "direction": "asc" }
}
```
1–12 列、最多 200 行。生产方截断时填 `totalRows`，渲染器显示“显示 N / 共 M 条”。单元格只能是标量（数字 / 字符串 / 布尔 / null），**不允许嵌套**。

#### `time_series`

```json
{
  "title": "未来 5 天气温", "xType": "date", "yUnit": "°C",
  "series": [
    { "key": "high", "label": "最高", "points": [ { "x": "2026-10-26", "y": 18 }, { "x": "2026-10-27", "y": 16 } ] },
    { "key": "low", "label": "最低", "points": [ { "x": "2026-10-26", "y": 7 }, { "x": "2026-10-27", "y": 6 } ] }
  ]
}
```
最多 6 条序列，每条最多 500 点；`y` 为 `null` 表示缺测。图表类型（折线 / 柱状）由渲染器决定，生产方不指定。

#### `comparison`

```json
{
  "title": "两个城市本周对比",
  "subjects": [ { "id": "bj", "label": "北京" }, { "id": "sh", "label": "上海" } ],
  "attributes": [ { "key": "avg_high", "label": "平均最高", "type": "number", "unit": "°C", "preference": "none" }, { "key": "rain_days", "label": "雨天", "type": "integer", "preference": "lower_is_better" } ],
  "values": [ { "subject": "bj", "attribute": "rain_days", "value": 0, "assessment": { "status": "positive" } }, { "subject": "sh", "attribute": "rain_days", "value": 3 } ],
  "conclusion": "北京本周更干燥。"
}
```
2–6 个比较对象、1–12 个维度；`values` 是扁平的“对象 × 维度”单元格列表，便于校验。

#### `status`

```json
{ "label": "正在同步日程", "state": "running", "progress": { "current": 3, "total": 5, "unit": "项" }, "steps": [ { "label": "读取", "state": "succeeded" }, { "label": "合并", "state": "running" } ] }
```
`state`：`pending` / `running` / `waiting` / `succeeded` / `failed` / `cancelled`。

`status` 块是**内容**：它描述的是回答里要交代的事情（例如宿主某个后台任务的进度），会留在消息正文里。AI 回答这条消息时自己做了哪些步骤，用 4.7 的运行步骤，不用 `status` 块。

#### `choice`（交互块）

```json
{
  "prompt": "要查哪个城市？",
  "options": [ { "id": "bj", "label": "北京" }, { "id": "sh", "label": "上海" } ],
  "selection": "single",
  "allowFreeText": true,
  "action": { "type": "choice.select", "target": "clarification.answer" },
  "state": { "status": "open" }
}
```
2–10 个选项。`state` 由服务端维护：服务端记录答案后经 `block.patch` 变成 `{"status":"resolved","selected":["bj"],"resolvedBy":"member_7","resolvedAt":"2026-10-26T09:31:11Z"}`，所有设备都会看到同一个“已回答”结果（交互块状态的完整规则见 3.4）。

文字回答分两种“问”（4.8）：

- 块是**中断**的提问（消息 `paused`，`interrupt.blockId` 指向它）：不看 `allowFreeText`。每张中断卡（`choice`、`confirmation`、`form_intent` 都一样）默认固定带一个“其他内容”入口，由中断的 `otherInput` 控制（默认 `true`，宿主可以对单个中断关掉）。用户点它、在输入框里写的文字是这个中断的结果，**不是**一条聊天消息，经动作通道提交 `{freeText}`，显示在卡片上（[D60](decisions.md)）。
- 块在一条**已经结束**的消息里（最终回答里附带的问题）：`allowFreeText: true` 表示用户也可以直接发一条消息来回答。文字回答作为一条**普通用户消息**发出，不走动作通道；宿主把它关联到这个仍为 `open` 的块，并在服务端把块写成 `resolved`（`freeText` 记录回答文本）（[D22](decisions.md)）。

两种情况下块的 `state.freeText` 都记录回答文本。

#### `confirmation`（交互块）

```json
{
  "title": "删除待办“交水费”？",
  "body": "删除后无法恢复。",
  "severity": "destructive",
  "details": [ { "label": "截止", "value": "2026-10-28" } ],
  "confirmLabel": "删除", "cancelLabel": "保留",
  "action": { "type": "confirmation.respond", "target": "todo.delete", "requiresConfirmation": true, "expiresAt": "2026-10-26T10:30:00Z" },
  "state": { "status": "open" }
}
```
**破坏性或不可逆的操作只能通过 `severity: "destructive"` 的确认块发起**（Schema 与服务端注册表双重约束，见第 5 节）。

#### `form_intent`（交互块）

```json
{
  "title": "新建待办", "purpose": "还差截止日期和优先级",
  "fields": [
    { "key": "title", "label": "事项", "type": "text", "required": true, "maxLength": 100, "defaultValue": "交水费" },
    { "key": "due", "label": "截止日期", "type": "date", "required": true },
    { "key": "priority", "label": "优先级", "type": "single_select", "options": [ { "id": "p1", "label": "高" }, { "id": "p2", "label": "普通" } ] }
  ],
  "submitLabel": "保存",
  "action": { "type": "form.submit", "target": "todo.create" },
  "state": { "status": "open" }
}
```
名字里的 “intent” 表示它描述的是“需要哪些信息、为什么需要”，表单怎么排由渲染器决定。最多 12 个字段，字段类型：`text`、`multiline_text`、`number`、`integer`、`date`、`datetime`、`boolean`、`single_select`、`multi_select`。

### 3.3 宿主自定义类型

宿主可以定义自己的业务类型，**必须带命名空间**：`x-<宿主名>.<类型名>`，例如 `x-jiabu.record_card`、`x-todo.task_card`。规则：

1. 宿主必须在服务端为每个自定义类型注册 JSON Schema，并在发出前校验（库提供注册接口）；通用 Schema 只约束大小。
2. 宿主必须在客户端注册对应组件；没注册的客户端按未知类型降级。
3. 自定义类型同样只放语义数据。推荐**只放引用**（如 `{"recordId": "…"}`），由宿主组件从本地数据源读取最新内容——这样编辑 / 撤销后卡片自动更新，也不会把业务数据复制进聊天记录。引用某条记录的卡片推荐写成“**记录 ID + 标题快照**”（如 `{"recordId": "…", "titleSnapshot": "交水费"}`，[D46](decisions.md)）：ID 是唯一的事实来源；标题快照**只在本地读不到这条记录时**显示（尚未同步、已删除、当前查看者无权读取），显示为“标题 + 不可用”之类的说明，并且要包含在块的 `fallbackText` 里。读得到记录时一律显示记录的最新内容，不显示快照。
4. 自定义块必须带 `fallbackText`。

### 3.4 交互块的状态（`choice` / `confirmation` / `form_intent`）

交互块的 `state` **只由服务端写**，并且只在服务端已经记录了结果之后才变化：

| `state.status` | 含义 | 客户端显示 |
|---|---|---|
| `open` | 等待回答 | 可操作（前提见 [rendering.md 4.2](rendering.md#42-交互块的显示状态)） |
| `resolved` | 已记录一个答案：`selected` / `outcome` / `values` / `freeText`，以及 `resolvedBy`（宿主的不透明成员 ID）、`resolvedAt`（必填） | 服务端记录的结果和“谁、何时”；控件禁用 |
| `expired` | 到了 `action.expiresAt` 仍没有回答 | “已过期”，控件禁用 |
| `cancelled` | 服务端作废了这次询问，**必须**带 `reason`（例如引用的记录已变化或删除、权限变化、服务端策略拒绝）。注意：用户自己在确认卡上点“取消”不是这个状态，而是 `resolved` + `outcome: "cancel"` | “已取消”+ 原因说明，控件禁用 |
| `superseded` | 被一个更新的交互块取代（例如助手针对同一操作重新发了一张确认卡），`supersededBy` 指向新块 | “已被新的请求取代”，控件禁用 |

**谁、为什么**（[D45](decisions.md)）：

- `resolvedBy`（宿主的不透明成员 ID）记录**用户**给出的答案是谁给的，包括用户在确认卡上点“取消”（`resolved` + `outcome: "cancel"`）。一对一会话里它就是那位用户，宿主也可以省略。
- `cancelled` / `expired` / `superseded` 是**服务端**造成的结束，不得带 `resolvedBy`。`cancelled` 必须带 `reason{code, text?}`，`expired` / `superseded` 可以带：`code` 取 `withdrawn`（服务端撤回）、`policy`（服务端策略拒绝）、`record_changed`、`record_deleted`、`permission_changed`、`stopped`（消息暂停在这个块的中断上时被停止，包括用户没回答、直接发了新消息，见 4.8）、`other`；`text` 是可以直接给用户看的简短说明。这样界面能区分“你取消了”和“系统已作废”。

规则（所有场景）：

1. **不乐观显示结果。** 用户点下去之后，客户端只显示“提交中”（离线排队时显示“已排队，联网后提交”），**不**把自己点的选项先画成“已选择”。只有收到服务端的 `ActionResult.patches`、流里的 `block.patch`，或宿主同步下来的更高 `rev` 时，才显示结果。“提交中 / 已排队”是客户端本地的显示状态，**不属于协议**，也不会出现在 `state.status` 里。
   为什么一对一也要这样：服务端可能拒绝这次操作——当前用户没有权限、块引用的记录已经被改动或删除、表单值没通过校验、块已过期；同一用户也可能在另一台设备上已经回答过。先画“已选择”再回退，会让用户以为已经生效。
2. 一旦离开 `open`，块不再接受任何动作；拒绝时结果带块的当前状态（见第 5 节）。块所在的消息还没结束时（中断的块），当前状态不靠 `rev` 补丁传递，而是在这条消息的流（或快照）里，结果用 `resume` 指向这条消息（4.8）。

**群聊场景：并发回答（先答者胜）。** 群聊里同一个块会同时出现在多位成员面前。服务端以**第一个被记录的答案**为准；后到的请求被拒绝（`already_resolved`，或块已被取代时 `superseded`、已过期时 `expired`），结果里**必须**带上块的当前状态（`patches`），客户端据此显示服务端的真实结果（例如“已由另一位成员选择‘北京’”），而不是自己刚才点的那个。一对一会话里同一机制照样生效：同一用户在两台设备上几乎同时作答时，后到的那台设备显示先记录的答案。

## 4. 流式事件（Stream Events）

定义见 [`stream-event.schema.json`](../schemas/v0.1/stream-event.schema.json)；端到端示例、SSE 封装、断线续传见 [streaming.md](streaming.md)。

### 4.1 事件公共字段

| 字段 | 说明 |
|---|---|
| `protocolVersion` | 如 `"0.1"` |
| `type` | 事件类型，见下表 |
| `messageId` | 所属消息 |
| `seq` | **每条消息从 1 开始、每个事件严格 +1** 的序号。临时事件（`message.activity`，见 4.5）**没有** `seq`；运行步骤事件（4.7）、暂停 / 继续事件（4.8）和块事件一样**有** `seq`。消息暂停后继续，`seq` 接着往下数，不重新开始 |
| `ts` | 可选，服务端时间 |

### 4.2 事件类型

| 事件 | 关键字段 | 作用 |
|---|---|---|
| `message.start` | `message{id, role, conversationId?, createdAt, metadata?}` | 开始一条消息 |
| `block.start` | `blockId`、`index`、`blockType`、`schemaVersion`、`placeholder?` | 在固定位置创建块容器（占位）。**类型从此不再改变** |
| `block.delta` | `blockId`、`delta.text` | v1 只用于 markdown：追加文本 |
| `block.data` | `blockId`、`data`、`fallbackText`、`metadata?` | 组件块的**完整**数据（服务端已校验），v1 每块只发一次 |
| `block.patch` | `blockId`、`patch`、`rev?` | 按块 ID 局部更新：对 `{data, fallbackText, metadata}` 做 JSON Merge Patch |
| `block.end` | `blockId`、`status`（`complete`/`error`）、`fallbackText?`、`error?` | 块结束；组件块失败时给出兜底文本 |
| `message.end` | `status`、`fallbackText`、`blockCount`、`rev`、`error?` | 消息结束，最终版本已持久化 |
| `message.paused` | `interrupt{id, stepId, blockId, reason}`、`fallbackText`、`blockCount` | 运行在等用户回答（中断），消息暂停；服务端持久化暂停检查点后关闭流（4.8）。对应 AG-UI 的 `RUN_FINISHED{outcome: interrupt}` |
| `message.resumed` | `interruptId` | 中断已被回答，同一条消息继续（4.8）。对应 AG-UI 带 `resume` 的新一次运行的 `RUN_STARTED` |
| `message.snapshot` | `message`（完整消息） | 续传时无法按序重放、或服务端不保留事件日志时，直接发完整状态 |
| `error` | `error{code, message, retryable}`、`blockId?` | 流级错误 |
| `message.activity` | `activity{phase, label?}`，**无 `seq`** | 临时进度提示，只用于显示（见 4.5） |
| `step.started` | `stepId`、`label`、`kind?`、`parentStepId?` | 一个运行步骤开始（`running`），见 4.7；`kind: delegate` 表示交给子 Agent，子 Agent 的步骤用 `parentStepId` 挂在它下面。对应 AG-UI 的 `STEP_STARTED`（委派步骤另对应 `SUBAGENT_STARTED`） |
| `step.finished` | `stepId`、`state`、`durationMs`、`summary?` | 这个步骤结束：`succeeded` / `failed` / `cancelled`。等用户不是结束（见 4.8）。对应 AG-UI 的 `STEP_FINISHED`（委派步骤另对应 `SUBAGENT_FINISHED` / `SUBAGENT_ERROR`） |

**JSON Merge Patch**（RFC 7396，“合并补丁”）：补丁对象里出现的字段覆盖原值，值为 `null` 表示删除该字段，数组整体替换。它比逐条操作的 JSON Patch（RFC 6902）简单，足够表达 v1 的状态更新。

### 4.3 v1 的流式范围

- **Markdown 文本逐步出现**：`block.start(markdown)` → 若干 `block.delta` → `block.end`。
- **组件块整块到达**：`block.start` 时创建占位，`block.data` 时一次填满，然后 `block.end`。v1 **不做**组件字段级的增量流式（例如表格逐行出现），留给 Phase 3。
- 同一时刻最多一个 markdown 块处于打开状态；组件块可以先占位、稍后填充，期间后续 markdown 可以继续输出（例如工具查询还在进行时文字先说）。
- 块按 `index` 顺序开始；`index` 就是它在最终 `blocks` 中的位置。

### 4.4 顺序、幂等与修订号

- **`seq`（流内顺序）**：消费方记住每条消息最后应用的 `seq`；收到 `seq ≤ 已应用` 的事件直接丢弃（幂等）；收到跳号（`seq > 已应用 + 1`）就断开并带上已应用的 `seq` 重连续传，不尝试“先放着等补齐”。
- **`rev`（持久化版本）**：消息完成后发生的变化（例如选项块被回答）带 `rev`。规则：`rev == 本地 rev + 1` 才应用；`≤ 本地 rev` 忽略；跳号则向宿主存储 / 同步重新取整条消息。消息还没结束时（生成中、暂停中）的块变化（例如中断的块被回答）是流里普通的 `block.patch`，只按 `seq`，不带 `rev`。
- 未知事件类型：忽略内容但照常推进 `seq`。
- 没有 `seq` 的事件只能是临时事件（4.5），不参与以上规则。

### 4.5 临时进度事件（`message.activity`）

第一个块出现之前，或一次工具查询比较慢的时候，界面上常有几秒空白。`message.activity` 用来显示一句临时提示（[D40](decisions.md)）：

```json
{"protocolVersion":"0.1","type":"message.activity","messageId":"msg_01","activity":{"phase":"working","label":"正在查天气…"}}
```

- `phase`：`waiting`（已受理，还没开始产出）/ `working`（正在做某件事，`label` 说明是什么）/ `still_working`（较长时间没有新内容，例如 10 秒以上，“仍在处理”）/ `degraded`（上游变慢或切换了提供方，回答可能更慢）。`label` 可选，最长 120 字符，由宿主写（不是模型输出），不得包含业务数据。
- **只用于显示**：不带 `seq`，不写事件日志，续传时不重放，不参与折叠（`fold`），不进入最终消息和快照。因此 `fold(events) == 持久化消息` 仍然成立。
- SSE 帧里没有 `id:` 行，`Last-Event-ID` 不受影响。
- 客户端只保留最新的一条提示；该消息的下一个带 `seq` 的事件、新的 `message.activity` 或 `message.end` 到达时替换或清除。断线重连后提示消失，直到服务端再发。
- 服务端只向声明了 `stream.activity` 能力（7.2）的客户端发送。没声明的客户端看不到提示，内容不受影响。
- 它不是运行步骤。有具体步骤（查什么、对比什么、等用户确认）时用 4.7 的步骤事件；`message.activity` 只留给**没有具体步骤**的笼统等待，例如第一个步骤之前的“已受理”、步骤之间模型在组织回答时的“仍在处理”、上游变慢时的“可能慢一些”。两者同时存在时，界面以步骤为准（见 4.7）。

### 4.6 生成控制：开始、停止、找回

这三件事不是块上的动作，不走 Action 协议；端点路径由宿主决定，库提供处理函数与 Schema（[`generation.schema.json`](../schemas/v0.1/generation.schema.json)）。流式细节见 [streaming.md 第 4 节](streaming.md#4-断线续传)。

1. **开始：同步返回助手消息 ID**（[D41](decisions.md)）。宿主的“提交用户消息”接口**必须**在生成开始前返回 `{userMessageId, messageId, streamable}`（`messageId` 是这次回复的助手消息 ID）。同一个用户消息 ID 重复提交（例如离线重发、超时重试）返回同一个 `messageId`，`replayed: true`，不会开始第二次生成。会话里有一个开着的中断时，宿主可以拒绝开始（4.8 第 16 条）：

   ```json
   {"userMessageId":"01J9ZA0B1C","error":{"code":"interrupt_pending","message":"先回答上面的问题。"},"pending":{"messageId":"msg_03","interruptId":"int_01"}}
   ```
2. **停止：显式请求，与断线严格区分**（[D39](decisions.md)）。`POST {宿主前缀}/messages/{messageId}/stop`，幂等。服务端取消生成，持久化已产出的部分，发 `message.end{status: "interrupted", error.code: "cancelled"}`；响应 `{messageId, status: "stopping" | "already_ended"}`。暂停中的消息同样可以停止（4.8）。**关闭连接、切后台、离开页面、App 被杀都只是断线**，不是停止，生成照常继续，之后可以续传。谁能停止由宿主授权（例如只允许发起这一轮的用户）。
3. **找回：按会话查询正在生成的消息**（[D41](decisions.md)）。`GET {宿主前缀}/conversations/{conversationId}/active-messages` → `{conversationId, messages: [{messageId, lastSeq, replyTo?, status?}]}`，列出还没结束的消息（`status` 为 `streaming`（默认）或 `paused`），没有就返回空列表。用于“提交了用户消息、还没收到助手消息 ID 时 App 就被杀”的空窗：重启后先查一次，再按 `messageId` 续传。群聊里同一会话可能同时有几条在生成，所以是列表。

### 4.7 运行步骤（`step.started` / `step.finished`）

助手回答之前常常要先做几件事：查数据、对比、等用户确认。步骤事件让界面在这条消息顶部显示一条“过程”，告诉用户 AI 正在做什么、做完了哪些（[D48](decisions.md)–[D52](decisions.md)、[D58](decisions.md)；界面见 [rendering.md 4.3](rendering.md#43-运行过程条processstrip)）。事件名和字段对齐 AG-UI 1.0 的 `STEP_STARTED` / `STEP_FINISHED`，差异逐条列在 [10.1](#101-运行过程事件对齐-ag-ui)。

```json
{"protocolVersion":"0.1","type":"step.started","messageId":"msg_02","seq":2,"stepId":"s1","label":"查北京本周天气"}
{"protocolVersion":"0.1","type":"step.started","messageId":"msg_02","seq":3,"stepId":"s2","label":"查上海本周天气"}
{"protocolVersion":"0.1","type":"step.finished","messageId":"msg_02","seq":4,"stepId":"s1","state":"succeeded","durationMs":800}
{"protocolVersion":"0.1","type":"step.finished","messageId":"msg_02","seq":5,"stepId":"s2","state":"failed","durationMs":1200,"summary":"天气服务暂时不可用"}
{"protocolVersion":"0.1","type":"step.started","messageId":"msg_04","seq":2,"stepId":"s1","label":"交给天气助手对比两城天气","kind":"delegate"}
{"protocolVersion":"0.1","type":"step.started","messageId":"msg_04","seq":3,"stepId":"s2","label":"查北京本周天气","parentStepId":"s1"}
```

前四行是两个并行的查询，一个成功、一个失败；后两行来自另一条消息：主 Agent 把“对比两城天气”交给一个子 Agent，子 Agent 自己的步骤挂在委派步骤下面。完整的事件序列与折叠结果见 [streaming.md 2.5](streaming.md#25-运行步骤) 与 [2.7](streaming.md#27-子-agent-的步骤嵌套)；等用户确认的步骤见 4.8。

**Agent 的形态**：宿主的 Agent 通常是一个 ReAct 循环（思考 → 调用工具 → 看结果 → 再思考……），可以有一个主 Agent 和若干子 Agent（主从结构：主 Agent 把一部分工作委派给子 Agent，子 Agent 自己也是一个循环）。ChatWeave 不规定宿主怎么实现 Agent，只规定它们在过程条上怎么表达：每次工具调用（或宿主认为值得告诉用户的一件事）是一个步骤；一次委派是一个 `kind: "delegate"` 的步骤，子 Agent 的步骤是它的子步骤。

**字段**

- `stepId`：在这条消息内唯一且稳定，用来把开始和结束配成一对，也用来被子步骤引用。
- `label`：**宿主写的**、给人看的一句话（最长 60 字符），例如“查北京本周天气”“交给天气助手对比两城天气”。宿主为每种工具 / 处理 / 子 Agent 预先写好标签，可以填入经过整理的对象名（如城市名）；它**不是**工具名、子 Agent 的内部名字、调用参数，也不是模型输出。
- `kind`（只在 `step.started` 上，可选）：`delegate` 表示这一步是把工作交给一个子 Agent。没有这个字段就是普通步骤。
- `parentStepId`（只在 `step.started` 上，可选）：子 Agent 的步骤指向它所在的委派步骤。主 Agent 自己的步骤不带。
- `state`（只在 `step.finished` 上）：`succeeded`（完成）/ `failed`（失败）/ `cancelled`（用户停止生成、或中断过期时还没完成）。`step.started` 本身就表示 `running`。等用户回答**不是**结束状态：它由 `message.paused` / `message.resumed` 表达（4.8），那一步在暂停期间是 `awaiting_user`，回答后回到 `running`，最后照常 `step.finished`。
- `durationMs`：这一步的工作时长（毫秒），**不含**暂停等用户的时间。它是时长，不是时间点，不受第 1 节“时间只用 RFC 3339”的约束。
- `summary`（可选，最长 120 字符）：宿主按工具提供的一行结果说明，例如“找到 3 件待办”“天气服务暂时不可用”，由宿主模板生成。**原始查询结果不下发**。

**规则**

1. **每个步骤只结束一次**，结束后不再变化。生产方在 `message.end` 之前**必须**为每个已开始的步骤发出 `step.finished`：用户按停止时仍在运行或等待的步骤记为 `cancelled`。已结束的消息里不会有 `running` 或 `awaiting_user` 的步骤；服务端崩溃后按检查点或日志恢复时，仍在运行的步骤记为 `failed`（暂停中的消息不受崩溃影响，见 4.8）。
2. **失败只影响自己这一行**：一个步骤 `failed` 不影响其他步骤，也不会让消息失败；消息是否成功只看 `message.end.status`。宿主通常会让 Agent 带着“这一步没查到”继续回答。子 Agent 的某一步失败也只标那一行；委派步骤本身成功与否由宿主按子 Agent 的结果决定。
3. **可以并行**：多个步骤可以同时处于 `running`（包括几个子 Agent 同时在跑）。同一层里的显示顺序 = `step.started` 的顺序。
4. **可以嵌套（子 Agent）**：`parentStepId` **必须**指向这条消息里**更早开始**、`kind` 为 `delegate`、而且还在运行的步骤（所以不会出现环）；嵌套最多 3 层（主 Agent 的步骤是第 1 层）。委派步骤要等它的所有子步骤都结束之后才能结束（停止时先结束子步骤、再结束委派步骤）。普通步骤不能有子步骤。违反这些按协议错误处理。
5. **带 `seq`，和块事件一样可靠**：写事件日志、续传时重放、进快照（`message.snapshot` 里的 `message.steps`，生成中可能含 `running`，暂停中含 `awaiting_user`）。`fold(events) == 持久化消息` 包括步骤：`step.started` 追加 `{id, label, kind?, parentStepId?, state: "running"}`，`message.paused` 把中断的那一步改成 `awaiting_user` 并写入 `blockId`，`message.resumed` 把它改回 `running`，`step.finished` 把这一项改成最终状态并写入 `durationMs`、`summary`。对未开始的步骤发 `step.finished`、重复的 `stepId` 开始，都按协议错误处理（与块相同）。
6. **与内容分开**：步骤折叠进消息的 `steps` 字段，不是内容块：不占 `index`，不计入 `blockCount`，不进 `fallbackText`。只会显示文本的客户端、通知、搜索都看不到过程。
7. **持久化的只是精简记录**：`message.end` 时随消息保存的每一步只有 `id`、`label`、最终 `state`、`durationMs`，以及可选的 `summary`、`blockId`（这一步曾经通过哪个交互块问过用户）、`kind`、`parentStepId`。**不含**工具名、子 Agent 的内部名字、参数、原始数据或模型文字。
8. **不传模型的思考过程**：模型的推理 / 思考文字（AG-UI 的 `REASONING_*`）**从不**下发，不进事件、事件日志或消息，也不用来生成 `label` / `summary`。子 Agent 的思考文字同样不下发。
9. **等用户确认 / 回答**：运行中某一步需要用户确认或回答时，运行**暂停**，同一条消息在回答后继续，这一步从“等你确认”回到运行、最后照常结束。完整规则见 4.8。最终回答里附带的问题不是这种情况（4.8 开头）。
10. **对所有订阅者都发出**：步骤事件带 `seq`，按接收者删掉会造成跳号。没声明 `stream.steps` 能力（7.2）的客户端把它们当作未知事件类型：忽略内容、照常推进 `seq`；持久化消息里的 `steps` 字段同样忽略（宽进严出）。内容照常显示。服务端可以为这类客户端额外发 `message.activity{phase: "working", label: 当前步骤的 label}`，让它们仍能看到一句提示；对声明了 `stream.steps` 的客户端不必再发重复的提示。不认识 `parentStepId` 的旧客户端按宽进严出忽略它，把所有步骤平铺显示。
11. **与 `message.activity` 的关系**：有步骤正在运行时，客户端以步骤为准，不再单独显示 activity 提示；没有正在运行的步骤时（例如第一个步骤之前、步骤之间模型在组织回答时）照常显示 activity。
12. **按接收者替换，不删除（仅群聊）**：步骤细节对谁可见由宿主按接收者决定（[security.md 第 6 节](security.md#6-隐私)）。要对某位接收者隐藏细节时，宿主**替换**而不是删除：把 `label` 换成笼统的说法（如“处理一项请求”），去掉 `summary`，事件条数、`seq`、`kind` 和 `parentStepId` 保持不变；同步下发的 `steps` 也同样处理。一对一会话只有一位用户，不存在这个问题。

### 4.8 中断：暂停与继续（同一条消息）

助手问用户问题有两种情况，处理方式不同（[D53](decisions.md)）：

| | (a) **中断**：运行中途要用户确认或回答 | (b) **最终回答里带着问题** |
|---|---|---|
| 例子 | 某个工具调用被系统拦下、要用户确认（例如修改或删除一条记录之前）；运行中途 `ask_user` 澄清（“要查哪个城市？”） | 回答已经写完，最后问一句“要我给‘交水费’设个提醒吗？” |
| 运行 | **没有结束**：同一条助手消息**暂停**，回答后在同一条消息、同一条过程条里**继续** | 已经结束（`message.end`） |
| 用户的回答 | 是这一步的**结果**，不是一条新的聊天消息（显示在卡片 / 这一步上） | 一条**新的用户消息**，随后是一条**新的助手消息** |
| 协议 | `message.paused` → 回答 → `message.resumed`，`seq` 接着数 | 照旧：普通消息，或块上的动作 + `followUp` 新消息 |

本节只讲 (a)。(b) 不需要任何新机制。

**生命周期**

```
streaming ──message.paused──▶ paused ──(回答) block.patch + message.resumed──▶ streaming ──…──▶ message.end（complete）
                                 │
                                 ├─(停止，或宿主按第 16 条先停止) block.patch(cancelled, stopped) + step.finished(cancelled)… + message.end(interrupted, cancelled)
                                 └─(过期) block.patch(expired) + step.finished(cancelled)… + message.end(interrupted, interrupt_expired)
```

同一条消息可以暂停多次（例如先问城市、后确认删除），每次只等一个中断（[D57](decisions.md)）。

**暂停（`message.paused`）**

```json
{"protocolVersion":"0.1","type":"message.paused","messageId":"msg_03","seq":6,"interrupt":{"id":"int_01","stepId":"s1","blockId":"b1","reason":"confirmation"},"fallbackText":"删除待办“交水费”？删除后无法恢复。","blockCount":1}
{"protocolVersion":"0.1","type":"message.resumed","messageId":"msg_03","seq":8,"interruptId":"int_01"}
```

1. **前提**：中断的交互块（`choice` / `confirmation` / `form_intent`，状态 `open`）已经完整发出（`block.data` + `block.end`）；所有已开始的块都已结束；除了中断的那一步和它上面的委派步骤（子 Agent 里发起的中断，见第 9 条），没有其他步骤在运行——并行的其他工具调用先跑完。
2. `interrupt`：`id`（不透明，消息内唯一）、`stepId`（发起中断的那一步）、`blockId`（正文里的交互块，问题本身在块里）、`reason`（`confirmation` = 确认或拒绝一个操作；`input_required` = 需要用户回答。取值对齐 AG-UI 的核心 reason）、`otherInput`（可选，布尔，默认 `true`：这张卡除了自己的控件，是否固定提供“其他内容”入口，让用户改用一段文字回答，见第 10 条；宿主可以对单个中断关掉，例如只允许“确认 / 取消”的纯确认，这时用户只能在卡上作答或停止）。过期时间取块的 `action.expiresAt`，不在这里重复。
3. **折叠**：消息 `status` 变成 `paused`，带上 `interrupt`；那一步变成 `awaiting_user` 并写入 `blockId`；`fallbackText` 是到目前为止的纯文本（含问题），给只会显示文本的客户端和通知用。
4. **持久化**：服务端在发出 `message.paused` 的同时（同一事务或等价的条件写入）把暂停检查点写进消息存储：折叠后的消息（`status: paused`、`rev: 0`、`lastSeq` = 这个事件的 `seq`）。暂停可能持续几小时甚至几天，检查点是它的权威状态，**不依赖**事件日志或进程内缓冲；服务端重启不影响暂停中的消息。
5. **关闭流**：发出 `message.paused` 后服务端关闭这条 SSE 连接（像 `message.end` 一样）。客户端进入“已暂停”状态，**不自动重连**——这时没有东西可等；打开会话、回到前台等续传触发时机（[streaming.md 4.3](streaming.md#43-客户端续传状态机)）对暂停中的消息不生效。
6. **暂停中订阅**：有客户端在暂停中订阅这条消息（例如另一台设备刚打开会话）时，服务端照常从日志重放 `seq > N` 的事件（日志没有了就发快照），以 `message.paused`（或暂停中的快照）结束，然后关闭。
7. **事件日志的保留期从 `message.paused` 起算**（默认 10 分钟，同 [D21](decisions.md)）：过期后可以清掉日志，之后的订阅拿到暂停检查点的快照，再接着收继续之后的事件。**暂停中的消息本身不会因为日志过期而失去继续的能力**——继续只依赖检查点和宿主的运行时状态。
8. **找回与同步**：暂停中的消息出现在活动消息列表里（`status: "paused"`，4.6），另一台设备据此显示问题、回答后订阅。宿主也可以把暂停检查点同步下发；客户端收到 `rev = 0` 的检查点时，只有 `lastSeq ≥ 本地已应用 seq` 才替换本地状态（检查点不会让本地状态倒退）。
9. **子 Agent 里的中断**：中断可以由子 Agent 的某一步发起（它的 `stepId` 是子步骤）。**整条消息暂停**，不只是子 Agent：那一步是 `awaiting_user`，它上面的委派步骤保持 `running`（界面上显示为“等你确认”，见 [rendering.md 4.3](rendering.md#43-运行过程条processstrip)）。

**回答与继续（`message.resumed`）**

10. **回答就是中断的结果**：用户在中断的块上操作（选项、确认 / 取消、表单），客户端照常发动作请求（第 5 节，幂等键规则不变）。**文字回答**也走动作通道：中断开着且 `otherInput` 不为 `false` 时，三种交互块都接受 `{freeText}`（`choice.select`、`confirmation.respond`、`form.submit`，与块自身的答案字段二选一）。文字原样作为中断的结果交给宿主的 Agent 运行时（例如在确认卡上写“改成 72 块再删”），由 Agent 理解；库和宿主的处理器都不把它解析成某个选项（[D60](decisions.md)）。输入框怎么配合见 [rendering.md 4.5](rendering.md#45-输入框联动composer-契约)。回答**不会**变成一条用户消息；它记在块的 `state` 里（`resolved`、`selected` / `outcome` / `values` / `freeText`），显示在卡片上和这一步上。用户在确认卡上点“取消”也是一个回答（`outcome: cancel`），运行照样继续，由 Agent 决定接下来怎么说。
11. **服务端**：dispatcher 按第 5.2 节校验；第 7 步对中断的块是：在同一个事务（或条件写入）里检查“消息仍是 `paused`、中断仍未回答、块仍是 `open`”→ 记录答案 → 把答案作为这次中断的结果交给宿主的 Agent 运行时（宿主把它当作那次工具调用的结果，例如 `ask_user` 的返回值或“已确认，可以执行”）。返回 `ActionResult{status: "accepted", resume: {messageId}}`，**不带** `patches`、不加 `rev`（消息还没结束）。
12. **流里的顺序**：继续时服务端先发记录答案的 `block.patch`（块 → `resolved`，不带 `rev`），紧接着发 `message.resumed{interruptId}`；之后运行照常产出事件（那一步回到 `running`，最后 `step.finished`；新的块；`message.end`）。`message.resumed` **必须**紧跟在把中断的块写成 `resolved` 的 `block.patch` 之后。
13. **客户端**：收到 `resume` 后按已应用的 `seq` 重新订阅这条消息（`Last-Event-ID = 已应用 seq`）；在收到 `block.patch` 之前，块照常只显示“提交中”（[D18](decisions.md)）。其他设备通过活动消息列表或下一次打开会话时订阅，拿到同样的事件。
14. **幂等与并发**：同一个动作 ID 重复提交返回第一次的结果（含 `resume`），不会让运行继续两次。另一台设备已经回答过（或已停止、已过期）时，后到的请求被拒（`already_resolved` / `expired`）；如果消息还没结束，结果不带 `patches` 而带 `resume`，客户端订阅后从流（或快照）里看到真实结果；消息已经结束时照常带 `rev` 补丁。

**暂停中停止、新消息、过期**（[D56](decisions.md)、[D61](decisions.md)、[D62](decisions.md)）

15. **停止**：暂停中的消息可以停止（`POST …/stop`，幂等）。服务端在同一个条件写入里关闭中断，然后依次发：中断块的 `block.patch`（→ `cancelled`，`reason.code: "stopped"`）、等待中的那一步及其上面的委派步骤各一个 `step.finished{state: cancelled}`（先子后父）、`message.end{status: interrupted, error.code: cancelled}`，并持久化最终消息（`rev = 1`）。这些事件写进日志；没有人在订阅时，客户端下次打开时从持久化版本拿到结果。
16. **暂停时输入框锁定；中断开着时到达的新消息**：中断还开着、当前用户可以回答时，客户端的输入框**锁定**，发不出普通消息（[rendering.md 4.5](rendering.md#45-输入框联动composer-契约)，[D61](decisions.md)）：要用文字回答就点卡上的“其他内容”，这时输入框发出的是这个中断的 `freeText`（第 10 条）；不想回答就停止（第 15 条）。所以正常界面上没有“不回答、直接发新消息”这条路。万一服务端在中断开着时仍收到这位用户在这段会话里的新消息（旧版本客户端、还不知道已经暂停的另一台设备、离线排队后补发的消息），宿主二选一，**绝不**把它默默当成回答（[D62](decisions.md)）：
    - **拒绝**（推荐用于在线提交）：开始接口返回 `startRejected{error.code: "interrupt_pending", pending: {messageId, interruptId}}`（[`generation.schema.json`](../schemas/v0.1/generation.schema.json)），这条消息不保存、不开始生成；客户端据此显示那张卡、输入框进入锁定，草稿留在输入框里。
    - **先停止再开始**（用于不能拒绝的提交，例如离线排队同步上来的消息）：先对暂停中的消息执行第 15 条的停止（块 `cancelled` + `stopped`），再照常开始新的一轮。
    两种做法都与 AG-UI“有未回答的中断时，新的输入必须先处理它们”一致。群聊里只针对能回答这个中断的成员（其他成员照常聊天）；宿主也可以按自己的规则决定。

17. **过期**：块的 `action.expiresAt` 到了仍没回答，服务端关闭中断：块 → `expired`，步骤 → `cancelled`（同第 15 条的顺序），`message.end{status: interrupted, error.code: interrupt_expired}`。没有 `expiresAt` 的中断不会自己过期（直到停止，或按第 16 条先停止）。过期时间由宿主按场景设定。
18. **先到者胜**：回答、停止、过期、新消息都要先“检查中断仍开着 → 关闭它”，在同一个事务或条件写入里完成，只有一个会成功。停止请求到达时如果回答已经被接受、消息又在生成了，就按普通的停止处理。

## 5. Action 协议（v1 最小集合）

定义见 [`action.schema.json`](../schemas/v0.1/action.schema.json)。

### 5.1 三个对象

1. **ActionSpec（动作声明）**：由服务端写在交互块里。`{type, target, requiresConfirmation?, expiresAt?}`。
   - `type`：v1 只有 `choice.select`、`confirmation.respond`、`form.submit`。
   - `target`：服务端 Action Registry（动作注册表）里的处理器名，例如 `clarification.answer`、`todo.delete`。库不理解它的业务含义。
   - `requiresConfirmation`：破坏性操作为 `true`，此时只能出现在破坏性确认块上。
2. **ActionRequest（动作请求）**：客户端发出。

   ```json
   {
     "id": "01J9Z9A0K2…",
     "protocolVersion": "0.1",
     "type": "choice.select",
     "target": "clarification.answer",
     "context": { "conversationId": "conv_42", "messageId": "01J9Z8M5…", "blockId": "b4" },
     "payload": { "selected": ["bj"] },
     "clientTs": "2026-10-26T09:31:10Z"
   }
   ```
   - `id`：客户端生成，同时是**幂等键**（重复提交只执行一次，返回第一次的结果）。生命周期：
     - 用户在一个块上做出一次决定时生成一次；这个 ID 和块的交互状态一起放在 `chatweave_core` 里（不放在组件的 State 里），列表回收、组件重建、App 重启后都不会丢。
     - 网络错误、超时、离线排队后的重发，**一律复用同一个 ID**——请求可能已经被执行了。
     - 只有在服务端给出明确的拒绝（`rejected`）、块仍是 `open`、用户重新做了决定时，才生成新 ID。
     - 提交进行中再次点按不产生新请求（防双击）。
   - `context`：只有定位块所需的 ID。**用户是谁、属于哪个租户、有什么权限，一律由宿主在服务端推导，不信任客户端。**
   - `payload` 按类型：`choice.select` → `{selected: [选项id]}`；`confirmation.respond` → `{outcome: "confirm" | "cancel"}`；`form.submit` → `{values: {字段key: 值}}`。三种都可以改为 `{freeText: "…"}`（与上面的字段恰好一个），但只对**开着的中断**的块、且中断的 `otherInput` 不为 `false` 时有效（4.8 第 10 条）；已经结束的消息里的文字回答走普通消息（3.2）。
3. **ActionResult（动作结果）**：服务端返回。块所在的消息已经结束（最终回答里附带的问题）时，结果带 `rev` 补丁，引发的新一轮是一条新消息（`followUp`）：

   ```json
   {
     "actionId": "01J9Z9A0K2…",
     "status": "accepted",
     "patches": [ { "messageId": "01J9Z8M5…", "blockId": "b4", "rev": 2, "patch": { "data": { "state": { "status": "resolved", "selected": ["bj"], "resolvedBy": "member_7", "resolvedAt": "2026-10-26T09:31:11Z" } } } } ],
     "followUp": { "messageId": "01J9Z9B7…", "streamable": true }
   }
   ```

   块是一条暂停中的消息的中断块时（4.8），回答之后**同一条消息**继续：结果不带补丁，用 `resume` 指向这条消息，答案在它的流里以 `block.patch` 到达：

   ```json
   { "actionId": "01J9Z9D2P5…", "status": "accepted", "resume": { "messageId": "msg_03", "streamable": true } }
   ```

   群聊里别人先回答了的情况（客户端据此显示“已由另一位成员选择‘上海’”，而不是自己点的“北京”；一对一时同理，可能是同一用户在另一台设备上先答了）：

   ```json
   {
     "actionId": "01J9Z9C4M8…",
     "status": "rejected",
     "error": { "code": "already_resolved", "message": "这个问题已经有人回答了。" },
     "patches": [ { "messageId": "01J9Z8M5…", "blockId": "b4", "rev": 2, "patch": { "data": { "state": { "status": "resolved", "selected": ["sh"], "resolvedBy": "member_3", "resolvedAt": "2026-10-26T09:31:09Z" } } } } ]
   }
   ```
   - `status`：`completed`（同步完成）/ `accepted`（已受理，异步执行，例如回答了中断、运行即将继续，或重新排队一轮 Agent）/ `rejected`（校验、权限或状态不符，原样重试无意义）/ `failed`（执行出错，看 `error.retryable`）。
   - `error.code`：`invalid_payload`、`not_found`、`forbidden`、`already_resolved`、`expired`、`superseded`、`confirmation_required`、`target_mismatch`、`conflict`、`rate_limited`、`unavailable`、`unsupported`、`internal`。宿主可以把“无权限”也报成 `not_found`，以免泄露资源存在。几个容易混淆的：
     - `forbidden`：**这个人**不能回答这个块；`conflict`：**业务规则**不允许这次操作（例如状态已变化）。两者给用户的提示不同。
     - `already_resolved` / `expired` / `superseded`：块已经不是 `open`。结果**必须**带 `patches`，把块更新成服务端的真实状态；块所在的消息还没结束时（中断的块）改为带 `resume`，客户端从那条消息的流或快照拿真实状态（4.8）。
     - `unavailable`：服务端暂时无法给出结论，**动作可能已经执行**。客户端不得把它显示成“失败”，而是显示“暂时无法确认结果”，刷新块状态，必要时用**同一个 ID** 重试。客户端自己的超时同理。
   - `patches`：块状态变化，与流里的 `block.patch` 同形；同步下来的持久化版本 `rev` 相同，重复应用无副作用。客户端只根据 `patches`（或同步版本）显示结果。
   - `resume`：动作回答了一条暂停中的消息的中断，**同一条消息**继续；客户端按已应用的 `seq` 重新订阅它的流（4.8）。这时没有 `patches`，答案作为流里的 `block.patch` 到达。
   - `followUp`：动作引发了一条新的助手消息时给出其 ID，客户端可以去订阅它的流（块在一条已经结束的消息里时）。`resume` 和 `followUp` 不会同时出现。

### 5.2 服务端处理顺序（库的 dispatcher 固定执行）

1. 按 `context.messageId` / `blockId` **从宿主存储加载持久化的块**（宿主的加载函数同时做作用域校验，查不到即 `not_found`）。
2. 块里必须声明了 ActionSpec，且 `type`、`target` 与请求一致（否则 `target_mismatch`）；块状态必须是 `open`（否则按当前状态返回 `already_resolved` / `superseded`，并附上当前状态的补丁），未过期（否则 `expired`，同样附上补丁）。
3. **按块自身的声明校验 payload**：选的选项必须在 `options` 里、数量符合 `selection` / `minSelect` / `maxSelect`；表单值必须满足字段的类型、必填、范围、长度、选项。客户端无法提交块里没出现过的值。`freeText` 只在块是一个开着的中断的块、且该中断的 `otherInput` 不为 `false` 时接受（否则 `invalid_payload`），长度 1–500 字符，原样交给宿主，不做语义校验。
4. 处理器标记为破坏性时，请求必须来自 `severity: destructive` 的确认块，且 `outcome = confirm`（否则 `confirmation_required`）。
5. 幂等检查：同一个 `id` 已有结果则直接返回（`replayed: true`）。
6. 调用宿主处理器的 `authorize`（宿主自己的权限检查），再调用 `execute`。
7. 写入块的新状态（`rev + 1`），返回结果与补丁。块是暂停中的消息的中断块时不同：不加 `rev`，答案作为这条消息流里的 `block.patch` 发出，把答案交给宿主的 Agent 运行时继续这一轮，返回 `accepted` + `resume`（4.8 第 11 条）。

第 2 步与第 7 步必须在同一个事务（或等价的条件写入）里完成“检查仍为 `open` → 写入结果”，这样并发的两个答案只有一个能成功，另一个拿到 `already_resolved`。

**UI 动作 ≠ 工具授权**：一个块里出现了按钮，只代表“允许用户发起这个请求”，不代表请求一定被执行；执行与否由第 3、4、6 步决定。模型生成的内容永远无法直接获得工具执行权限。

### 5.3 没有动作通道时：只读

宿主没有提供 `ActionTransport`、会话是只读的，或宿主判定当前查看者不能回答这个块时，交互块**照常显示**内容和状态（包括已记录的结果），只是控件禁用并给出简短说明。库**不会**把“点选项”偷偷改成“把选项文字作为一条消息发出去”——那会绕过服务端对动作的校验，也会让结果无法对账。

### 5.4 不属于协议的消息级操作

对整条消息的反馈（点赞 / 点踩）、复制、转发等**不进协议**，也不写进消息（[D47](decisions.md)）。`chatweave_flutter` 在消息操作栏留插槽和回调，宿主自己决定怎么保存这些数据（[rendering.md 4.1](rendering.md#41-生成中的消息)）。

## 6. 降级规则（任何时候都能只看文本）

消费方按以下顺序处理每个块（每个块单独处理，一个块失败不影响其他块）：

1. 类型已注册且 `schemaVersion ≤ 支持的最高版本`，解析成功 → 渲染组件。
2. 内置的“降级链”可用（例如 `time_series` 不支持图表时转表格）→ 渲染降级组件。
3. 否则（包括组件在构建或渲染时出错）→ 渲染该块的 `fallbackText`（markdown 块没有 `fallbackText`，其文本本身就是兜底）。
4. 连 `fallbackText` 也缺失（不合规的生产方）→ 显示一行中性的“此内容无法显示”。

整条消息解析失败（例如协议主版本不认识）→ 只显示消息级 `fallbackText`。**Markdown-only 模式永远可用**：宿主可以把注册表清空，只渲染 markdown 块与 `fallbackText`。

## 7. 版本与能力协商

### 7.1 版本号

- `protocolVersion`：`主.次`。0.x 期间次版本可能破坏兼容；1.0 起主版本变化才破坏兼容。
- `schemaVersion`：每个块类型独立的整数版本。
- 演进规则：新增字段只能是可选的（旧消费方忽略）；含义变化就升 `schemaVersion` 或换新类型名；永不复用已删除字段的名字。

### 7.2 能力声明

客户端在每个可能产生助手消息的请求里声明自己能渲染什么（[`capabilities.schema.json`](../schemas/v0.1/capabilities.schema.json)）：

```json
{
  "protocolVersions": ["0.1"],
  "blocks": { "markdown": 1, "metric": 1, "metric_group": 1, "dataset": 1, "time_series": 1, "status": 1, "choice": 1, "confirmation": 1, "form_intent": 1, "x-todo.task_card": 1 },
  "features": ["stream.resume", "stream.snapshot", "stream.activity", "stream.steps", "action.choice", "action.confirmation", "action.form"],
  "locale": "zh-CN"
}
```

放不进请求体的场合（例如 SSE 的 GET 请求）用紧凑请求头：

```
ChatWeave-Capabilities: v=0.1; blocks=markdown:1,metric:1,metric_group:1,dataset:1,time_series:1,status:1,choice:1,confirmation:1,form_intent:1; features=stream.resume,stream.steps,action.choice
```

服务端的用法：

1. 选双方都支持的最高 `protocolVersion`；没有交集时只发 markdown + `fallbackText`。
2. 宿主把业务结果映射成块时，**优先选择客户端支持的类型**（例如客户端不支持 `time_series` 就直接给 `dataset`）。这是表现层面的选择，不改变数据。
3. 持久化的消息始终保存规范形态（canonical）。同一账号的另一台旧设备通过同步拿到它时，自己按第 6 节降级。

### 7.3 流响应头里的协议版本

服务端在流式响应头里写明这条流用的协议版本（[D44](decisions.md)）：

```
ChatWeave-Protocol: 0.1
```

客户端在读第一个事件之前先看这个头：不认识（例如主版本更高）就不解析事件，直接关闭连接，改从宿主同步取持久化版本，显示时按第 6 节降级（最差只显示 `fallbackText`）。头缺失时按事件里的 `protocolVersion` 判断（兼容早期实现）。

## 8. 保留：View 协议（Phase 2）

0.1 只保留名字，不得发出：

- 消息字段 `view`：将来存放受约束的布局描述，形如 `{"layout": …, "components": [{"id", "component", "dataRef": "/blocks/b3/data", "props"}]}`。**View 只能引用 Content 中的数据（`dataRef` 是指向块数据的 JSON Pointer），不能复制或改写业务事实。**
- 事件类型前缀 `view.`（如 `view.update`）。

消费方遇到这些一律忽略。

## 9. 限制（防止超大或恶意内容）

| 项 | 上限（协议默认） |
|---|---|
| 每条消息的块数 | 64 |
| 单块 `data` 序列化后大小 | 64 KB |
| 整条消息序列化后大小 | 256 KB |
| markdown 块文本 | 32 KB（32768 字符） |
| 单个 `block.delta` 文本 | 4 KB |
| 单个流事件 | 128 KB |
| `data` 内 JSON 嵌套深度 | 6 层（以 `data` 为第 1 层） |
| 单块 JSON 节点总数（对象 + 数组 + 标量） | 5,000 |
| `metric_group.metrics` | 12 |
| `dataset` 列 / 行 | 12 / 200 |
| `time_series` 序列 / 每条点数 | 6 / 500 |
| `comparison` 对象 / 维度 / 单元格 | 6 / 12 / 72 |
| `choice.options` | 10 |
| `form_intent.fields` / 每字段选项 | 12 / 20 |
| 普通标签 / 短按钮文字 / 说明文字 | 120 / 24 / 2000 字符 |
| `fallbackText`（块 / 消息） | 2000 / 16000 字符 |
| 每条消息的运行步骤（含子步骤） | 64 |
| 步骤嵌套层数 | 3 |
| 步骤 `label` / `summary` | 60 / 120 字符 |
| 每次暂停等待的中断 | 1 |
| 动作的 `freeText`（三种动作） | 500 字符 |

数量与长度上限写在 Schema 里；字节大小、深度、节点数由库的 `Limits` 校验（Schema 难以表达）。宿主可以把限制**调得更严**，不能调得比协议默认更宽（否则别的消费方可能拒收）。超限时生产方必须截断（并填 `totalRows` 之类的说明）或改发 markdown，不得发出超限块。

## 10. 与 A2UI 的映射意图（不依赖）

[A2UI](https://github.com/a2ui-project/a2ui) 是一个声明式生成 UI 协议（Agent 发 JSON 组件描述，客户端用白名单组件渲染）。它目前仍是早期预览（v0.9.1 为生产版，v1.0 为候选版），所以 ChatWeave 不依赖它，但字段形状尽量对齐，以便将来写一个机械的适配器：

| ChatWeave | A2UI（v0.9 / v1.0） | 说明 |
|---|---|---|
| 一条 Message | 一个 surface（`surfaceId = messageId`） | |
| `blocks[]` | `updateComponents.components[]`（扁平邻接表） | 都是扁平列表 + 稳定 `id` |
| 块 `type` | `component` | 内置类型对应一个 ChatWeave catalog |
| `x-<host>.*` 自定义类型 | 宿主自己的 `catalogId` | 转换时把 `x-host.name` 改写成合法标识符 `name`（A2UI 标识符不允许连字符） |
| 块 `data` | `updateDataModel` 中 `/blocks/{id}` 下的数据，组件用路径绑定 | 正好对应 Phase 2 的 “View 引用 Content 数据” |
| ActionSpec `{type, target}` | 组件上的 `action.event{name, context}` | `name = target` |
| ActionRequest | 客户端发出的 `action{name, surfaceId, sourceComponentId, timestamp, context}` | `sourceComponentId = blockId`，`context = payload` |
| 能力声明 | renderer capabilities / catalog 协商 | |

不打算映射的部分：A2UI 的双向数据绑定和客户端函数求值（ChatWeave v1 不需要，且会扩大安全面）。

### 10.1 运行过程事件：对齐 AG-UI

A2UI 管的是“内容长什么样”，而“Agent 正在做什么”（运行开始 / 结束、步骤、工具调用、子 Agent、中断、思考）是另一个层面的信息，[AG-UI](https://github.com/ag-ui-protocol/ag-ui) 是这方面的协议。ChatWeave v1 展示运行步骤（4.7，[D48](decisions.md)）并支持中断后在同一条消息里继续（4.8，[D53](decisions.md)），事件名和字段对齐 **AG-UI 1.0**（协议 1.0 于 2026-09-17 发布，以其仓库中的 `spec/1.0/schema.json` 和 Interrupts、Subagents 两篇概念文档为准，2026-10-26 核对）。形成“内容对齐 A2UI、过程对齐 AG-UI”的格局。

| ChatWeave | AG-UI 1.0 | 说明 |
|---|---|---|
| `message.start` / `message.end` | `RUN_STARTED` / `RUN_FINISHED`；`RUN_ERROR` | 一条助手消息里每一段“开始或继续 → 暂停或结束”对应一次运行（见下方第 9 条）。用户停止（`interrupted` + `cancelled`）≈ `outcome.type = "cancelled"` |
| `message.paused{interrupt}` | `RUN_FINISHED{outcome: {type: "interrupt", interrupts: [Interrupt]}}` | `Interrupt.id = interrupt.id`，`reason` 相同（`confirmation` / `input_required`），`message` = 块的 `fallbackText`，`expiresAt` = 块的 `action.expiresAt`，`metadata` 放 `stepId`、`blockId`；子 Agent 里发起的中断带 `subagentRunId`（见下） |
| 动作回答中断 + `message.resumed` | 新一次运行：`RunAgentInput.resume = [{interruptId, status: "resolved", payload}]`，`RUN_STARTED` | `payload` = 动作的 `payload`（`selected` / `outcome` / `values`，或任一动作的 `freeText`）；`otherInput` 是 ChatWeave 的扩展，放进 `Interrupt.metadata`；确认卡上点“取消”也是 `resolved`，拒绝写在 `payload` 里（与 AG-UI 一致） |
| 暂停中停止（含按 4.8 第 16 条先停止）/ 过期 | `resume` 里 `status: "cancelled"` 的运行以 `outcome.type = "cancelled"` 结束；过期 ≈ AG-UI 规定的过期答复 `RUN_ERROR` | ChatWeave 都以 `message.end{interrupted}` 结束这条消息（4.8 第 15–17 条） |
| `step.started{stepId, label}` | `STEP_STARTED{stepName, metadata?}` | 转换时 `stepName = stepId`，`label` 放进 `metadata.label` |
| `step.finished{stepId, state, durationMs, summary?}` | `STEP_FINISHED{stepName, metadata?}` | 转换时 `stepName = stepId`，其余字段放进 `metadata` |
| `step.started{kind: "delegate"}` | 再加一个 `SUBAGENT_STARTED{subagentRunId, name, parentSubagentRunId?}` | `subagentRunId` 由委派步骤的 `stepId` 派生（消息内唯一，一次委派一个值）；`name = label`（ChatWeave 不下发子 Agent 的内部名字）；外层还有委派步骤时 `parentSubagentRunId` 指向它 |
| 子步骤（带 `parentStepId`） | 事件带 `subagentRunId` | 取最近的上层委派步骤派生的 `subagentRunId`；主 Agent 的步骤不带（与 AG-UI“不带即属于父 Agent”一致） |
| 委派步骤的 `step.finished` | `SUBAGENT_FINISHED`（`succeeded`）/ `SUBAGENT_ERROR`（`failed`，`cancelled` 时 `code: "cancelled"`） | 暂停时还在运行的委派步骤（子 Agent 里有中断）在 `RUN_FINISHED` 之前发 `SUBAGENT_FINISHED{outcome: {type: "suspended", interruptIds}}`；继续时用**同一个** `subagentRunId` 再发 `SUBAGENT_STARTED`（AG-UI 允许并建议挂起的子 Agent 在继续时复用 ID） |
| （不下发） | `TOOL_CALL_START` / `TOOL_CALL_ARGS` / `TOOL_CALL_END` / `TOOL_CALL_RESULT` / `TOOL_CALL_CHUNK` | 见下方第 5 条 |
| （不下发） | `REASONING_*`（1.0 已移除旧的 `THINKING_*`） | 见下方第 6 条 |
| `message.activity` | 无直接对应 | AG-UI 的 `ACTIVITY_SNAPSHOT` / `ACTIVITY_DELTA` 是会留在消息列表里的活动消息；ChatWeave 的 activity 是不进日志、不持久化的临时提示（4.5），两者含义不同，不做映射 |

**与 AG-UI 不同之处（扩展清单）**，每处单列理由：

1. **事件名写法**：`step.started` / `step.finished`、`message.paused` / `message.resumed`（小写、点分）。理由：与 ChatWeave 已有事件的命名一致；一一对应，适配器只做机械改写。
2. **外层信封**：用 ChatWeave 的 `protocolVersion`、`messageId`、`seq`、`ts`（RFC 3339），而不是 AG-UI 的 `threadId` / `runId` 与整数 `timestamp`。理由：续传和去重依赖每条消息内的 `seq`（D6）；整个协议只用一种时间编码（D35）。
3. **用 `stepId` 配对，另设 `label`**：AG-UI 只有 `stepName`，它同时是标识和名字，开始与结束靠名字配对。ChatWeave 同一条消息里可能出现两个同名步骤（例如两次“查天气”），而名字是给人看的、群聊里还可能按接收者被替换（4.7 第 12 条），所以用稳定的 `stepId` 配对，`label` 单独给人看。
4. **`step.finished` 带结果状态 `state` 和 `durationMs`**：AG-UI 的 `STEP_FINISHED` 只有名字，失败只能通过整个运行的 `RUN_ERROR` 表达。ChatWeave 要求“一步失败只显示在这一行、不影响其他步骤和回答”，还要显示每一步的耗时，所以结果状态是一等字段（转换成 AG-UI 时放进 `metadata`）。
5. **不下发工具调用事件**（`TOOL_CALL_*`）：工具名、参数和原始结果是宿主内部信息，可能含业务数据，也不是给用户看的；用户看到的是宿主写的 `label` 和可选的 `summary`。一个步骤对应零个、一个或多个工具调用，由宿主决定。所以中断里也没有 `toolCallId`：AG-UI 的 `reason: "tool_call"` 要求带它，ChatWeave 只用 `confirmation` / `input_required`，被拦下的是哪个工具调用由宿主在服务端按中断 `id` 自己对应。接入只会发 AG-UI 事件的外部 Agent 时，适配器按宿主登记的“工具 → 标签”表把 `TOOL_CALL_START` 翻成 `step.started`、把 `TOOL_CALL_END` / `TOOL_CALL_RESULT` 翻成 `step.finished`，丢弃参数和结果；没登记的工具用宿主的笼统标签。
6. **不下发推理事件**（`REASONING_*`）：模型的思考文字不展示，也不传输（4.7 第 8 条）。理由：它是未经校验的模型原文，可能复述敏感数据或让用户误以为是结论；对“它做了什么”的理解帮助不大。
7. **步骤带 `seq`、进事件日志、进持久化消息**：AG-UI 不规定事件的持久化。ChatWeave 的步骤要在续传、快照、同步之后保持一致，并在消息结束后留下精简记录（`message.steps`）。
8. **子 Agent 用步骤树表达，不另设子 Agent 事件**：ChatWeave 没有 `SUBAGENT_*` 事件，委派就是一个 `kind: "delegate"` 的步骤，子 Agent 的工作是它的子步骤（`parentStepId`）。理由：用户关心的是“交给谁做了什么、做到哪了”，一棵步骤树就够表达，也只需要一套续传、折叠和持久化规则；转换成 AG-UI 是机械映射（上表）。比 AG-UI 更严格的地方：子步骤只能挂在还在运行的委派步骤下，委派步骤要等子步骤都结束才能结束（AG-UI 允许父先于子结束）；嵌套最多 3 层。
9. **暂停与继续是同一条消息、同一个 `seq` 序列**：AG-UI 的中断让本次运行以 `RUN_FINISHED{interrupt}` 结束，继续是带 `resume` 的另一次运行（新的 `runId`）。ChatWeave 里用户看到的是一条消息、一条过程条，所以继续沿用同一个 `messageId`，`seq` 接着数，续传、快照、持久化都不用跨消息拼接。转换成 AG-UI 时每一段对应一次运行（同一个 `threadId`，新的 `runId`）。
10. **每次暂停只有一个中断**：AG-UI 允许一次带多个中断，并要求一次 `resume` 全部回答。ChatWeave 0.1 每次暂停只等一个（[D57](decisions.md)）；需要问多件事时宿主一件一件问（同一条消息可以多次暂停）。理由：一次只显示一个问题，界面和“部分回答”的状态都简单；转换成 AG-UI 时 `interrupts` 只有一项，仍然合规。
11. **回答走 ChatWeave 的动作通道**：AG-UI 的回答是下一次 `RunAgentInput` 里的 `resume`；ChatWeave 的回答是对中断块的动作请求（第 5 节），服务端校验、幂等、先到者胜的规则与其他交互块完全相同，答案记在块的 `state` 里，多设备一致。`responseSchema` 不下发：问题的形状就是块本身（选项、确认、表单字段）。

Phase 3 的完整交互（点击下钻、筛选等）如果需要把用户操作交回 Agent，也沿用 4.8 的中断方式，不再另设字段。

## 11. 外部 Agent 的兼容

不会输出结构化块的 Agent（例如通用编程 / 助手类 Agent、普通 LLM）走**降级路径**：

- 它们的输出整体作为 `markdown` 块流式下发，`metadata.provenance = "adapter"`。
- **适配器不得为了生成组件而从文本里推断业务事实**（例如用正则把“温度 18 度”抽成 `metric`）。v1 也不支持在文本里嵌入代码围栏形式的 JSON 块。
- 想输出结构化内容的 Agent，只能通过宿主提供的**受控工具**提交（工具参数按块 Schema 校验），由宿主决定是否、如何生成块。

## 12. 在通用 IM 消息里承载 ChatWeave

ChatWeave 只描述“一条消息内部的内容”，不管会话列表、成员、已读这些 IM 层面的事。已有 IM 系统想展示 ChatWeave 内容时，不需要改协议，按下面的方式承载即可：

| IM 消息字段（通用说法） | 放什么 |
|---|---|
| 消息类型 | 一个表示“结构化内容”的类型 |
| 正文 | 完整的 ChatWeave Message JSON |
| 兜底文本 | `message.fallbackText`（不认识这种类型的客户端、通知、搜索都用它） |
| 交互结果 | 交互块的 `state`：谁（`resolvedBy`）、何时（`resolvedAt`）、选了什么 |

IM 客户端只要为这种消息类型写一个渲染插件、内部调用 ChatWeave 的渲染器就能显示；不认识的客户端显示兜底文本。
