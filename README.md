# ChatWeave

> **ChatWeave** is a Markdown-first, hybrid Generative UI library for chat apps. Agents keep answering in streaming Markdown, and when information really is structured (metrics, tables, time series, comparisons, status, choices, confirmations, forms) they emit validated **semantic blocks** that the client renders with native components. Text and components interleave in one message. ChatWeave ships a language-neutral protocol with JSON Schemas, Rust crates for the server (types, validation, an SSE stream emitter for Axum, an action registry) and Flutter packages for the client (stream parser, block store with resume, renderer, component registry, neutral themeable components). It knows nothing about any host's business domain. **Status: design stage, no code yet.**

ChatWeave 是一个 **Markdown 优先的混合式生成 UI 聊天库**：回答默认仍是边生成边显示的 Markdown；信息确实适合结构化展示时，Agent 输出经过校验的**语义块**，客户端用原生组件画出来，文字和组件在同一条消息里自然交错。

**适用场景**：一对一（一位用户和 AI 对话）与群聊（多位成员和 AI 在同一个会话里）都支持。协议和客户端规则在两种场景下相同；只在群聊里才会出现的问题（多人同时回答同一张卡、块级可见性）在文档里单独标明。

## 当前状态

**设计阶段（草案），还没有代码。** 本仓库目前只有设计文档和 JSON Schema 草案（协议 0.1）。

## 为什么做

- 纯 Markdown 能写标题、列表、表格，但承载不了“可读的数据展示”和“可点的交互”。
- 让模型直接生成界面（HTML、组件树）又带来延迟、成本、安全和风格不统一的问题。
- 现有方案还不成熟：Flutter 的 genui 包自称“highly experimental”并已宣布重写，A2UI 协议仍是早期预览。

ChatWeave 的取舍：**让 Agent 决定表达什么，让渲染器决定通常怎么展示。** Agent 只给事实和语义（数值、单位、时间、评价），颜色、布局、组件由客户端注册表和宿主主题决定；所有结构化内容都经 Schema 校验；任何时候都能退回纯文本。

## 核心特点

- **Markdown 优先**：普通段落、解释、结论保持 Markdown；结构化只在需要时出现。
- **10 种语义块**：`markdown`、`metric`、`metric_group`、`dataset`、`time_series`、`comparison`、`status`、`choice`、`confirmation`、`form_intent`，外加宿主自定义类型（`x-<host>.<name>`）。
- **流式**：文字逐步出现；组件先占位、数据到达时整块填满；稳定块 ID、按 ID 补丁、幂等事件、断线续传（SSE + `Last-Event-ID`）、快照回退；持久化版本优先；显式“停止生成”（与断线严格区分）、只用于显示的临时进度提示、按会话找回正在生成的消息。
- **安全**：组件白名单、Schema 校验、数量与大小限制、Markdown 安全子集（不渲染 HTML、不加载图片）；UI 动作必须经服务端注册表校验和宿主权限检查，破坏性操作需要确认。
- **交互结果以服务端为准**：选项、确认卡点按后只显示“提交中”，服务端记录后才显示结果——即使是一对一，服务端也可能拒绝（权限、记录已变化或删除、校验不通过），同一用户也可能在两台设备上操作；群聊里多人同时回答时先答者胜，所有设备显示同一个结果；幂等键在重试间保持不变。
- **稳健的客户端状态**：单一写入口、结构共享、按块错误隔离、续传有明确的触发时机和上限、用户消息 ID 由客户端生成（兼作离线重发的幂等键），乐观副本按同一个 ID 对账；附带只读调试面板和宿主实现一致性测试。
- **与宿主解耦**：存储、传输、权限、主题全部由宿主注入；库不包含任何业务概念。
- **与模型无关**：不依赖特定模型或 Agent 框架；只会输出文本的 Agent 自动降级为 Markdown。
- **形状对齐 A2UI**：不依赖 A2UI，但字段形状对齐，将来可以加适配器。

## 概念示例

一条助手消息由有序的块组成（节选）：

