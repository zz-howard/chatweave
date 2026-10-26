# 流式传输（草案 0.1）

> **状态：草案。** 事件定义见 [protocol.md 第 4 节](protocol.md#4-流式事件stream-events) 与 [`stream-event.schema.json`](../schemas/v0.1/stream-event.schema.json)。本文讲事件怎么在线上传、断了怎么续、客户端怎么合并，以及怎样避免界面跳动。

## 1. 目标与 v1 范围

- 文字**边生成边显示**，不等整条消息结束。
- 组件块在它该在的位置先出现占位，数据到达时整块填满；v1 不做组件字段级增量。
- 事件可以重复、可以断线，客户端最终状态与服务端持久化的消息一致；**断线 / 离线之后以持久化版本为准**。
- 普通 Markdown 回复不因为 UI 系统额外变慢：不额外调用模型，不额外往返。
- AI 回答前做的几件事（查数据、对比、交给子 Agent、等用户确认）作为**运行步骤**在同一条流里下发，显示在消息顶部的“过程”条里；它们和块事件一样可续传、可折叠，但与内容分开存放（[protocol.md 4.7](protocol.md#47-运行步骤stepstarted--stepfinished)）。
- 运行中途要用户确认或回答时，消息**暂停**，回答后**同一条消息**继续，`seq` 接着数；暂停可能持续很久，暂停中的消息不依赖事件日志（[protocol.md 4.8](protocol.md#48-中断暂停与继续同一条消息)）。

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

**变体：生成中停止。** 步骤 s3 还在运行时用户按停止：服务端先发 `step.finished{stepId: "s3", state: "cancelled"}`，再发 `message.end{status: "interrupted", error.code: "cancelled"}`。

运行中途要用户确认的情况见 2.6；子 Agent 的步骤见 2.7。

### 2.6 中断：暂停与继续

用户说“把交水费删了”。删除是不可恢复的操作，宿主的 Agent 发起删除的工具调用被系统拦下，要用户先确认（[protocol.md 4.8](protocol.md#48-中断暂停与继续同一条消息) 的情况 (a)）。运行**没有结束**：消息暂停，用户确认后**同一条消息**继续，`seq` 接着数：

```json
{"protocolVersion":"0.1","type":"message.start","messageId":"msg_03","seq":1,"message":{"id":"msg_03","role":"assistant","conversationId":"conv_42","createdAt":"2026-10-26T09:50:00Z"}}
{…,"type":"step.started","seq":2,"stepId":"s1","label":"删除待办“交水费”"}
{…,"type":"block.start","seq":3,"blockId":"b1","index":0,"blockType":"confirmation","schemaVersion":1}
{…,"type":"block.data","seq":4,"blockId":"b1","data":{"title":"删除待办“交水费”？","body":"删除后无法恢复。","severity":"destructive","details":[{"label":"截止","value":"2026-10-28"}],"confirmLabel":"删除","cancelLabel":"保留","action":{"type":"confirmation.respond","target":"todo.delete","requiresConfirmation":true,"expiresAt":"2026-10-27T09:50:00Z"},"state":{"status":"open"}},"fallbackText":"删除待办“交水费”？删除后无法恢复。"}
{…,"type":"block.end","seq":5,"blockId":"b1","status":"complete"}
{…,"type":"message.paused","seq":6,"interrupt":{"id":"int_01","stepId":"s1","blockId":"b1","reason":"confirmation"},"fallbackText":"删除待办“交水费”？删除后无法恢复。","blockCount":1}
{…,"type":"block.patch","seq":7,"blockId":"b1","patch":{"data":{"state":{"status":"resolved","outcome":"confirm","resolvedAt":"2026-10-26T09:52:10Z"}}}}
{…,"type":"message.resumed","seq":8,"interruptId":"int_01"}
{…,"type":"step.finished","seq":9,"stepId":"s1","state":"succeeded","durationMs":700,"summary":"已删除"}
{…,"type":"block.start","seq":10,"blockId":"b2","index":1,"blockType":"markdown","schemaVersion":1}
{…,"type":"block.delta","seq":11,"blockId":"b2","delta":{"text":"好的，“交水费”已经删掉了。"}}
{…,"type":"block.end","seq":12,"blockId":"b2","status":"complete"}
{…,"type":"message.end","seq":13,"status":"complete","blockCount":2,"rev":1,"fallbackText":"删除待办“交水费”？删除后无法恢复。好的，“交水费”已经删掉了。"}
```

seq 6 之后服务端关闭这条流。这时持久化的暂停检查点（`fold` 到 seq 6 的结果）是：

```json
{"id":"msg_03","protocolVersion":"0.1","conversationId":"conv_42","role":"assistant","status":"paused","rev":0,"lastSeq":6,"createdAt":"2026-10-26T09:50:00Z","fallbackText":"删除待办“交水费”？删除后无法恢复。","interrupt":{"id":"int_01","stepId":"s1","blockId":"b1","reason":"confirmation"},"blocks":[{"id":"b1","type":"confirmation","schemaVersion":1,"data":{"title":"删除待办“交水费”？","body":"删除后无法恢复。","severity":"destructive","details":[{"label":"截止","value":"2026-10-28"}],"confirmLabel":"删除","cancelLabel":"保留","action":{"type":"confirmation.respond","target":"todo.delete","requiresConfirmation":true,"expiresAt":"2026-10-27T09:50:00Z"},"state":{"status":"open"}},"fallbackText":"删除待办“交水费”？删除后无法恢复。"}],"steps":[{"id":"s1","label":"删除待办“交水费”","state":"awaiting_user","blockId":"b1"}]}
```

用户点“删除”：客户端发 `confirmation.respond {outcome: "confirm"}`（动作 ID 是幂等键），卡片只显示“提交中”。服务端在同一个事务里确认中断仍开着、记录答案、把“已确认”交给 Agent 运行时，返回 `{status: "accepted", resume: {messageId: "msg_03"}}`。客户端带 `Last-Event-ID: 6` 重新订阅，收到 seq 7 起的事件：卡片变成“已确认”，过程条那一行从“等你确认”变回运行中，删除完成后显示“✓ 0.7 秒 · 已删除”（耗时不含等用户的时间），然后是收尾文字。最终持久化的消息里，这一步是：

```json
{"steps":[{"id":"s1","label":"删除待办“交水费”","state":"succeeded","durationMs":700,"summary":"已删除","blockId":"b1"}]}
```

用户的回答**不是**一条新的用户消息：它记在确认卡的 `state` 里（`outcome: confirm`），显示在卡片上；对话里没有多出一条“删除”。

**变体：继续之后断线。** 客户端在 seq 9 之后断网：恢复后按 4.3 带 `Last-Event-ID: 9` 续传，和没有暂停过的消息一样；日志里没有了（例如服务端重启）就给快照。

**变体：暂停很久之后在另一台设备上回答。** 用户第二天在另一台手机上打开会话：活动消息列表里有 `{messageId: "msg_03", status: "paused", lastSeq: 6}`，客户端订阅这条消息；事件日志早已过期，服务端发暂停检查点的快照（`seq: 6`）后关闭。用户回答后照常继续，收到 seq 7 起的事件。第一台手机下次打开会话时同样从活动消息列表或同步下来的最终版本拿到结果。

**变体：暂停中停止。** 用户没有回答，按了“停止”（或在输入框里发了别的内容，而这张卡不接受文字回答）：

```json
{…,"type":"block.patch","seq":7,"blockId":"b1","patch":{"data":{"state":{"status":"cancelled","reason":{"code":"stopped"}}}}}
{…,"type":"step.finished","seq":8,"stepId":"s1","state":"cancelled","durationMs":300}
{…,"type":"message.end","seq":9,"status":"interrupted","blockCount":1,"rev":1,"fallbackText":"删除待办“交水费”？删除后无法恢复。","error":{"code":"cancelled","message":"已停止"}}
```

**变体：中断过期。** 到了 `expiresAt` 仍没有回答：块 → `expired`，步骤 → `cancelled`，`message.end{status: interrupted, error.code: interrupt_expired}`。顺序与停止相同。

**变体：子 Agent 里发起的中断。** 中断的步骤是某个委派步骤的子步骤时（2.7），整条消息照样暂停：子步骤 `awaiting_user`，它上面的委派步骤保持 `running`（过程条上显示“等你确认”）；继续之后子步骤、委派步骤依次结束。

### 2.7 子 Agent 的步骤（嵌套）

用户问“北京和上海这周哪边更适合出门？再看看我的待办”。主 Agent 把“对比两城天气”交给一个天气子 Agent（委派步骤 `kind: "delegate"`），子 Agent 并行查两个城市（子步骤带 `parentStepId`），主 Agent 自己读待办，然后回答（[protocol.md 4.7](protocol.md#47-运行步骤stepstarted--stepfinished) 第 4 条）：

```json
{"protocolVersion":"0.1","type":"message.start","messageId":"msg_04","seq":1,"message":{"id":"msg_04","role":"assistant","conversationId":"conv_42","createdAt":"2026-10-26T10:00:00Z"}}
{…,"type":"step.started","seq":2,"stepId":"s1","label":"交给天气助手对比两城天气","kind":"delegate"}
{…,"type":"step.started","seq":3,"stepId":"s2","label":"查北京本周天气","parentStepId":"s1"}
{…,"type":"step.started","seq":4,"stepId":"s3","label":"查上海本周天气","parentStepId":"s1"}
{…,"type":"step.finished","seq":5,"stepId":"s2","state":"succeeded","durationMs":800}
{…,"type":"step.finished","seq":6,"stepId":"s3","state":"succeeded","durationMs":900}
{…,"type":"step.finished","seq":7,"stepId":"s1","state":"succeeded","durationMs":2100,"summary":"北京更干燥"}
{…,"type":"step.started","seq":8,"stepId":"s4","label":"读取本周待办"}
{…,"type":"step.finished","seq":9,"stepId":"s4","state":"succeeded","durationMs":300,"summary":"找到 3 件"}
{…,"type":"block.start","seq":10,"blockId":"b1","index":0,"blockType":"markdown","schemaVersion":1}
{…,"type":"block.delta","seq":11,"blockId":"b1","delta":{"text":"北京这周比上海干燥，更适合出门。你这周还有 3 件待办，最近的是周三交水费。"}}
{…,"type":"block.end","seq":12,"blockId":"b1","status":"complete"}
{…,"type":"message.end","seq":13,"status":"complete","blockCount":1,"rev":1,"fallbackText":"北京这周比上海干燥，更适合出门。你这周还有 3 件待办，最近的是周三交水费。"}
```

折叠后的步骤（平铺保存，层级由 `parentStepId` 表达，顺序 = `step.started` 的顺序）：

```json
{"steps":[{"id":"s1","label":"交给天气助手对比两城天气","kind":"delegate","state":"succeeded","durationMs":2100,"summary":"北京更干燥"},{"id":"s2","label":"查北京本周天气","parentStepId":"s1","state":"succeeded","durationMs":800},{"id":"s3","label":"查上海本周天气","parentStepId":"s1","state":"succeeded","durationMs":900},{"id":"s4","label":"读取本周待办","state":"succeeded","durationMs":300,"summary":"找到 3 件"}]}
```

界面上：委派步骤一行“交给天气助手对比两城天气”，它的子步骤默认收起（行尾显示“2 步”，点按展开）；子 Agent 运行时这一行显示运行中。结束后过程条收起成“查了 2 项 · 用时 3 秒”（只数主 Agent 这一层）。

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
| 消息暂停中 | `200`，重放 `seq > N` 的事件（日志没有了就发暂停中的快照），以 `message.paused` 或快照结束，然后关闭 |

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
- `message.end`、`message.paused` 或流级 `error` 之后服务端关闭连接。暂停后的关闭不是断线，客户端不重连（4.3）。

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

使用默认实现时，宿主在每个 `block.end`、且至少每隔几秒（例如 5 秒），把折叠后的临时消息（`status = streaming`、`rev = 0`）和最后的 `seq` 写入消息存储作为**检查点**。这样崩溃不会丢掉整条消息，也避免“只在生成结束时才落库”。**`message.paused` 时必须写检查点**（`status = paused`、`lastSeq`），不论用哪种日志实现：它是暂停中的消息的权威状态。

两种实现的共同规则：

- 生成过程中每个事件**先追加到日志再广播**给在线订阅者（进程内广播通道）。
- 续传请求带 `Last-Event-ID = N`：服务端先从日志重放 `seq > N` 的事件，再接上实时广播；重放与实时之间按 `seq` 去重，保证不漏不重。
- 保留期（**已定，[D21](decisions.md)**）：默认保留到 `message.end` 之后 **10 分钟**（宿主可配置）；过期后清理。暂停中的消息从 `message.paused` 起算同样的保留期（[D54](decisions.md)）：过期后订阅拿暂停检查点的快照，继续之后的新事件照常写日志、照常保留。暂停检查点本身不过期，继续不依赖日志。10 分钟覆盖了常见的短暂断线、切后台和弱网重连；更久之后客户端走快照或宿主同步，不再需要逐事件重放。日志里有内容，访问它与访问消息本身用同一套权限检查，保留期结束必须删除。存放位置：默认在进程内存里（见上表）；宿主可以换成数据库表等持久实现。

### 4.2 无法重放时：快照

如果 `N` 早于日志里最早的事件、日志已清理、或宿主根本不保留日志，服务端发送 `message.snapshot`：

- 内容是此刻的完整消息（生成中则 `status = streaming`、`rev = 0`；暂停中则 `status = paused`、带 `interrupt` 和 `lastSeq`），包括运行步骤 `steps`（生成中可能有 `running` 的步骤，之后照常接收它们的 `step.finished`；暂停中有一个 `awaiting_user` 的步骤）。
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
 [接收中] ──收到 message.paused（或暂停中的快照）──▶ [已暂停] ── 流已关闭，不自动重连
                                      │ 动作结果带 resume（本设备回答）、活动消息列表显示它又在生成、
                                      │ 或同步来的检查点 lastSeq 更大
                                      └──▶ [连接中]（Last-Event-ID = 已应用 seq）
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
- **“已暂停”的消息不自动重连**（[protocol.md 4.8](protocol.md#48-中断暂停与继续同一条消息)）：流是服务端正常关闭的，没有东西可等。只有三种情况重新订阅：这台设备回答了中断（动作结果带 `resume`）；打开会话、回到前台时查活动消息列表，发现它已经不是 `paused`（例如在另一台设备上回答了）；同步下来的检查点 `lastSeq` 比本地大。查到消息已经结束时直接用持久化版本。
- **同步下来的检查点**（`rev = 0`，生成中或暂停中）只有在 `lastSeq ≥ 已应用 seq` 时才替换本地状态，不会让本地状态倒退；`rev ≥ 1` 的持久化版本照旧总是替换。

### 4.4 停止生成

**停止和断线是两回事**（[D39](decisions.md)，参考了 Vercel AI SDK 文档对“停止 ≠ 断开”的强调）：

| 发生了什么 | 算什么 | 服务端 | 客户端 |
|---|---|---|---|
| 用户按“停止生成” | 停止 | 收到 `POST …/messages/{id}/stop`：取消生成，持久化已产出的部分，发 `message.end{status: interrupted, error.code: cancelled}` | 进入“已请求停止”，按钮变成“正在停止…”；收到 `message.end` 后末尾标“已停止” |
| 关闭连接、切后台、离开页面、App 被杀、网络断开 | 断线 | 什么都不做，生成照常继续 | 按 4.3 在合适的时机续传 |

- **停止请求是幂等的**：重复发送返回同样的结果；消息已经结束时返回 `already_ended`，客户端直接以持久化版本为准。
- **暂停中也能停止**：这时没有打开的流，服务端关闭中断（块 `cancelled` + `reason.code: stopped`，等待的步骤 `cancelled`）并结束消息（`interrupted` + `cancelled`），客户端从持久化版本或下一次订阅拿到结果（[protocol.md 4.8](protocol.md#48-中断暂停与继续同一条消息) 第 15 条）。离线时停止按钮不可用（停止只有在服务端还在生成时才有意义，不进离线队列）。
- **停止后不自动重连这条消息**：如果停止请求发出后、`message.end` 到达前连接断了，客户端**不**重新订阅这条消息（否则会和停止竞争，或把刚停掉的内容“续”回来），而是等宿主同步下来的持久化版本；打开会话、回到前台时可以查一次持久化版本，但不重开流。
- **服务端清理要比对**：停止时只清除“这条消息仍是活动消息”的登记；如果登记已经指向更新的一条，不能误清（比对后再清，或在同一个条件写入里完成）。
- 停止请求和流式请求用同一套鉴权；谁能停止由宿主决定（例如只允许发起这一轮的用户；群聊里也可以允许管理员）。

### 4.5 找回正在生成的消息

发起生成的接口在生成开始前同步返回助手消息 ID（[protocol.md 4.6](protocol.md#46-生成控制开始停止找回)）。剩下的空窗是：用户消息已经提交，响应还没回来 App 就被杀了，客户端不知道该续传哪条消息。两条补救路径，都不需要会话级流（D20 不变）：

1. **重新提交同一条用户消息**：用户消息 ID 由客户端生成并已存在本地（[D43](decisions.md)），重发时服务端按幂等处理，返回同一个助手消息 ID（`replayed: true`），不会重复生成。
2. **查询活动消息**：`GET …/conversations/{id}/active-messages` 返回这个会话里还没结束的消息及其 `lastSeq`（没有就是空列表）；暂停中的消息带 `status: "paused"`，客户端据此显示问题，不订阅它（回答后再订阅）。客户端打开会话、App 回到前台时，如果本地有“已提交、还没拿到助手消息 ID”的用户消息，就查一次，按 `replyTo` 对上，再从头订阅（`afterSeq = null`）。

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
| `step.started` | 在消息的 `steps` 末尾追加 `{id, label, kind?, parentStepId?, state: running}`；不碰 `blocks`。重复的 `stepId` 视为协议错误（同重复的 `blockId`）；`parentStepId` 指向不存在、不是 `delegate`、已经结束的步骤，或嵌套超过 3 层，同样是协议错误 |
| `step.finished` | 把对应步骤改成最终状态并写入 `durationMs`、`summary`；对未开始或已结束的步骤发 `step.finished`、委派步骤还有没结束的子步骤时结束它，视为协议错误 |
| `message.paused` | 消息 `status → paused`，写入 `interrupt`；`interrupt.stepId` 那一步 → `awaiting_user` 并写入 `blockId`。前提不满足（还有块没结束、中断的块不是 `open` 的交互块、有别的步骤在运行）视为协议错误。之后不再等事件，不重连 |
| 暂停中的事件 | 只允许：中断块的 `block.patch`（不带 `rev`），然后 `message.resumed`（块已是 `resolved`）；或者等待的步骤及其上级的 `step.finished{cancelled}` 和 `message.end{interrupted}`（块已是 `cancelled` / `expired`）。其他事件视为协议错误 |
| `message.resumed` | 消息 `status → streaming`，去掉 `interrupt`；`awaiting_user` 的那一步回到 `running`（`blockId` 保留）。必须紧跟在把中断块写成 `resolved` 的 `block.patch` 之后，`interruptId` 必须与暂停时的一致 |
| 未声明 `stream.steps` 的客户端 | 步骤事件按未知事件类型处理：忽略内容、照常推进 `seq` |

## 6. 中断与不完整的块

| 场景 | 服务端行为 | 客户端显示 |
|---|---|---|
| 用户点“停止生成”（显式停止请求，见 4.4） | 停止生产；仍在运行的步骤各发一个 `step.finished{state: cancelled}`，再发 `message.end{status: interrupted, error.code: cancelled}`，持久化已产出的部分 | 已出现的内容保留（不清空、不回退），末尾标“已停止”；过程条里被停下的步骤显示“已停止”；断线**不**属于这种情况 |
| 某个步骤失败（工具出错、超时） | 发 `step.finished{state: failed, summary?}`，其他步骤和回答照常继续 | 过程条里只有这一行显示失败，不影响其他行和正文 |
| 运行中途要用户确认 / 回答（中断） | 发交互块，`message.paused`，写暂停检查点，关闭流；回答后同一条消息继续 | 已出现的内容保留；过程条那一行“等你确认”，交互块可操作；不显示“连接中断”和生成中的光标、临时提示；停止按钮仍可用 |
| 暂停中停止、发新消息或中断过期 | 块 → `cancelled`（`stopped`）或 `expired`，等待的步骤 → `cancelled`，`message.end{interrupted}`（`cancelled` / `interrupt_expired`） | 卡片显示“已停止”或“已过期”，过程条那一行“已停止”，消息末尾标“已停止”或“确认已过期” |
| 上游模型失败 | 已有内容保留，`message.end{status: interrupted 或 error}`；全无内容时 `fallbackText` 说明原因 | 显示已有内容 + 一行错误说明，宿主可提供“重试” |
| 某个组件块的数据没拿到（工具失败、校验失败） | `block.end{status: error, fallbackText: "天气数据暂时无法获取"}`，消息继续 | 占位原地换成一行兜底文字，不移除块、不影响后续块 |
| 服务端进程崩溃 | 暂停中的消息不受影响（检查点是权威状态）。重启后扫描超过租约仍为 `streaming` 的消息：有持久日志时用同一个折叠函数把日志折叠成消息；默认的进程内缓冲时用最近的检查点（4.1）。仍在运行的步骤记为 `failed`，消息标 `interrupted` 并持久化 | 续传时拿到剩余事件或快照（默认实现下是快照） |
| 客户端离线 | — | 停在已收到的状态；未完成的 markdown 文本末尾不显示闪烁光标，改显示“连接中断”；联网后续传或从同步拿最终版本 |

**生成中的消息是“预览”，不是记录**：在拿到 `message.end` 或持久化版本之前，消息不显示复制、转发、引用等操作栏（避免复制到半截内容），也不参与搜索与通知；结束后才出现这些操作。

未完成的 markdown（例如 `**粗体` 还没闭合）按当前文本原样渲染，未闭合的标记暂时显示为普通字符，等后续文字到达后自然修正。渲染器不做猜测性的“补全标记”。

## 7. 布局稳定（避免界面跳动）

1. **块类型在 `block.start` 时就确定**，之后不变；不会出现“先显示一段文字，再被替换成一个组件”。
2. **占位预留大致高度**：按类型和 `placeholder{size, items}` 给出骨架高度（例如 3 个指标 → 一行指标卡的高度；3 行表格 → 表头 + 3 行）。数据到达后高度变化用尺寸过渡（遵守系统“减少动态效果”设置时直接跳变）。
3. **只重排变化的部分**：markdown 渲染把文本分成“已稳定段落”（最后一个不在代码块内的空行之前）和“活动尾部”，每批 delta 只重新解析尾部；已稳定段落的组件树复用。
4. **批量刷新**：每帧最多重建一次；同一帧内到达的多个 delta 合并（约 16–50ms 一批），避免逐 token 重建。
5. **滚动跟随**：用户停在列表底部时，新内容出现自动跟随；用户向上翻看时不跟随、画面不动，改为显示“有新内容”按钮。正在生成的消息变长**不算**“新消息”，不增加未读计数。
6. **过程条在消息顶部**：它在第一个块之上。生成中新步骤追加在过程条末尾（子 Agent 的步骤默认收起在委派步骤那一行里，不占高度），会把下方已出现的内容往下推；这和组件变高一样由锚点规则处理（第 8 条），用户正在看的内容不动。`message.end` 时过程条收起成一行，高度变化用尺寸过渡。
7. **读屏不刷屏**：不逐 token 播报；块结束或消息结束时播报一次（见 [rendering.md](rendering.md#6-无障碍)）。
8. **滚动由一个纯函数状态机决定**：`chatweave_core` 里的 `ViewportController` 是 `(视口状态, 事件, 测量结果) → 新视口状态` 的纯函数，阶段包括“打开中 / 定位中 / 稳定 / 用户滚动中 / 跟随最新”。锚点用“消息 ID + 块 ID + 像素偏移”表示，而不是绝对滚动位置，所以在上方插入历史消息或某个组件变高时，用户正在看的内容不会移动。`chatweave_flutter` 只负责测量和应用，**全库只有一个地方写滚动位置**；“有新内容”按钮、以及交给宿主的可见性回调（宿主可以据此做自己的已读逻辑）都从这个状态推导。这让最难测的滚动行为可以在纯 Dart 里做单元测试。

## 8. 背压与资源

- 慢订阅者：进程内广播通道满了就断开该订阅者，让它重连后从事件日志重放（日志里没有了就拿快照），不让一个慢客户端拖住生成过程。
- 进程内缓冲的内存：每条消息的事件数和字节数都有上限（与下面的事件总数上限一致），保留期满即释放。
- 合并 delta：服务端把模型 token 合并成小批（约 20 字或 50ms），减少事件数量和日志写入。
- 每条消息的事件总数上限（例如 5,000）与单事件大小上限（128 KB）由库检查，超限时结束消息（`limit_exceeded`）。
- 连接数：宿主应限制每个用户同时打开的流数量（例如 4）。
