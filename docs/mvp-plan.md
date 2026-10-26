# MVP 实施计划（草案）

> **状态：草案。** 对应 [architecture.md](architecture.md#7-分期) 的 Phase 1。每个任务都能独立实现、独立测试；验收标准写成机器能检查的形式为主。

## 0. 端到端验收场景（MVP 完成的标志）

在示例 App（天气 + 待办助手）中，用脚本化的假 Agent 产生一条消息：**运行步骤（查天气、读待办）+ 文字 + 天气指标组 + 待办表格 + 简单气温折线图 + 收尾文字**，并验证：

1. 文字逐步出现，组件先占位后整块填满，组件出现时上方已渲染的文字位置不跳动。
2. 在第 N 个事件时切断网络，恢复后自动续传，最终界面与一次性收完完全一致（golden 相同）。
3. 事件日志被清空后续传，收到快照，结果仍一致。
4. 把客户端注册表换成 Markdown-only，消息仍完整可读。
5. 点一个选项块的选项：点按后只显示“提交中”，服务端校验并更新块状态后才显示结果；另一台模拟设备同步后看到同一个“已回答”；重复提交同一动作只执行一次。两台设备几乎同时选了不同选项（一对一：同一用户的两台设备；群聊：两位成员）：只有一个被记录，后到的一方显示服务端记录的那个答案（群聊里含回答者），而不是自己点的。服务端作废一张确认卡时显示“已作废”和原因，与用户自己点“取消”的显示不同。
6. 删除待办需要破坏性确认块；直接伪造一个指向删除处理器的 `choice.select` 请求被拒绝。
7. 不提供 `ActionTransport` 时，交互块以只读方式显示，点按不会发出任何消息或请求。
8. 生成中按“停止”：消息以“已停止”结束，已出现的内容保留；在停止请求之后、`message.end` 之前切断网络，恢复后客户端**不**重新订阅这条消息，而是拿到持久化版本。只切后台或断网（没按停止）时生成继续，恢复后续传。
9. 提交用户消息后、收到助手消息 ID 之前杀掉 App：重启后通过“重新提交同一个用户消息 ID”或“查询活动消息”接回同一条助手消息，不产生第二次生成；假 Agent 发出的临时进度提示能显示，但不出现在最终消息里。重启服务端后续传得到快照，结果仍一致。
10. 运行过程条：生成中过程条在正文之上展开、逐行显示步骤（运行中 / 完成 + 耗时）；其中一步失败时只有这一行显示“没有完成”，其他步骤和回答照常；`message.end` 后自动收起成一行摘要，点按可展开，从历史打开时默认收起。主 Agent 把天气对比交给子 Agent 时，委派步骤一行、子步骤默认收起，点按展开后缩进显示。某一步运行中按停止：这一步显示“已停止”，消息以“已停止”结束。某一步运行中断网，恢复后续传，过程条和最终消息与一次性收完一致；服务端重启后拿到的快照里也有步骤。把客户端换成不声明 `stream.steps` 的版本：步骤事件被忽略、`seq` 照常推进，正文完全一致，只显示临时提示。最终消息的 `fallbackText` 与复制内容里没有过程条。
11. 中断（暂停与继续）：删除待办时运行暂停，确认卡在正文里、过程条那一行“等你确认”，流被服务端关闭且客户端不重连；点“删除”后只显示“提交中”，随后**同一条消息**继续（`seq` 接着数）：卡片显示“已确认”，那一行变成完成并附“你已确认”，收尾文字接在同一条消息下面，对话里没有多出用户气泡。选项块的文字回答从输入框发出时同样只出现在卡片上。暂停后杀掉 App、等事件日志过期，再在另一台模拟设备上打开：从活动消息列表看到暂停中的消息、拿到暂停检查点的快照，回答后继续，两台设备最终一致。继续之后断网，恢复后续传结果与一次性收完一致。暂停中按停止：卡片“已停止，没有等到回答”，那一行“已停止”，消息以“已停止”结束；暂停中直接发新消息（卡片不接受文字回答）效果相同，然后开始新的一轮。中断过期：卡片“已过期”，消息以“确认已过期”结束。同一个回答重复提交只继续一次；两台设备几乎同时回答，后到的一方显示先记录的答案。子 Agent 里发起的中断让整条消息暂停，委派步骤那一行显示“等你确认”。最终回答里附带的问题（例如“要我设个提醒吗？”）回答后是一条新的用户消息和一条新的助手消息。

## 1. 任务列表

依赖关系一览：

```
T0 ─┬─ T1 ─┬─ T2 ─┬─ T3 ─┐
    │      │      └─ T4 ─┤
    │      └─ T5 ─┬─ T6 ─┼─ T7 ─┐
    │             └─ T9 ─┤      ├─ T10
    │                    └─ T8 ─┘
    └──────────────────────────────── T11（宿主集成，在宿主仓库）
```

### T0 仓库骨架与 CI 关卡

- **目标**：建好空仓库结构和全部 CI 关卡，让后续任务一提交就受约束。
- **主要模块**：仓库根、`rust/`、`dart/`、`tool/`、CI 配置。
- **依赖**：无。
- **产物**：Cargo workspace 与 pub workspace 空包；`tool/check_deps`（依赖方向）、`tool/host_terms.txt` + 检查脚本（宿主词汇拦截）、`tool/validate_schemas`（Schema 自检 + 夹具校验）；CI：`cargo fmt/clippy/test`、`dart format/analyze/test`、上述脚本。
- **验收**：故意在 `chatweave_core` 导入 `package:flutter`、在 `chatweave-protocol` 加 axum 依赖、在库代码里写一个宿主词汇，三种情况 CI 都失败。

### T1 协议规范定稿（0.1）与一致性夹具

- **目标**：把 [protocol.md](protocol.md) 与 `schemas/v0.1/` 定稿为 0.1，产出两端共用的一致性夹具。
- **主要模块**：`docs/protocol.md`、`schemas/v0.1/`、`fixtures/conformance/`。
- **依赖**：T0。
- **产物**：每个内置类型的正例 / 反例；至少 20 个事件流夹具（`*.events.jsonl` + `*.expected.json`），覆盖：纯文本、混排、占位后填充、块失败、中断、用户停止、重复事件、跳号、快照、补丁与 `rev`、未知块类型、未知事件类型、穿插临时进度事件（折叠结果与不含它们时相同）、超限；运行步骤夹具：并行步骤、步骤失败（其他步骤与回答不受影响）、步骤运行中用户停止（`cancelled` 在 `message.end` 之前）、步骤运行中断线续传（从步骤中间的 `seq` 重放）、步骤运行中拿到快照（快照含 `running` 的步骤，之后收到它的 `step.finished`）、崩溃恢复（运行中的步骤记为 `failed`）、步骤事件对旧客户端（按未知事件忽略，正文折叠结果相同）；嵌套步骤（子 Agent 并行、3 层嵌套）；中断夹具：暂停（检查点 = `fold` 到 `message.paused`）、回答后继续（`block.patch` → `message.resumed` → 步骤结束，最终消息 `complete`）、继续之后断线续传、暂停期间日志过期后拿快照再继续、暂停中停止、中断过期、子 Agent 里的中断、同一条消息两次暂停；反例：重复的 `stepId`、对未开始的步骤发 `step.finished`、已结束消息里有 `running` 或 `awaiting_user` 的步骤、`awaiting_user` 不带 `blockId`、步骤事件不带 `seq`、`parentStepId` 指向不存在 / 非委派 / 已结束的步骤或自己、嵌套超过 3 层、委派步骤先于子步骤结束、暂停时还有块没结束或别的步骤在运行、暂停中出现中断块以外的事件、`message.resumed` 前块不是 `resolved`、`interruptId` 不一致、`paused` 消息缺 `interrupt` 或 `lastSeq`；另有动作夹具：正常回答、先答者胜（后到者拿到 `already_resolved` + 当前状态）、过期、被取代、服务端作废（`cancelled` + `reason`）、回答中断（`accepted` + `resume`，没有补丁）、中断的文字回答（`choice.select {freeText}`）、中断已被另一台设备回答（`already_resolved` + `resume`）；生成控制夹具：开始（重复提交返回同一个助手消息 ID）、停止、活动消息查询。
- **验收**：`tool/validate_schemas` 通过（正例全部通过 Schema、反例全部被拒）；夹具的期望消息全部通过 `message.schema.json`。

### T2 Rust：`chatweave-protocol`

- **目标**：协议类型、校验、限制检查、折叠函数。
- **主要模块**：`rust/crates/chatweave-protocol`。
- **依赖**：T1。
- **产物**：serde 类型；`validate()`（`jsonschema` crate + `Limits`：字节数、深度、节点数）；自定义类型 Schema 注册表；`fold(events) -> Result<Message>`。
- **验收**：所有夹具 JSON 往返无损；`fold` 对每个事件流夹具的结果等于期望消息（包括 `steps`）；反例全部被 `validate()` 拒绝；`cargo tree` 不含 axum / tokio。

### T3 Rust：流生成器、事件日志与 SSE

- **目标**：服务端产生合规事件流、可续传。
- **主要模块**：`chatweave-server`（`MessageStream`、`EventLog`、`sse_response`，feature `axum`）。
- **依赖**：T2。
- **产物**：生成器（分配 seq / 块 ID / index，合并 delta，块失败与中断处理，`fallbackText` 辅助；运行步骤 API：开始步骤返回一个句柄，结束时给出状态、可选 `summary`，耗时由生成器计算；停止时自动把未结束的步骤记为 `cancelled`；结束消息时仍有未结束的步骤视为宿主缺陷，调试构建直接报错；子步骤 API 只能从委派步骤的句柄开出，自动检查嵌套层数与“子先于父结束”；中断 API：`pause(stepHandle, block)` 检查前提、发 `message.paused`、写暂停检查点并关闭订阅者的流，`resume(answer)` 发 `block.patch` + `message.resumed`，暂停中的停止与过期辅助）；`EventLog` 接口 + 默认的进程内环形缓冲实现（按消息、按 `seq`，保留期满释放）+ 检查点辅助；Axum SSE 辅助（`Last-Event-ID` / `?after=`、心跳、快照回退、`resume_unavailable`、`ChatWeave-Protocol` 响应头、`message.activity` 帧不带 `id:`）；停止与活动消息查询的处理函数（比对后清理活动登记）；崩溃恢复辅助（折叠日志或从检查点恢复 → interrupted）。
- **验收**：生成器的输出逐条通过 Schema；`axum-test` 集成测试：中途断开后带 `Last-Event-ID` 重连，拼接结果与不断开一致；日志清空（或模拟进程重启、缓冲为空）后得到快照；慢订阅者被断开不影响生成；客户端断开连接后生成继续，只有停止请求会结束生成；重复停止返回同样结果；临时进度事件不进入日志和折叠结果；步骤事件进入日志、续传时重放、快照含步骤；停止时每个运行中的步骤都在 `message.end` 之前得到 `cancelled`；崩溃恢复后运行中的步骤为 `failed`；`message.paused` 后连接关闭，暂停中订阅得到重放或快照后关闭；日志过期、服务端重启后暂停中的消息仍能继续；暂停中停止 / 过期得到正确的结束序列；回答、停止、过期并发时只有一个成功。

### T4 Rust：Action Registry 与 dispatcher

- **目标**：受控动作的服务端处理。
- **主要模块**：`chatweave-server::action`。
- **依赖**：T2。
- **产物**：`ActionHandler<Ctx>`、`ActionStore<Ctx>`、`ActionRegistry::dispatch()`；内存版 `ActionStore`。
- **验收**：中断块的回答返回 `accepted` + `resume`、不加 `rev`，重复动作 ID 不会让运行继续两次；单元测试覆盖 protocol.md 5.2 的每一步各自的拒绝路径（未声明、target 不符、已回答、过期、被取代、选项不在列表、表单越界、破坏性非确认、重复 ID 回放、`authorize` 拒绝）；非 `open` 的拒绝都带当前状态的补丁；并发的两个不同答案只有一个成功；成功路径返回补丁且 `rev` +1。

### T5 Dart：`chatweave_core`

- **目标**：客户端协议核心，纯 Dart。
- **主要模块**：`dart/packages/chatweave_core`。
- **依赖**：T1。
- **产物**：模型类（手写序列化）；`SseDecoder`；`EventParser`；`BlockStore`（单一写入口 `apply`、结构共享、seq 去重、按块合并、Merge Patch、`rev` 规则、持久化版本对账、乐观用户消息按 `id` 对账）；`StreamController`（续传状态机、触发时机、单飞、轮数上限、退避、心跳超时、“已请求停止”不自动重连、“已暂停”不自动重连及其重新订阅条件、临时进度提示、活动消息查询）；运行步骤的折叠（与块分开保存，含嵌套与暂停 / 继续）与过程条的本地展开状态（整条与每个委派步骤）；当前暂停中的中断（供输入框使用）；`InteractionController`；`ViewportController`（纯函数）；`inspect()` 只读快照与事件环形缓冲；`ChatWeaveStore` / `StreamTransport` / `ActionTransport` 接口与内存实现、`ScriptedTransport`；宿主实现一致性套件；`Limits`。
- **验收**：同一批一致性夹具全部通过（与 Rust 的 `fold` 结果一致）；SSE 解码对任意切分的字节流（逐字节、跨帧切分）结果相同；续传状态机的属性测试（随机插入重复、断线）最终状态等于期望消息；重复事件不触发通知且返回同一对象；同一消息的多个续传触发只产生一次连接；`ViewportController` 的单元测试（插入历史、组件变高时锚点不动）；内存实现通过一致性套件，故意写坏的实现被套件发现；`pubspec.yaml` 不含 Flutter，源码不导入 `dart:io`。

### T6 Flutter：主题接口、Markdown、注册表与降级

- **目标**：渲染底座。
- **主要模块**：`chatweave_flutter`（`ChatWeaveTheme`、`MarkdownBlockView`、`BlockRegistry`、`FallbackNote`）。
- **依赖**：T5。
- **产物**：主题接口与中性浅色 / 深色主题；Markdown 安全子集（含流式“稳定段落 + 活动尾部”）；注册表（含 `override`、`markdownOnly()`、`capabilities()`）；降级链。
- **验收**：Markdown 子集测试（HTML、图片、`javascript:` 链接均按纯文本 / 禁用处理；单换行即换行）；未知类型、过高版本、`parse` 抛异常、`build` 抛异常、布局阶段抛异常五种情况都只降级该块，且 `onBlockRenderError` 每块只上报一次；对内置类型调用 `register` 抛错；长文本流式时每批 delta 只重新解析尾部（用计数器断言）。

### T7 Flutter：默认组件

- **目标**：10 种内置类型的中性默认组件。
- **主要模块**：`chatweave_flutter/components`。
- **依赖**：T6。
- **产物**：`MetricTile`、`MetricGrid`、`DataTableView`、`LineChartView`（自绘）、`ComparisonTable`、`StatusView`、`ChoiceView`、`ConfirmationCard`、`IntentForm`，以及各自的占位骨架；消息级的运行过程条 `ProcessStrip`（[rendering.md 4.3](rendering.md#43-运行过程条processstrip)）。
- **验收**：每个组件的组件测试 + golden（浅 / 深 × 360 / 430 × 100% / 200%）；无障碍指南测试通过；200% 字号无溢出（`tester.takeException()` 为空）；`ProcessStrip` 覆盖运行中 / 全部完成 / 有失败 / 等你确认（块 open 与已确认）/ 已停止 / 收起与展开，读屏语义含展开状态，状态不只靠颜色。

### T8 Flutter：聊天列表、输入框与流式集成

- **目标**：把流接到界面上，且界面不跳。
- **主要模块**：`ChatWeaveList`、`ChatWeaveComposer`、`MessageView`。
- **依赖**：T6、T7。
- **产物**：反向列表（`CustomScrollView` + `SliverList`），由 `ViewportController` 驱动（唯一的滚动写入点）；滚动跟随与“有新内容”按钮、占位尺寸过渡、每帧最多一次重建、生成中的消息不显示操作栏、可替换的用户消息 / 消息外框构建器；`ChatWeaveDebugOverlay`（只读）。
- **验收**：用夹具驱动的组件测试：组件出现前后，上方已渲染文字的位置（`tester.getTopLeft`）不变；过程条新增步骤、`message.end` 时收起，用户正在看的内容不动；有步骤运行时不显示临时提示；用户手动展开过的过程条在 `message.end` 时不被自动收起；用户上翻时不自动滚动，生成中的消息变长不增加“新内容”计数；读屏只在块结束时播报；打开调试面板前后 store 的事件序列完全相同（只读）；导出的 JSON 默认不含正文。

### T9 Dart / Flutter：动作客户端

- **目标**：交互块的客户端流程。
- **主要模块**：`chatweave_core`（`ActionRequest` 构造、`InteractionController`）、`chatweave_flutter`（交互组件接线）。
- **依赖**：T5、T7。
- **产物**：“提交中”与“已排队（离线）”显示状态（不乐观显示结果）、收到补丁后显示服务端结果（含另一台设备或群聊里别人先答的情况）、`cancelled` 带原因的显示、`followUp` 自动订阅、`resume` 后按已应用 `seq` 重新订阅同一条消息、中断块的文字回答（输入框路由到卡片）、错误显示（含 `fieldErrors`）、`unavailable` / 超时的“正在确认”状态与同 ID 重试、无 `ActionTransport` 时只读。
- **验收**：重复点击只生成一个动作 ID；网络错误后重试复用同一 ID；提交中界面上没有任何选项被标为已选；服务端拒绝时回到可操作状态并显示原因；`already_resolved` 时显示补丁里的答案而不是本地点击；补丁重复应用无副作用；组件被回收重建后提交中状态与幂等键不变；回答中断后在 `block.patch` 到达前卡片只显示“提交中”，回答不产生用户消息。

### T10 示例 App 与端到端测试

- **目标**：证明库在非宿主领域完整可用，并作为 golden 的运行环境。
- **主要模块**：`examples/assist_demo/server`（Axum + 脚本化假 Agent + 内存存储）、`examples/assist_demo/app`（Flutter）。
- **依赖**：T3、T4、T8、T9。
- **产物**：天气 + 待办领域；自定义类型 `x-todo.task_card` 演示宿主组件注册；断网模拟开关；假 Agent 的工具都登记了步骤标签（含一个可配置为失败的天气查询）；假 Agent 有一个天气子 Agent（演示嵌套步骤），删除待办会触发中断（演示暂停与继续）。
- **验收**：第 0 节的十一条端到端场景全部自动化通过（集成测试 + golden）。

### T11 首个宿主集成（在宿主仓库进行，不在本仓库）

- **目标**：在真实宿主里用路径依赖接入，验证接口够用、没有泄漏宿主概念。
- **依赖**：T5–T9 可用即可开始（服务端部分依赖 T3、T4）。
- **产物（宿主侧）**：主题实现、存储适配器、自定义组件、服务端映射与 SSE 端点、动作处理器。
- **验收**：宿主集成过程中需要改库的地方，全部以“通用能力”的形式进入库（不出现宿主词汇，CI 词汇拦截通过）；宿主的存储与传输实现通过库的一致性套件；宿主测试通过。

## 2. 风险较高的部分与替代方案

| # | 风险 | 首选方案 | 替代方案 |
|---|---|---|---|
| R1 | 长 Markdown 流式渲染卡顿（每批 delta 重解析） | “稳定段落 + 活动尾部”增量解析 + 帧级批量 | 服务端按句 / 段切块（每段一个 markdown 块）；或流式期间先显示纯文本，块结束后再渲染 Markdown |
| R2 | 移动网络、运营商代理切断或缓冲 SSE 长连接 | 心跳 + `no-store` + 关闭代理缓冲 + 续传 | 降级为短轮询（`GET …/events?after=N` 一次取一批）；最差情况只靠宿主同步拿最终版本（失去逐字效果但功能完整） |
| R3 | 反向列表在内容增长时滚动锚定不稳 | 自研 `CustomScrollView` + 纯函数 `ViewportController`（锚点 = ID + 偏移，可在纯 Dart 里单测）+ 尺寸过渡 + 底部跟随逻辑 | 引入 `flutter_chat_ui`（后端无关、可完全自定义构建器）只用它的列表与动画 |
| R4 | 自绘图表工作量与质量 | `CustomPainter` 只做折线（v1 足够） | `fl_chart` 等成熟图表库；或 v1 直接把 `time_series` 降级为表格 |
| R5 | Dart 端缺少成熟的 JSON Schema 2020-12 校验器 | 客户端不跑 Schema，只做类型化解析 + 限制检查；Schema 一致性由夹具保证 | 评估 `json_schema` 包，仅在测试中使用 |
| R6 | Rust 与 Dart 两套实现漂移 | 共用一致性夹具，两端 CI 都跑 | 从 Schema 生成两端类型（`typify` / 自写生成器），代价是生成代码可读性差 |
| R7 | 模型的工具调用参数分片到达 | 服务端缓冲到工具调用完整再执行并发 `block.data`（与“组件整块到达”一致） | — |
| R8 | 事件日志写入量（每个 delta 一行） | 默认进程内缓冲 + 检查点，重启后只给快照（D42）；合并 delta（约 20 字 / 50ms 一批）；日志保留期短 | 多实例或要求重启后逐事件续传时，换成持久日志（例如 PostgreSQL） |
| R9 | A2UI 将来成为事实标准，迁移成本 | 字段形状对齐 + 映射表 | Phase 2 评估适配器；或在块内嵌 A2UI surface 作为一种自定义类型 |
