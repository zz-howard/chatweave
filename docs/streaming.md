# 流式传输（草案 0.1）

> **状态：草案。** 事件定义见 [protocol.md 第 4 节](protocol.md#4-流式事件stream-events) 与 [`stream-event.schema.json`](../schemas/v0.1/stream-event.schema.json)。本文讲事件怎么在线上传、断了怎么续、客户端怎么合并，以及怎样避免界面跳动。

## 1. 目标与 v1 范围

- 文字**边生成边显示**，不等整条消息结束。
- 组件块在它该在的位置先出现占位，数据到达时整块填满；v1 不做组件字段级增量。
- 事件可以重复、可以断线，客户端最终状态与服务端持久化的消息一致；**断线 / 离线之后以持久化版本为准**。
- 普通 Markdown 回复不因为 UI 系统额外变慢：不额外调用模型，不额外往返。
- AI 回答前做的几件事（查数据、对比、等用户确认）作为**运行步骤**在同一条流里下发，显示在消息顶部的“过程”条里；它们和块事件一样可续传、可折叠，但与内容分开存放（[protocol.md 4.7](protocol.md#47-运行步骤stepstarted--stepfinished)）。

## 2. 端到端示例

场景（示例 App 的天气 + 待办助手）：用户问“北京今天天气怎么样？顺便看看我这周的待办”。助手回复 = 一段文字 + 一组天气指标（`metric_group`）+ 一段文字 + 一张待办表（`dataset`）+ 一句收尾。

### 2.1 服务端怎么产生这些事件

```
模型流 ──文字 token──▶ 当前 markdown 块的 block.delta（服务端合并成 ≥ 约 20 字或 50ms 一批）
      └─工具调用 get_weather(city) ──▶ 关闭当前 markdown 块
                                      block.start(metric_group, 占位)
                                      宿主执行真实查询 → 按 Schema 校验 → block.data → block.end
      └─继续输出文字 ──▶ 新的 markdown 块
```

数字来自工具（宿主执行的真实查询），**不是模型编的**；模型只决定“这里该展示天气”。

### 2.2 事件序列

下面每个事件都是一个 SSE 帧（封装见第 3 节），这里只列 `data` 中的 JSON。`protocolVersion` 与 `messageId` 每个事件都有，为便于阅读只在第一个事件中写全，其余用 `…` 省略。

```json
{"protocolVersion":"0.1","type":"message.start","messageId":"msg_01","seq":1,"message":{"id":"msg_01","role":"assistant","conversationId":"conv_42","createdAt":"2026-10-26T09:30:00Z"}}
{…,"type":"block.start","seq":2,"blockId":"b1","index":0,"blockType":"markdown","schemaVersion":1}
{…,"type":"block.delta","seq":3,"blockId":"b1","delta":{"text":"北京今天"}}
{…,"type":"block.delta","seq":4,"blockId":"b1","delta":{"text":"**晴**，白天比较暖和："}}
{…,"type":"block.end","seq":5,"blockId":"b1","status":"complete"}
{…,"type":"block.start","seq":6,"blockId":"b2","index":1,"blockType":"metric_group","schemaVersion":1,"placeholder":{"size":"small","items":3}}
{…,"type":"block.data","seq":7,"blockId":"b2","data":{"title":"北京 · 今天","metrics":[{"label":"最高","value":18,"unit":"°C"},{"label":"最低","value":7,"unit":"°C"},{"label":"降水概率","value":0.1,"format":{"style":"percent"},"assessment":{"status":"positive","label":"适合出门"}}]},"fallbackText":"北京今天：最高 18°C，最低 7°C，降水概率 10%（适合出门）","metadata":{"provenance":"tool","asOf":"2026-10-26T09:00:00Z"}}
{…,"type":"block.end","seq":8,"blockId":"b2","status":"complete"}
{…,"type":"block.start","seq":9,"blockId":"b3","index":2,"blockType":"markdown","schemaVersion":1}
{…,"type":"block.delta","seq":10,"blockId":"b3","delta":{"text":"你这周还有 3 件待办没完成，"}}
{…,"type":"block.delta","seq":11,"blockId":"b3","delta":{"text":"最近的是周三交水费："}}
{…,"type":"block.end","seq":12,"blockId":"b3","status":"complete"}
{…,"type":"block.start","seq":13,"blockId":"b4","index":3,"blockType":"dataset","schemaVersion":1,"placeholder":{"size":"medium","items":3}}
{…,"type":"block.data","seq":14,"blockId":"b4","data":{"title":"本周待办","columns":[{"key":"title","label":"事项","type":"string"},{"key":"due","label":"截止","type":"date"},{"key":"priority","label":"优先级","type":"string"}],"rows":[{"title":"交水费","due":"2026-10-28","priority":"高"},{"title":"取快递","due":"2026-10-29","priority":"普通"},{"title":"预约体检","due":"2026-10-31","priority":"普通"}],"sort":{"key":"due","direction":"asc"}},"fallbackText":"本周待办：交水费（10-28，高）；取快递（10-29，普通）；预约体检（10-31，普通）","metadata":{"provenance":"host"}}
{…,"type":"block.end","seq":15,"blockId":"b4","status":"complete"}
{…,"type":"block.start","seq":16,"blockId":"b5","index":4,"blockType":"markdown","schemaVersion":1}
{…,"type":"block.delta","seq":17,"blockId":"b5","delta":{"text":"要我给“交水费”设个提醒吗？"}}
{…,"type":"block.end","seq":18,"blockId":"b5","status":"complete"}
{…,"type":"message.end","seq":19,"status":"complete","blockCount":5,"rev":1,"fallbackText":"北京今天晴，白天比较暖和：最高 18°C，最低 7°C，降水概率 10%（适合出门）。你这周还有 3 件待办没完成，最近的是周三交水费：交水费（10-28，高）；取快递（10-29，普通）；预约体检（10-31，普通）。要我给“交水费”设个提醒吗？"}
```

（示例日期 2026-10-28 为星期三。）

**变体：组件先占位、文字继续。** 如果天气查询较慢，服务端可以在 seq 6 发出 `block.start(b2)` 后不等结果，继续开 `b3` 输出文字；查询返回后再发 `block.data(b2)`。客户端在 b2 的位置显示骨架占位，文字在它下方继续出现，数据到达后占位原地填满。

### 2.3 最终持久化的消息

`message.end` 时服务端把下列消息写入宿主存储（是否与宿主自己的任务状态更新放在同一事务里，由宿主决定），然后经宿主的同步机制下发：

```json
{
  "id": "msg_01", "protocolVersion": "0.1", "conversationId": "conv_42",
  "role": "assistant", "status": "complete", "rev": 1,
  "createdAt": "2026-10-26T09:30:00Z", "completedAt": "2026-10-26T09:30:03Z",
  "fallbackText": "北京今天晴，白天比较暖和：……要我给“交水费”设个提醒吗？",
  "blocks": [
    { "id": "b1", "type": "markdown", "schemaVersion": 1, "data": { "text": "北京今天**晴**，白天比较暖和：" } },
    { "id": "b2", "type": "metric_group", "schemaVersion": 1, "data": { "title": "北京 · 今天", "metrics": [ "…同 seq 7…" ] }, "fallbackText": "北京今天：最高 18°C……", "metadata": { "provenance": "tool", "asOf": "2026-10-26T09:00:00Z" } },
    { "id": "b3", "type": "markdown", "schemaVersion": 1, "data": { "text": "你这周还有 3 件待办没完成，最近的是周三交水费：" } },
    { "id": "b4", "type": "dataset", "schemaVersion": 1, "data": { "…": "同 seq 14" }, "fallbackText": "本周待办：……", "metadata": { "provenance": "host" } },
    { "id": "b5", "type": "markdown", "schemaVersion": 1, "data": { "text": "要我给“交水费”设个提醒吗？" } }
  ]
}
```

客户端和服务端用**同一个折叠函数（reducer）**把事件序列变成消息：`fold(events) == 持久化消息`。这条等式是一致性测试（conformance fixtures）的核心断言，Rust 与 Dart 两端都要通过同一批夹具。

### 2.4 临时进度事件

天气查询要几秒时，服务端可以在 `block.start(b2)` 之后插入临时提示（[protocol.md 4.5](protocol.md#45-临时进度事件messageactivity)）。它们**没有 `seq`**，不写日志、不参与折叠，上面 2.2 的序列和 2.3 的最终消息都不变：

```json
{"protocolVersion":"0.1","type":"message.activity","messageId":"msg_01","activity":{"phase":"working","label":"正在查天气…"}}
{"protocolVersion":"0.1","type":"message.activity","messageId":"msg_01","activity":{"phase":"still_working","label":"仍在查询，请稍候"}}
```

客户端在 b2 的占位旁显示最新一条提示；seq 7 的 `block.data` 到达时清除。

### 2.5 运行步骤

另一条消息：用户问“对比一下北京和上海这周的天气，再看看我这周的待办”。助手先并行查两个城市（上海的查询失败），再读待办，然后回答。步骤事件和块事件在同一条流里、共用同一个 `seq` 序列（[protocol.md 4.7](protocol.md#47-运行步骤stepstarted--stepfinished)）：

```json
{"protocolVersion":"0.1","type":"message.start","messageId":"msg_02","seq":1,"message":{"id":"msg_02","role":"assistant","conversationId":"conv_42","createdAt":"2026-10-26T09:40:00Z"}}
{…,"type":"step.started","seq":2,"stepId":"s1","label":"查北京本周天气"}
{…,"type":"step.started","seq":3,"stepId":"s2","label":"查上海本周天气"}
{…,"type":"step.finished","seq":4,"stepId":"s1","state":"succeeded","durationMs":800}
{…,"type":"step.finished","seq":5,"stepId":"s2","state":"failed","durationMs":1200,"summary":"天气服务暂时不可用"}
{…,"type":"step.started","seq":6,"stepId":"s3","label":"读取本周待办"}
{…,"type":"step.finished","seq":7,"stepId":"s3","state":"succeeded","durationMs":300,"summary":"找到 3 件"}
{…,"type":"block.start","seq":8,"blockId":"b1","index":0,"blockType":"markdown","schemaVersion":1}
{…,"type":"block.delta","seq":9,"blockId":"b1","delta":{"text":"北京这周都是晴天；上海的天气暂时查不到。你这周还有 3 件待办，最近的是周三交水费。"}}
{…,"type":"block.end","seq":10,"blockId":"b1","status":"complete"}
{…,"type":"message.end","seq":11,"status":"complete","blockCount":1,"rev":1,"fallbackText":"北京这周都是晴天；上海的天气暂时查不到。你这周还有 3 件待办，最近的是周三交水费。"}
```

折叠后，持久化消息除了 `blocks` 之外多一个 `steps`（`fallbackText` 和 `blockCount` 都不包含步骤）：

```json
{"steps":[{"id":"s1","label":"查北京本周天气","state":"succeeded","durationMs":800},{"id":"s2","label":"查上海本周天气","state":"failed","durationMs":1200,"summary":"天气服务暂时不可用"},{"id":"s3","label":"读取本周待办","state":"succeeded","durationMs":300,"summary":"找到 3 件"}]}
```

界面上：seq 2–7 期间过程条展开，逐行显示“查北京本周天气 ✓ 0.8 秒”“查上海本周天气 · 失败”“读取本周待办 ⏳”；上海失败不影响其他步骤，也不影响回答。`message.end` 到达后过程条自动收起成一行“查了 3 项（1 项失败）· 用时 4 秒”，点按可展开（[rendering.md 4.3](rendering.md#43-运行过程条processstrip)）。

**变体：等用户确认。** 用户说“把交水费删了”：服务端开始步骤“准备删除待办”，暂存待执行的删除操作，发出确认块 `b2`，再发 `step.finished{state: "awaiting_user", blockId: "b2"}`，然后以 `complete` 结束消息。过程条这一行显示“等你确认”，确认卡在正文里；用户确认后这一行跟着块的状态显示“已确认”，真正的删除和后续回答在 `followUp` 的新消息里，有自己的步骤。

**变体：生成中停止。** 步骤 s3 还在运行时用户按停止：服务端先发 `step.finished{stepId: "s3", state: "cancelled"}`，再发 `message.end{status: "interrupted", error.code: "cancelled"}`。

## 3. SSE 封装

**SSE（Server-Sent Events）** 是浏览器标准里的“服务器单向推送”格式：一个长连接的 HTTP 响应，内容类型 `text/event-stream`，按空行分隔的文本帧往下推。选它而不是 WebSocket 的原因：只需要服务端→客户端单向；就是普通 HTTP，反向代理和鉴权中间件照常工作；自带断线续传约定（`Last-Event-ID`）。

### 3.1 端点（推荐形态，路径由宿主决定）

```
GET {宿主前缀}/messages/{messageId}/stream
Accept: text/event-stream
Authorization: …（宿主自己的鉴权）
ChatWeave-Capabilities: v=0.1; blocks=…; features=stream.resume,stream.snapshot
Last-Event-ID: 11        ← 续传时带上；也可以用查询参数 ?after=11（给无法设置请求头的客户端）
X-Request-Id: …          ← 宿主的追踪 ID，可选
```

响应：

| 情况 | 响应 |
|---|---|
| 正常 | `200`，`Content-Type: text/event-stream`，`Cache-Control: no-store`，`ChatWeave-Protocol: 0.1`（本流的协议版本，[protocol.md 7.3](protocol.md#73-流响应头里的协议版本)），并关闭代理缓冲（如 `X-Accel-Buffering: no`） |
| 消息不存在 / 无权访问 | 由宿主决定，推荐统一 `404`，不区分两者 |
| 消息早已完成 | `200`，只发一个 `message.snapshot` 然后关闭；或宿主直接 `204` 让客户端走同步 |

### 3.2 帧格式

```
retry: 2000

id: 1
event: message.start
data: {"protocolVersion":"0.1","type":"message.start","messageId":"msg_01","seq":1,"message":{…}}

id: 2
event: block.start
data: {"protocolVersion":"0.1","type":"block.start","messageId":"msg_01","seq":2,"blockId":"b1",…}

: ping

```

- `id` = 本事件的 `seq`；`event` = 事件 `type`（便于调试，客户端以 `data` 里的 `type` 为准）；`data` = 单行 JSON。
- 临时事件 `message.activity` **不写 `id:` 行**（它没有 `seq`）。按 SSE 规范，没有 `id:` 的帧不改变“最后事件 ID”，所以续传位置不受它影响：

  ```
  event: message.activity
  data: {"protocolVersion":"0.1","type":"message.activity","messageId":"msg_01","activity":{"phase":"working","label":"正在查天气…"}}

  ```
- 开头的 `retry: 2000` 建议客户端断线后 2 秒重连（客户端仍应做指数退避，上限例如 30 秒）。
- 每 15 秒发一行注释 `: ping` 作心跳，防止代理或运营商网关切断空闲连接；客户端超过 45 秒没收到任何字节就主动重连。
- `message.end` 或流级 `error` 之后服务端关闭连接。

### 3.3 为什么按“每条消息一条流”

**已定（[D7](decisions.md)、[D20](decisions.md)）：每条消息一条流，不按会话合并。** 一条助手消息对应一条流，`seq` 在消息内从 1 计数。好处：续传语义最简单（一个整数）；多台设备可以同时订阅同一条消息；一次请求里只有一个生成过程。代价：一个会话里同时生成多条消息时要开多条连接——v1 的聊天场景同一时刻通常只生成一条，宿主可以用每用户的流数量上限（第 8 节）兜住。只有当“一次请求产生多条助手消息”或“会话内并发生成”成为真实需求时才重新评估。

## 4. 断线续传

### 4.1 服务端：事件日志

库定义 `EventLog` 接口。**默认实现是进程内环形缓冲**（[D42](decisions.md)）：每条正在生成的消息一个按 `seq` 排列的缓冲，消息结束后保留到保留期满。需要更强保证的宿主自己实现持久日志（例如一张 PostgreSQL 表 `(message_id, seq, event_json, created_at)`）。

| | 进程内缓冲（默认） | 持久日志（可选） |
|---|---|---|
| 适合 | 单实例服务端 | 多实例部署；要求服务端重启后仍能逐事件续传 |
| 服务端重启后续传 | 缓冲已空 → 发 `message.snapshot`（来自消息存储里的检查点或最终消息），客户端整体替换后照常接收 | 照常逐事件重放 |
| 续传请求落到另一个实例 | 那个实例没有缓冲 → 快照 | 照常重放 |
| 崩溃恢复 | 从最近的检查点恢复，标 `interrupted`；检查点之后的内容丢失 | 从日志折叠，标 `interrupted` |
| 写入量 | 只有检查点 | 每个事件（delta 已合并成小批）一行 |

使用默认实现时，宿主在每个 `block.end`、且至少每隔几秒（例如 5 秒），把折叠后的临时消息（`status = streaming`、`rev = 0`）和最后的 `seq` 写入消息存储作为**检查点**。这样崩溃不会丢掉整条消息，也避免“只在生成结束时才落库”。

两种实现的共同规则：

- 生成过程中每个事件**先追加到日志再广播**给在线订阅者（进程内广播通道）。
- 续传请求带 `Last-Event-ID = N`：服务端先从日志重放 `seq > N` 的事件，再接上实时广播；重放与实时之间按 `seq` 去重，保证不漏不重。
- 保留期（**已定，[D21](decisions.md)**）：默认保留到 `message.end` 之后 **10 分钟**（宿主可配置）；过期后清理。10 分钟覆盖了常见的短暂断线、切后台和弱网重连；更久之后客户端走快照或宿主同步，不再需要逐事件重放。日志里有内容，访问它与访问消息本身用同一套权限检查，保留期结束必须删除。存放位置：默认在进程内存里（见上表）；宿主可以换成数据库表等持久实现。

### 4.2 无法重放时：快照

如果 `N` 早于日志里最早的事件、日志已清理、或宿主根本不保留日志，服务端发送 `message.snapshot`：

- 内容是此刻的完整消息（生成中则 `status = streaming`、`rev = 0`），包括运行步骤 `steps`（生成中可能有 `running` 的步骤，之后照常接收它们的 `step.finished`）。
- 它的 `seq` 等于快照所反映的最后一个事件的 `seq`。消费方在 `snapshot.seq ≥ 已应用 seq` 时用它**整体替换**本地状态，并把已应用 seq 设为 `snapshot.seq`，之后照常接收后续事件。
- 宿主因此需要随消息保存“最后一个 seq”。

客户端未声明 `stream.snapshot` 能力时，服务端改为返回流级 `error{code: "resume_unavailable"}` 并关闭；客户端随后通过宿主的同步机制取持久化版本。

### 4.3 客户端：续传状态机

```
          ┌──────────── 收到 message.end ───────────┐
          ▼                                          │
 [空闲] ─订阅─▶ [连接中] ─200─▶ [接收中] ──事件──▶ 应用（seq 去重）
                  ▲               │   │
                  │      断线 / 心跳超时 / 跳号
                  └─退避重连(Last-Event-ID = 已应用 seq)─┘
                                      │ 用户按“停止”
                                      ▼
                               [已请求停止] ── 现有连接继续收，直到 message.end
                                      │ 期间断线：不自动重连这条消息，等持久化版本
 宿主同步送来同一消息且 rev ≥ 1 ──▶ 用持久化版本替换，停止订阅（任何状态下）
```

- 已应用的 `seq` 和临时消息状态由宿主的存储接口持久化（例如每 1 秒或每个 `block.end` 节流写一次），**App 被杀后重启也能续传**。
- **续传触发时机**：除了连接断开 / 心跳超时 / 跳号，以下时刻也要检查所有未完成（`status = streaming` 且没有持久化版本）的消息并按需续传：打开会话、切回会话、网络恢复、App 回到前台。移动端系统常在后台静默切断连接，回到前台时主动检查比等心跳超时快得多。
- **同一条消息同时只有一个续传**（单飞）：多个触发同时发生时合并成一次，不并发开多条连接。
- **有上限**：一次续传过程中，重连后又立刻遇到跳号或协议错误的轮数超过上限（例如 3 轮）时，不再逐事件追赶，直接向宿主要持久化版本（或请求快照）。这与“持久化版本优先”一致：追不上就用权威版本整体替换。
- 收到 `seq ≤ 已应用 seq` 的事件：丢弃（重放与实时交界、代理重发都会造成重复）。
- 收到跳号：断开并按已应用 seq 重连，不缓存乱序事件。
- 连续失败超过上限（例如 5 分钟）或消息已从同步拿到最终版本：停止重连，以同步为准。
- **“已请求停止”的消息不自动重连**（见 4.4）：这个状态一直保持到收到 `message.end` 或持久化版本为止；上面的各种续传触发时机对它都不生效。

### 4.4 停止生成

**停止和断线是两回事**（[D39](decisions.md)，参考了 Vercel AI SDK 文档对“停止 ≠ 断开”的强调）：

| 发生了什么 | 算什么 | 服务端 | 客户端 |
|---|---|---|---|
| 用户按“停止生成” | 停止 | 收到 `POST …/messages/{id}/stop`：取消生成，持久化已产出的部分，发 `message.end{status: interrupted, error.code: cancelled}` | 进入“已请求停止”，按钮变成“正在停止…”；收到 `message.end` 后末尾标“已停止” |
| 关闭连接、切后台、离开页面、App 被杀、网络断开 | 断线 | 什么都不做，生成照常继续 | 按 4.3 在合适的时机续传 |

- **停止请求是幂等的**：重复发送返回同样的结果；消息已经结束时返回 `already_ended`，客户端直接以持久化版本为准。离线时停止按钮不可用（停止只有在服务端还在生成时才有意义，不进离线队列）。
- **停止后不自动重连这条消息**：如果停止请求发出后、`message.end` 到达前连接断了，客户端**不**重新订阅这条消息（否则会和停止竞争，或把刚停掉的内容“续”回来），而是等宿主同步下来的持久化版本；打开会话、回到前台时可以查一次持久化版本，但不重开流。
- **服务端清理要比对**：停止时只清除“这条消息仍是活动消息”的登记；如果登记已经指向更新的一条，不能误清（比对后再清，或在同一个条件写入里完成）。
- 停止请求和流式请求用同一套鉴权；谁能停止由宿主决定（例如只允许发起这一轮的用户；群聊里也可以允许管理员）。

### 4.5 找回正在生成的消息

发起生成的接口在生成开始前同步返回助手消息 ID（[protocol.md 4.6](protocol.md#46-生成控制开始停止找回)）。剩下的空窗是：用户消息已经提交，响应还没回来 App 就被杀了，客户端不知道该续传哪条消息。两条补救路径，都不需要会话级流（D20 不变）：

1. **重新提交同一条用户消息**：用户消息 ID 由客户端生成并已存在本地（[D43](decisions.md)），重发时服务端按幂等处理，返回同一个助手消息 ID（`replayed: true`），不会重复生成。
2. **查询活动消息**：`GET …/conversations/{id}/active-messages` 返回这个会话里正在生成的消息及其 `lastSeq`（没有就是空列表）。客户端打开会话、App 回到前台时，如果本地有“已提交、还没拿到助手消息 ID”的用户消息，就查一次，按 `replyTo` 对上，再从头订阅（`afterSeq = null`）。

## 5. 顺序、去重与合并规则

所有规则都在 `BlockStore.apply(event)` 这一个入口里执行（[architecture.md 3.4](architecture.md#34-客户端状态的几条硬规则)）：没有实际变化的事件（例如重复事件）不通知监听者、不替换对象。

| 情况 | 规则 |
|---|---|
| 事件顺序 | 只依赖 `seq`；不依赖到达时间或 `ts` |
| 重复事件 | `seq ≤ 已应用` 直接丢弃，天然幂等 |
| `block.start` 重复的 `blockId` | 视为协议错误：该消息进入“需要快照”状态，客户端重连并请求快照 |
| 对未开始的块发 `block.delta` / `data` | 同上 |
| `block.delta` 用于非 markdown 块 | 忽略该事件并记一次告警（v1 不支持） |
| `block.data` 发两次 | 第二次整体覆盖第一次（v1 生产方不应这样做） |
| `block.patch` | 对块的 `{data, fallbackText, metadata}` 做 JSON Merge Patch；带 `rev` 时按 `rev` 规则判断是否应用 |
| `message.end.blockCount` 与本地块数不符 | 本地缺块：请求快照或等同步结果替换 |
| 同步送来的持久化版本 | `rev ≥ 本地 rev` 时整体替换本地版本（包括本地生成中的临时状态）；**临时状态永远不会覆盖持久化版本** |
| `message.activity`（无 `seq`） | 不经过 seq 规则、不改变消息内容，只更新这条消息的“当前提示”；下一个带 `seq` 的事件、新提示或 `message.end` 到达时替换或清除。有步骤处于 `running` 时提示不显示（以步骤为准） |
| `step.started` | 在消息的 `steps` 末尾追加 `{id, label, state: running}`；不碰 `blocks`。重复的 `stepId` 视为协议错误（同重复的 `blockId`） |
| `step.finished` | 把对应步骤改成最终状态并写入 `durationMs`、`summary`、`blockId`；对未开始或已结束的步骤发 `step.finished` 视为协议错误 |
| 未声明 `stream.steps` 的客户端 | 步骤事件按未知事件类型处理：忽略内容、照常推进 `seq` |

## 6. 中断与不完整的块

| 场景 | 服务端行为 | 客户端显示 |
|---|---|---|
| 用户点“停止生成”（显式停止请求，见 4.4） | 停止生产；仍在运行的步骤各发一个 `step.finished{state: cancelled}`，再发 `message.end{status: interrupted, error.code: cancelled}`，持久化已产出的部分 | 已出现的内容保留（不清空、不回退），末尾标“已停止”；过程条里被停下的步骤显示“已停止”；断线**不**属于这种情况 |
| 某个步骤失败（工具出错、超时） | 发 `step.finished{state: failed, summary?}`，其他步骤和回答照常继续 | 过程条里只有这一行显示失败，不影响其他行和正文 |
| 上游模型失败 | 已有内容保留，`message.end{status: interrupted 或 error}`；全无内容时 `fallbackText` 说明原因 | 显示已有内容 + 一行错误说明，宿主可提供“重试” |
| 某个组件块的数据没拿到（工具失败、校验失败） | `block.end{status: error, fallbackText: "天气数据暂时无法获取"}`，消息继续 | 占位原地换成一行兜底文字，不移除块、不影响后续块 |
| 服务端进程崩溃 | 重启后扫描超过租约仍为 `streaming` 的消息：有持久日志时用同一个折叠函数把日志折叠成消息；默认的进程内缓冲时用最近的检查点（4.1）。仍在运行的步骤记为 `failed`，消息标 `interrupted` 并持久化 | 续传时拿到剩余事件或快照（默认实现下是快照） |
| 客户端离线 | — | 停在已收到的状态；未完成的 markdown 文本末尾不显示闪烁光标，改显示“连接中断”；联网后续传或从同步拿最终版本 |

**生成中的消息是“预览”，不是记录**：在拿到 `message.end` 或持久化版本之前，消息不显示复制、转发、引用等操作栏（避免复制到半截内容），也不参与搜索与通知；结束后才出现这些操作。

未完成的 markdown（例如 `**粗体` 还没闭合）按当前文本原样渲染，未闭合的标记暂时显示为普通字符，等后续文字到达后自然修正。渲染器不做猜测性的“补全标记”。

## 7. 布局稳定（避免界面跳动）

1. **块类型在 `block.start` 时就确定**，之后不变；不会出现“先显示一段文字，再被替换成一个组件”。
2. **占位预留大致高度**：按类型和 `placeholder{size, items}` 给出骨架高度（例如 3 个指标 → 一行指标卡的高度；3 行表格 → 表头 + 3 行）。数据到达后高度变化用尺寸过渡（遵守系统“减少动态效果”设置时直接跳变）。
3. **只重排变化的部分**：markdown 渲染把文本分成“已稳定段落”（最后一个不在代码块内的空行之前）和“活动尾部”，每批 delta 只重新解析尾部；已稳定段落的组件树复用。
4. **批量刷新**：每帧最多重建一次；同一帧内到达的多个 delta 合并（约 16–50ms 一批），避免逐 token 重建。
5. **滚动跟随**：用户停在列表底部时，新内容出现自动跟随；用户向上翻看时不跟随、画面不动，改为显示“有新内容”按钮。正在生成的消息变长**不算**“新消息”，不增加未读计数。
6. **过程条在消息顶部**：它在第一个块之上。生成中新步骤追加在过程条末尾，会把下方已出现的内容往下推；这和组件变高一样由锚点规则处理（第 8 条），用户正在看的内容不动。`message.end` 时过程条收起成一行，高度变化用尺寸过渡。
7. **读屏不刷屏**：不逐 token 播报；块结束或消息结束时播报一次（见 [rendering.md](rendering.md#6-无障碍)）。
8. **滚动由一个纯函数状态机决定**：`chatweave_core` 里的 `ViewportController` 是 `(视口状态, 事件, 测量结果) → 新视口状态` 的纯函数，阶段包括“打开中 / 定位中 / 稳定 / 用户滚动中 / 跟随最新”。锚点用“消息 ID + 块 ID + 像素偏移”表示，而不是绝对滚动位置，所以在上方插入历史消息或某个组件变高时，用户正在看的内容不会移动。`chatweave_flutter` 只负责测量和应用，**全库只有一个地方写滚动位置**；“有新内容”按钮、以及交给宿主的可见性回调（宿主可以据此做自己的已读逻辑）都从这个状态推导。这让最难测的滚动行为可以在纯 Dart 里做单元测试。

## 8. 背压与资源

- 慢订阅者：进程内广播通道满了就断开该订阅者，让它重连后从事件日志重放（日志里没有了就拿快照），不让一个慢客户端拖住生成过程。
- 进程内缓冲的内存：每条消息的事件数和字节数都有上限（与下面的事件总数上限一致），保留期满即释放。
- 合并 delta：服务端把模型 token 合并成小批（约 20 字或 50ms），减少事件数量和日志写入。
- 每条消息的事件总数上限（例如 5,000）与单事件大小上限（128 KB）由库检查，超限时结束消息（`limit_exceeded`）。
- 连接数：宿主应限制每个用户同时打开的流数量（例如 4）。
