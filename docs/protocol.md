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
- **ID**：`messageId` 由服务端生成（推荐 UUIDv7，即按时间排序的 UUID）；`blockId` 在所在消息内唯一且**稳定**——一旦分配，不得改指别的块，补丁、动作都按它定位。
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
| `id` | ✅ | 消息 ID |
| `protocolVersion` | ✅ | 生成这条消息时使用的协议版本，例如 `"0.1"` |
| `conversationId` | | 宿主的会话标识，库只当作不透明字符串 |
| `clientMessageId` | | 仅用户消息：发送端在服务端分配 `id` 之前生成的 ID，持久化后原样带回，用来替换本地的乐观副本（见下文） |
| `role` | ✅ | `assistant` / `user` / `system`。用户消息通常只有一个 markdown 块 |
| `status` | ✅ | `streaming`（生成中）/ `complete`（正常结束）/ `interrupted`（中途停止，已产出的内容保留）/ `error`（没有可用内容，`fallbackText` 说明原因） |
| `blocks` | ✅ | 内容块，最多 64 个 |
| `fallbackText` | ✅ | **整条消息的纯文本版本，任何状态下都必须有**。用于只会显示文本的客户端、系统通知、读屏、搜索 |
| `rev` | ✅ | 持久化版本号：生成中为 0；完成时为 1；之后每次变化（例如选项块被回答）+1。**同步时 rev 大的版本获胜** |
| `metadata` | | 宿主自用的不透明数据（如追踪 ID），库不渲染 |
| `view` | | **保留**给 Phase 2 的 View 协议，0.1 中不得出现 |

**持久化版本优先**：流式过程中客户端在内存里拼出的消息只是临时状态；服务端在 `message.end` 时持久化最终消息，经宿主的同步机制下发。断线重连或离线之后，**以持久化版本为准**，临时状态被整体替换。

**乐观的用户消息按 `clientMessageId` 对账**：用户发出消息时，客户端先在本地显示一条带 `clientMessageId` 的乐观消息；宿主同步下来的持久化消息带着同一个 `clientMessageId`，客户端用它**原地替换**本地副本（列表里的行身份不变，不闪烁、不重复）。发送失败的消息留在本地并标“未发送”，重试**复用同一个** `clientMessageId`，服务端据此去重。客户端**不得**按文本、发送人或时间去猜哪条持久化消息对应哪条本地消息；宿主无法回传 `clientMessageId` 时，客户端应重新拉取该会话的最新消息，再丢弃本地副本。

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

`allowFreeText: true` 表示除了点选项，用户也可以**直接在输入框里用文字回答**：这条回答作为一条**普通用户消息**发出，不走动作通道；宿主把它关联到这个仍为 `open` 的块，并在服务端把块写成 `resolved`（`freeText` 记录回答文本）。动作请求里只能带选项。

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
3. 自定义类型同样只放语义数据。推荐**只放引用**（如 `{"recordId": "…"}`），由宿主组件从本地数据源读取最新内容——这样编辑 / 撤销后卡片自动更新，也不会把业务数据复制进聊天记录。
4. 自定义块必须带 `fallbackText`。

### 3.4 交互块的状态（`choice` / `confirmation` / `form_intent`）

交互块的 `state` **只由服务端写**，并且只在服务端已经记录了结果之后才变化：