```json
{
  "id": "msg_01",
  "protocolVersion": "0.1",
  "role": "assistant",
  "status": "complete",
  "rev": 1,
  "createdAt": "2026-10-26T09:30:00Z",
  "fallbackText": "北京今天晴：最高 18°C，最低 7°C，降水概率 10%。要我给“交水费”设个提醒吗？",
  "blocks": [
    { "id": "b1", "type": "markdown", "schemaVersion": 1, "data": { "text": "北京今天**晴**，白天比较暖和：" } },
    {
      "id": "b2", "type": "metric_group", "schemaVersion": 1,
      "data": {
        "title": "北京 · 今天",
        "metrics": [
          { "label": "最高", "value": 18, "unit": "°C" },
          { "label": "最低", "value": 7, "unit": "°C" },
          { "label": "降水概率", "value": 0.1, "format": { "style": "percent" }, "assessment": { "status": "positive", "label": "适合出门" } }
        ]
      },
      "fallbackText": "北京今天：最高 18°C，最低 7°C，降水概率 10%（适合出门）",
      "metadata": { "provenance": "tool" }
    },
    {
      "id": "b3", "type": "choice", "schemaVersion": 1,
      "data": {
        "prompt": "要我给“交水费”设个提醒吗？",
        "options": [ { "id": "yes", "label": "好，明早 9 点" }, { "id": "no", "label": "不用" } ],
        "action": { "type": "choice.select", "target": "reminder.create" },
        "state": { "status": "open" }
      },
      "fallbackText": "要我给“交水费”设个提醒吗？（好，明早 9 点 / 不用）"
    }
  ]
}
```

注意块里没有颜色、尺寸或组件名：`assessment.status = "positive"` 由宿主主题决定用什么颜色和图标；`metric_group` 默认画成指标网格；不认识的类型显示 `fallbackText`。流式时这条消息以事件序列的形式到达，见 [docs/streaming.md](docs/streaming.md)。

宿主接入的大致样子（示意，未编译）：

```dart
final registry = BlockRegistry.withDefaults()
  ..register<TaskCardData>(
    type: 'x-todo.task_card', maxSchemaVersion: 1,
    parse: TaskCardData.fromJson,
    build: (context, block, data) => TaskCard(taskId: data.taskId),
  );

ChatWeaveTheme(
  data: myBrandTheme,                    // 宿主实现 ChatWeaveThemeData
  child: ChatWeaveList(
    conversationId: 'conv_42',
    store: myStore,                      // 宿主实现 ChatWeaveStore（例如基于本地数据库）
    transport: mySseTransport,           // 宿主实现 StreamTransport（用宿主已有的 HTTP 客户端）
    actions: myActionTransport,          // 宿主实现 ActionTransport（例如走离线队列）
    registry: registry,
  ),
);
```

## 仓库结构（规划）

```
README.md
LICENSE                      MIT
schemas/v0.1/                JSON Schema（draft 2020-12）：content-block / message / stream-event / action / capabilities / generation
fixtures/conformance/        一致性夹具（事件流 → 期望消息），Rust 与 Dart 共用（规划）
rust/crates/                 chatweave-protocol、chatweave-server（规划）
dart/packages/               chatweave_core（纯 Dart）、chatweave_flutter（规划）
examples/assist_demo/        非记账领域示例：天气 + 待办助手（规划）
tool/                        CI 检查：依赖方向、宿主词汇拦截、Schema 校验（规划）
docs/
  architecture.md            分层、模块、数据流、职责划分、分期
  protocol.md                协议规范：消息、块、流式事件、动作、版本与能力协商、限制
  streaming.md               端到端事件示例、SSE 封装、断线续传、顺序与去重、布局稳定
  rendering.md               组件注册表、降级、主题接口、Markdown 安全子集、无障碍
  security.md                威胁模型与控制措施、宿主检查清单
  mvp-plan.md                MVP 任务拆分与验收标准、风险与替代方案
  decisions.md               决策记录（ADR）
  open-questions.md          待定问题
```

## 文档阅读顺序

1. [architecture.md](docs/architecture.md)：先了解整体分层和各部分职责。
2. [protocol.md](docs/protocol.md) + [streaming.md](docs/streaming.md)：协议与流式细节。
3. [rendering.md](docs/rendering.md) + [security.md](docs/security.md)：客户端渲染与安全。
4. [mvp-plan.md](docs/mvp-plan.md)：怎么分步实现。
5. [decisions.md](docs/decisions.md) / [open-questions.md](docs/open-questions.md)：为什么这样选、还有什么没定。

## 许可证

[MIT](LICENSE)。
