# 流式传输（草案 0.1）

> **状态：草案。** 事件定义见 [protocol.md 第 4 节](protocol.md#4-流式事件stream-events) 与 [`stream-event.schema.json`](../schemas/v0.1/stream-event.schema.json)。本文讲事件怎么在线上传、断了怎么续、客户端怎么合并，以及怎样避免界面跳动。

## 1. 目标与 v1 范围

- 文字**边生成边显示**，不等整条消息结束。
- 组件块在它该在的位置先出现占位，数据到达时整块填满；v1 不做组件字段级增量。
- 事件可以重复、可以断线，客户端最终状态与服务端持久化的消息一致；**断线 / 离线之后以持久化版本为准**。
- 普通 Markdown 回复不因为 UI 系统额外变慢：不额外调用模型，不额外往返。

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
| 正常 | `200`，`Content-Type: text/event-stream`，`Cache-Control: no-store`，并关闭代理缓冲（如 `X-Accel-Buffering: no`） |
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
- 开头的 `retry: 2000` 建议客户端断线后 2 秒重连（客户端仍应做指数退避，上限例如 30 秒）。
- 每 15 秒发一行注释 `: ping` 作心跳，防止代理或运营商网关切断空闲连接；客户端超过 45 秒没收到任何字节就主动重连。
- `message.end` 或流级 `error` 之后服务端关闭连接。

### 3.3 为什么按“每条消息一条流”

**已定（[D7](decisions.md)、[D20](decisions.md)）：每条消息一条流，不按会话合并。** 一条助手消息对应一条流，`seq` 在消息内从 1 计数。好处：续传语义最简单（一个整数）；多台设备可以同时订阅同一条消息；一次请求里只有一个生成过程。代价：一个会话里同时生成多条消息时要开多条连接——v1 的聊天场景同一时刻通常只生成一条，宿主可以用每用户的流数量上限（第 8 节）兜住。只有当“一次请求产生多条助手消息”或“会话内并发生成”成为真实需求时才重新评估。

## 4. 断线续传

### 4.1 服务端：事件日志

库定义 `EventLog` 接口（宿主实现，例如一张 PostgreSQL 表 `(message_id, seq, event_json, created_at)`）：

- 生成过程中每个事件**先追加到日志再广播**给在线订阅者（进程内广播通道）。
- 续传请求带 `Last-Event-ID = N`：服务端先从日志重放 `seq > N` 的事件，再接上实时广播；重放与实时之间按 `seq` 去重，保证不漏不重。
- 保留期（**已定，[D21](decisions.md)**）：默认保留到 `message.end` 之后 **10 分钟**（宿主可配置）；过期后清理。10 分钟覆盖了常见的短暂断线、切后台和弱网重连；更久之后客户端走快照或宿主同步，不再需要逐事件重放。日志里有内容，访问它与访问消息本身用同一套权限检查，保留期结束必须删除。存放位置由宿主决定（例如数据库表）；只放内存、进程重启后只给快照的轻量做法也是合规的（见 [mvp-plan.md R8](mvp-plan.md#2-风险较高的部分与替代方案)）。

### 4.2 无法重放时：快照

如果 `N` 早于日志里最早的事件、日志已清理、或宿主根本不保留日志，服务端发送 `message.snapshot`：

- 内容是此刻的完整消息（生成中则 `status = streaming`、`rev = 0`）。
- 它的 `seq` 等于快照所反映的最后一个事件的 `seq`。消费方在 `snapshot.seq ≥ 已应用 seq` 时用它**整体替换**本地状态，并把已应用 seq 设为 `snapshot.seq`，之后照常接收后续事件。
- 宿主因此需要随消息保存“最后一个 seq”。

客户端未声明 `stream.snapshot` 能力时，服务端改为返回流级 `error{code: "resume_unavailable"}` 并关闭；客户端随后通过宿主的同步机制取持久化版本。

### 4.3 客户端：续传状态机

```
          ┌──────────── 收到 message.end ───────────┐
          ▼                                          │
 [空闲] ─订阅─▶ [连接中] ─200─▶ [接收中] ──事件──▶ 应用（seq 去重）
                  ▲               │
                  │      断线 / 心跳超时 / 跳号
                  └─退避重连(Last-Event-ID = 已应用 seq)─┘
 宿主同步送来同一消息且 rev ≥ 1 ──▶ 用持久化版本替换，停止订阅
```

- 已应用的 `seq` 和临时消息状态由宿主的存储接口持久化（例如每 1 秒或每个 `block.end` 节流写一次），**App 被杀后重启也能续传**。
- **续传触发时机**：除了连接断开 / 心跳超时 / 跳号，以下时刻也要检查所有未完成（`status = streaming` 且没有持久化版本）的消息并按需续传：打开会话、切回会话、网络恢复、App 回到前台。移动端系统常在后台静默切断连接，回到前台时主动检查比等心跳超时快得多。
- **同一条消息同时只有一个续传**（单飞）：多个触发同时发生时合并成一次，不并发开多条连接。
- **有上限**：一次续传过程中，重连后又立刻遇到跳号或协议错误的轮数超过上限（例如 3 轮）时，不再逐事件追赶，直接向宿主要持久化版本（或请求快照）。这与“持久化版本优先”一致：追不上就用权威版本整体替换。
- 收到 `seq ≤ 已应用 seq` 的事件：丢弃（重放与实时交界、代理重发都会造成重复）。
- 收到跳号：断开并按已应用 seq 重连，不缓存乱序事件。
- 连续失败超过上限（例如 5 分钟）或消息已从同步拿到最终版本：停止重连，以同步为准。

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

## 6. 中断与不完整的块

| 场景 | 服务端行为 | 客户端显示 |
|---|---|---|
| 用户点“停止生成” | 停止生产，发 `message.end{status: interrupted, error.code: cancelled}`，持久化已产出的部分 | 已出现的内容保留（不清空、不回退），末尾标“已停止” |
| 上游模型失败 | 已有内容保留，`message.end{status: interrupted 或 error}`；全无内容时 `fallbackText` 说明原因 | 显示已有内容 + 一行错误说明，宿主可提供“重试” |
| 某个组件块的数据没拿到（工具失败、校验失败） | `block.end{status: error, fallbackText: "天气数据暂时无法获取"}`，消息继续 | 占位原地换成一行兜底文字，不移除块、不影响后续块 |
| 服务端进程崩溃 | 重启后扫描超过租约仍为 `streaming` 的消息：用同一个折叠函数把事件日志折叠成消息，标 `interrupted`，追加 `message.end` 并持久化 | 续传时拿到剩余事件或快照 |
| 客户端离线 | — | 停在已收到的状态；未完成的 markdown 文本末尾不显示闪烁光标，改显示“连接中断”；联网后续传或从同步拿最终版本 |

**生成中的消息是“预览”，不是记录**：在拿到 `message.end` 或持久化版本之前，消息不显示复制、转发、引用等操作栏（避免复制到半截内容），也不参与搜索与通知；结束后才出现这些操作。

未完成的 markdown（例如 `**粗体` 还没闭合）按当前文本原样渲染，未闭合的标记暂时显示为普通字符，等后续文字到达后自然修正。渲染器不做猜测性的“补全标记”。

## 7. 布局稳定（避免界面跳动）

1. **块类型在 `block.start` 时就确定**，之后不变；不会出现“先显示一段文字，再被替换成一个组件”。
2. **占位预留大致高度**：按类型和 `placeholder{size, items}` 给出骨架高度（例如 3 个指标 → 一行指标卡的高度；3 行表格 → 表头 + 3 行）。数据到达后高度变化用尺寸过渡（遵守系统“减少动态效果”设置时直接跳变）。
3. **只重排变化的部分**：markdown 渲染把文本分成“已稳定段落”（最后一个不在代码块内的空行之前）和“活动尾部”，每批 delta 只重新解析尾部；已稳定段落的组件树复用。
4. **批量刷新**：每帧最多重建一次；同一帧内到达的多个 delta 合并（约 16–50ms 一批），避免逐 token 重建。
5. **滚动跟随**：用户停在列表底部时，新内容出现自动跟随；用户向上翻看时不跟随、画面不动，改为显示“有新内容”按钮。正在生成的消息变长**不算**“新消息”，不增加未读计数。
6. **读屏不刷屏**：不逐 token 播报；块结束或消息结束时播报一次（见 [rendering.md](rendering.md#6-无障碍)）。
7. **滚动由一个纯函数状态机决定**：`chatweave_core` 里的 `ViewportController` 是 `(视口状态, 事件, 测量结果) → 新视口状态` 的纯函数，阶段包括“打开中 / 定位中 / 稳定 / 用户滚动中 / 跟随最新”。锚点用“消息 ID + 块 ID + 像素偏移”表示，而不是绝对滚动位置，所以在上方插入历史消息或某个组件变高时，用户正在看的内容不会移动。`chatweave_flutter` 只负责测量和应用，**全库只有一个地方写滚动位置**；“有新内容”按钮、以及交给宿主的可见性回调（宿主可以据此做自己的已读逻辑）都从这个状态推导。这让最难测的滚动行为可以在纯 Dart 里做单元测试。

## 8. 背压与资源

- 慢订阅者：进程内广播通道满了就断开该订阅者，让它重连后从事件日志重放，不让一个慢客户端拖住生成过程。
- 合并 delta：服务端把模型 token 合并成小批（约 20 字或 50ms），减少事件数量和日志写入。
- 每条消息的事件总数上限（例如 5,000）与单事件大小上限（128 KB）由库检查，超限时结束消息（`limit_exceeded`）。
- 连接数：宿主应限制每个用户同时打开的流数量（例如 4）。