| `state.status` | 含义 | 客户端显示 |
|---|---|---|
| `open` | 等待回答 | 可操作（前提见 [rendering.md 4.2](rendering.md#42-交互块的显示状态)） |
| `resolved` | 已记录一个答案：`selected` / `outcome` / `values` / `freeText`，以及 `resolvedBy`（宿主的不透明成员 ID）、`resolvedAt`（必填） | 服务端记录的结果和“谁、何时”；控件禁用 |
| `expired` | 到了 `action.expiresAt` 仍没有回答 | “已过期”，控件禁用 |
| `cancelled` | 服务端撤回了这次询问 | “已取消”，控件禁用 |
| `superseded` | 被一个更新的交互块取代（例如助手针对同一操作重新发了一张确认卡），`supersededBy` 指向新块 | “已被新的请求取代”，控件禁用 |

规则：

1. **不乐观显示结果。** 用户点下去之后，客户端只显示“提交中”（离线排队时显示“已排队，联网后提交”），**不**把自己点的选项先画成“已选择”。只有收到服务端的 `ActionResult.patches`、流里的 `block.patch`，或宿主同步下来的更高 `rev` 时，才显示结果。“提交中 / 已排队”是客户端本地的显示状态，**不属于协议**，也不会出现在 `state.status` 里。
2. **先答者胜。** 同一个块可能同时出现在多台设备、多个人面前。服务端以第一个被记录的答案为准；后到的请求得到 `already_resolved`，并且结果里**必须**带上块的当前状态（`patches`），客户端据此显示服务端的真实结果（例如“已由另一位成员选择‘北京’”），而不是自己刚才点的那个。
3. 一旦离开 `open`，块不再接受任何动作。

## 4. 流式事件（Stream Events）

定义见 [`stream-event.schema.json`](../schemas/v0.1/stream-event.schema.json)；端到端示例、SSE 封装、断线续传见 [streaming.md](streaming.md)。

### 4.1 事件公共字段

| 字段 | 说明 |
|---|---|
| `protocolVersion` | 如 `"0.1"` |
| `type` | 事件类型，见下表 |
| `messageId` | 所属消息 |
| `seq` | **每条消息从 1 开始、每个事件严格 +1** 的序号 |
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
| `message.snapshot` | `message`（完整消息） | 续传时无法按序重放、或服务端不保留事件日志时，直接发完整状态 |
| `error` | `error{code, message, retryable}`、`blockId?` | 流级错误 |

**JSON Merge Patch**（RFC 7396，“合并补丁”）：补丁对象里出现的字段覆盖原值，值为 `null` 表示删除该字段，数组整体替换。它比逐条操作的 JSON Patch（RFC 6902）简单，足够表达 v1 的状态更新。

### 4.3 v1 的流式范围

- **Markdown 文本逐步出现**：`block.start(markdown)` → 若干 `block.delta` → `block.end`。
- **组件块整块到达**：`block.start` 时创建占位，`block.data` 时一次填满，然后 `block.end`。v1 **不做**组件字段级的增量流式（例如表格逐行出现），留给 Phase 3。
- 同一时刻最多一个 markdown 块处于打开状态；组件块可以先占位、稍后填充，期间后续 markdown 可以继续输出（例如工具查询还在进行时文字先说）。
- 块按 `index` 顺序开始；`index` 就是它在最终 `blocks` 中的位置。

### 4.4 顺序、幂等与修订号

- **`seq`（流内顺序）**：消费方记住每条消息最后应用的 `seq`；收到 `seq ≤ 已应用` 的事件直接丢弃（幂等）；收到跳号（`seq > 已应用 + 1`）就断开并带上已应用的 `seq` 重连续传，不尝试“先放着等补齐”。
- **`rev`（持久化版本）**：消息完成后发生的变化（例如选项块被回答）带 `rev`。规则：`rev == 本地 rev + 1` 才应用；`≤ 本地 rev` 忽略；跳号则向宿主存储 / 同步重新取整条消息。
- 未知事件类型：忽略内容但照常推进 `seq`。

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
   - `payload` 按类型：`choice.select` → `{selected: [选项id]}`（自由文本回答走普通消息，见 3.2）；`confirmation.respond` → `{outcome: "confirm" | "cancel"}`；`form.submit` → `{values: {字段key: 值}}`。
3. **ActionResult（动作结果）**：服务端返回。

   ```json
   {
     "actionId": "01J9Z9A0K2…",
     "status": "accepted",
     "patches": [ { "messageId": "01J9Z8M5…", "blockId": "b4", "rev": 2, "patch": { "data": { "state": { "status": "resolved", "selected": ["bj"], "resolvedBy": "member_7", "resolvedAt": "2026-10-26T09:31:11Z" } } } } ],
     "followUp": { "messageId": "01J9Z9B7…", "streamable": true }
   }
   ```

   别人先回答了的情况（客户端据此显示“已由另一位成员选择‘上海’”，而不是自己点的“北京”）：

   ```json
   {
     "actionId": "01J9Z9C4M8…",
     "status": "rejected",
     "error": { "code": "already_resolved", "message": "这个问题已经有人回答了。" },
     "patches": [ { "messageId": "01J9Z8M5…", "blockId": "b4", "rev": 2, "patch": { "data": { "state": { "status": "resolved", "selected": ["sh"], "resolvedBy": "member_3", "resolvedAt": "2026-10-26T09:31:09Z" } } } } ]
   }
   ```
   - `status`：`completed`（同步完成）/ `accepted`（已受理，异步执行，例如重新排队一轮 Agent）/ `rejected`（校验、权限或状态不符，原样重试无意义）/ `failed`（执行出错，看 `error.retryable`）。
   - `error.code`：`invalid_payload`、`not_found`、`forbidden`、`already_resolved`、`expired`、`superseded`、`confirmation_required`、`target_mismatch`、`conflict`、`rate_limited`、`unavailable`、`unsupported`、`internal`。宿主可以把“无权限”也报成 `not_found`，以免泄露资源存在。几个容易混淆的：
     - `forbidden`：**这个人**不能回答这个块；`conflict`：**业务规则**不允许这次操作（例如状态已变化）。两者给用户的提示不同。
     - `already_resolved` / `expired` / `superseded`：块已经不是 `open`。结果**必须**带 `patches`，把块更新成服务端的真实状态。
     - `unavailable`：服务端暂时无法给出结论，**动作可能已经执行**。客户端不得把它显示成“失败”，而是显示“暂时无法确认结果”，刷新块状态，必要时用**同一个 ID** 重试。客户端自己的超时同理。
   - `patches`：块状态变化，与流里的 `block.patch` 同形；同步下来的持久化版本 `rev` 相同，重复应用无副作用。客户端只根据 `patches`（或同步版本）显示结果。
   - `followUp`：动作引发了一条新的助手消息时给出其 ID，客户端可以去订阅它的流。

### 5.2 服务端处理顺序（库的 dispatcher 固定执行）

1. 按 `context.messageId` / `blockId` **从宿主存储加载持久化的块**（宿主的加载函数同时做作用域校验，查不到即 `not_found`）。
2. 块里必须声明了 ActionSpec，且 `type`、`target` 与请求一致（否则 `target_mismatch`）；块状态必须是 `open`（否则按当前状态返回 `already_resolved` / `superseded`，并附上当前状态的补丁），未过期（否则 `expired`，同样附上补丁）。
3. **按块自身的声明校验 payload**：选的选项必须在 `options` 里、数量符合 `selection` / `minSelect` / `maxSelect`；表单值必须满足字段的类型、必填、范围、长度、选项。客户端无法提交块里没出现过的值。
4. 处理器标记为破坏性时，请求必须来自 `severity: destructive` 的确认块，且 `outcome = confirm`（否则 `confirmation_required`）。
5. 幂等检查：同一个 `id` 已有结果则直接返回（`replayed: true`）。
6. 调用宿主处理器的 `authorize`（宿主自己的权限检查），再调用 `execute`。
7. 写入块的新状态（`rev + 1`），返回结果与补丁。

第 2 步与第 7 步必须在同一个事务（或等价的条件写入）里完成“检查仍为 `open` → 写入结果”，这样并发的两个答案只有一个能成功，另一个拿到 `already_resolved`。

**UI 动作 ≠ 工具授权**：一个块里出现了按钮，只代表“允许用户发起这个请求”，不代表请求一定被执行；执行与否由第 3、4、6 步决定。模型生成的内容永远无法直接获得工具执行权限。

### 5.3 没有动作通道时：只读

宿主没有提供 `ActionTransport`、会话是只读的，或宿主判定当前查看者不能回答这个块时，交互块**照常显示**内容和状态（包括已记录的结果），只是控件禁用并给出简短说明。库**不会**把“点选项”偷偷改成“把选项文字作为一条消息发出去”——那会绕过服务端对动作的校验，也会让结果无法对账。

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
  "features": ["stream.resume", "stream.snapshot", "action.choice", "action.confirmation", "action.form"],
  "locale": "zh-CN"
}
```

放不进请求体的场合（例如 SSE 的 GET 请求）用紧凑请求头：

```
ChatWeave-Capabilities: v=0.1; blocks=markdown:1,metric:1,metric_group:1,dataset:1,time_series:1,status:1,choice:1,confirmation:1,form_intent:1; features=stream.resume,action.choice
```

服务端的用法：

1. 选双方都支持的最高 `protocolVersion`；没有交集时只发 markdown + `fallbackText`。
2. 宿主把业务结果映射成块时，**优先选择客户端支持的类型**（例如客户端不支持 `time_series` 就直接给 `dataset`）。这是表现层面的选择，不改变数据。
3. 持久化的消息始终保存规范形态（canonical）。同一账号的另一台旧设备通过同步拿到它时，自己按第 6 节降级。

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

### 10.1 运行过程事件：参照 AG-UI

A2UI 管的是“内容长什么样”，而“Agent 正在做什么”（运行开始 / 结束、工具调用、思考中）是另一个层面的信息。ChatWeave v1 不展示运行过程（`status` 块是内容，不是运行事件）。将来如果要展示，**事件名和字段采用 [AG-UI](https://github.com/ag-ui-protocol/ag-ui) 1.0 的定义**（例如 `RUN_STARTED`、`TOOL_CALL_START`），ChatWeave 自己的信息放在外层信封里，并维护一张“与 AG-UI 不同之处”的扩展清单，每处扩展单独列出理由。形成“内容对齐 A2UI、过程对齐 AG-UI”的格局。

同理，Phase 3 中“确认后交回 Agent 继续”的交互，`ActionSpec` 可以带一个不透明的 `toolCallId`，dispatcher 把用户的回答作为那次工具调用的结果交回宿主的 Agent 运行时，形状上对齐 AG-UI 的中断（interrupt）模式。0.1 不包含这个字段。

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
