# 渲染（草案）

> **状态：草案。** 本文描述 `chatweave_flutter` 的组件注册表、降级规则、主题接口、Markdown 安全子集和无障碍要求。协议层的降级顺序见 [protocol.md 第 6 节](protocol.md#6-降级规则任何时候都能只看文本)。

## 1. 原则

- **渲染器是确定性的**：同样的消息、同样的主题，画出来永远一样；不依赖模型才能工作。
- **颜色表达语义，由主题决定**：块里没有颜色和尺寸；`assessment.status` 之类的语义字段由主题映射成颜色、图标和文字标签。
- **克制**：组件只做“把数据读清楚”这一件事，不做花哨动效，不为了展示 UI 而展示 UI。
- **失败只影响一个块**：任何组件构建出错，都只把这个块换成兜底文本，整条消息照常显示。
- **结果以服务端为准**：交互块不乐观显示结果，点按之后只显示“提交中”，服务端确认后才显示结果。
- **过程看得见、但不打扰**：AI 回答前做了哪些步骤，列在消息顶部的过程条里，回答完成后自动收起成一行；子 Agent 的步骤收在委派步骤那一行里；只显示宿主写的说明，不显示工具参数、原始数据和模型的思考文字（4.3）。
- **问了就在原地等**：运行中途需要确认或回答时，消息暂停在原地，回答显示在卡片上，同一条消息继续生成（4.4）。

## 2. 组件注册表（BlockRegistry）

注册表是一张“块类型 → 组件构建器”的表：

```dart
final registry = BlockRegistry.withDefaults()          // 内置 12 种类型的默认组件
  ..register<TaskCardData>(
    type: 'x-todo.task_card',
    maxSchemaVersion: 1,
    parse: TaskCardData.fromJson,                       // 宿主自己的解析与校验，失败抛异常 → 降级
    build: (context, block, data) => TaskCard(taskId: data.taskId),
  )
  ..override('metric_group', maxSchemaVersion: 1, build: myMetricGrid)  // 可替换某个默认组件
  ..register<TaskCardData>(
    type: 'x-todo.task_card',
    maxSchemaVersion: 2,
    when: (block) => block.schemaVersion == 2,           // 同一类型可以按谓词细分
    parse: TaskCardDataV2.fromJson,
    build: (context, block, data) => TaskCardV2(data),
  );
```

每个注册项包含：

| 项 | 说明 |
|---|---|
| `type` | 块类型；自定义类型必须是 `x-<host>.<name>` 形式 |
| `maxSchemaVersion` | 支持的最高 `schemaVersion`，更高的版本走降级 |
| `parse` | 把 `data` 解析成强类型对象并校验（内置类型由库实现；客户端不跑完整 JSON Schema，而是“类型化解析 + 限制检查”） |
| `build` | 构建组件 |
| `placeholder` | 可选：`block.start` 之后、数据到达前的骨架；默认按类型和 `placeholder.size / items` 估算高度 |
| `fallback` | 可选：降级链中的下一个类型（例如 `time_series → dataset`） |
| `when` | 可选：谓词。同一类型可以注册多个构建器，按注册顺序**第一个谓词为真的胜出**（例如按 `schemaVersion` 或 `metadata.host` 里的标记区分） |
| `requires` | 可选：组件依赖的宿主能力（例如 `ActionTransport`）。缺少时不报错，组件按只读方式渲染（见 4.2） |

覆盖规则：内置类型只能用 `override` 显式替换；对内置类型调用 `register` 会立即抛错，避免宿主“无意中”替换了默认组件。同一个自定义类型重复 `register` 而没有 `when` 区分，也会抛错。

注册表也是能力声明的来源：`registry.capabilities()` 生成发给服务端的 `blocks` 列表（[protocol.md 7.2](protocol.md#72-能力声明)），保证“声明的”和“能画的”一致。

### 2.1 默认组件

| 类型 | 默认组件 | 要点 |
|---|---|---|
| `markdown` | `MarkdownBlockView` | 安全子集（第 3 节）；流式时分“稳定段落 + 活动尾部” |
| `metric` | `MetricTile` | 标签、数值（按 `format` 本地化）、单位、变化量（箭头 + 文字）、评价（颜色 + 图标 + 文字标签） |
| `metric_group` | `MetricGrid` | 按可用宽度自适应列数（窄屏 2 列，宽屏 3–4 列）；标题与摘要 |
| `dataset` | `DataTableView` | 表头固定；列超出宽度时表格内部横向滚动（页面不横向滚动）；超过 20 行默认折叠“展开全部”；`totalRows` 时显示“显示 N / 共 M 条” |
| `time_series` | `LineChartView` | 自绘折线（`CustomPainter`），不引入图表库；坐标轴、图例、缺测断线；点按可切换“表格视图” |
| `comparison` | `ComparisonTable` | 对象为列、维度为行；`assessment` 用主题的语义色 + 文字标签；结论在表下方 |
| `breakdown` | `BreakdownView` | 自绘环形图，中心显示各部分之和；下方图例逐项列出数值和占比（图例本身就是可读的文字版）；超过调色板长度的部分用降低透明度的同色区分 |
| `category_series` | `CategorySeriesView` | 自绘柱状图，从零起画（支持负数），`null` 不画柱；参考线为虚线并在图下用文字说明；`assessment` 用主题的提醒色 / 危险色；点按可切换“表格视图” |
| `status` | `StatusView` | 状态图标 + 文字；有 `progress` 显示进度条；有 `steps` 显示步骤列表 |
| `choice` | `ChoiceView` | 选项按钮组；单选 / 多选；块是中断的提问且 `otherInput` 不为 `false` 时，选项后面固定多一个“输入其他内容”（点了进入输入框的回答状态，见 4.5）；已经结束的消息里 `allowFreeText` 时提示“也可以直接发消息回答”；点按后整组显示“提交中”；`state` 非 `open` 时显示**服务端记录的**选项、回答者与时间，并禁用 |
| `confirmation` | `ConfirmationCard` | 标题、说明、细节表；破坏性操作的确认按钮用主题的“危险”样式，且必须二次点按（或按住）才能提交；是中断的块且 `otherInput` 不为 `false` 时按钮下方有“输入其他内容”；点按后显示“提交中”，服务端确认后才显示“已确认 / 已取消” |
| `form_intent` | `IntentForm` | 按字段类型生成输入控件；客户端先做必填 / 范围 / 长度校验；服务端返回的 `fieldErrors` 显示在对应字段下；是中断的块且 `otherInput` 不为 `false` 时提交按钮下方有“输入其他内容” |

默认组件只用 Flutter `widgets` 层能力和主题接口取样式，不依赖 Material 的颜色或文字主题；按钮（含禁用态）、字段错误与进度文字显式取 ChatWeave 语义颜色，发送与关闭图标用 Canvas 自绘，不需要 MaterialIcons 字体（Markdown 渲染依赖的 `flutter_markdown_plus` 内部用到 Material，样式表仍完全由主题接口提供）。

## 3. Markdown 安全子集

用 `flutter_markdown_plus`（`flutter_markdown` 停更后的官方指定继任者，依赖只有 `markdown`、`meta`、`path`），并在解析层面限制语法，而不是只在显示时隐藏：

| 语法 | 处理 |
|---|---|
| 段落、换行、粗体、斜体、删除线、行内代码 | ✅ **单个换行就是换行**（不按 CommonMark 合并成空格）：模型输出里大量依赖单换行分行，合并会把列表式回答挤成一段 |
| 有序 / 无序列表（嵌套 ≤ 3 层） | ✅ 超过的层级压平 |
| 标题 | ✅ 但统一降级为 3–4 级大小，避免回复里出现巨大标题 |
| 引用块 | ✅ |
| 代码块 | ✅ 等宽字体、内部横向滚动；v1 不做语法高亮 |
| 表格（GFM） | ✅（能力 `markdown.tables`）列数 ≤ 8，内部横向滚动；结构化数据应优先用 `dataset` |
| 链接 | ⚠️ 只允许 `https:`，以及宿主配置的白名单协议（例如宿主自己的深链接）；宿主可以注入 `isAllowedLink` / `onLinkTap` 两个钩子扩展白名单、把站内链接路由到自己的页面；外部链接先显示目标网址再确认打开；`javascript:`、`data:`、`file:` 等一律显示为纯文本 |
| 自动识别的网址 | 同链接规则 |
| 图片 | ❌ 不加载，显示为 `[图片：alt 文字]`；有网址时显示为一个普通链接（同链接规则），避免追踪像素、远程内容和隐私泄露 |
| 原始 HTML（行内与块级） | ❌ 按纯文本显示 |
| 脚注、数学公式、任务列表、Mermaid 等扩展 | ❌ v1 不支持，按纯文本显示 |

其他要求：

- 单块文本上限 32 KB、data 深度 6、块节点数 5000；delta / patch / snapshot 都检查，按不可变块 revision 缓存结果。超限仅该块降级。
- 普通段落在稳定边界封存；活动尾部按几何增长阈值重解析，间隔内追加文本原样显示，块结束时完整解析尾部。列表跨段与引用定义回退为整体解析，并同样按几何阈值批处理，完成时保证列表与引用解析正确（[streaming.md 第 7 节](streaming.md#7-布局稳定避免界面跳动)）。
- 文本可选择、可复制；复制时得到原始 Markdown 去除标记后的纯文本。
- 代码块与行内代码里的内容一律原样显示，不解释其中的任何语法或链接。
- 库提供 `plainTextSummary(message, maxChars)`：去掉 Markdown 标记、组件块用 `fallbackText`，供宿主做通知、会话列表预览、搜索摘要，保证各处的“纯文本版本”一致。

## 4. 降级规则（客户端实现）

存储恢复、message.snapshot、SyncMessage 与动作补丁均按消费方宽进处理：保留坏块原始内容与 fallbackText，由注册表仅降级该块为纯文本或 FallbackNote，兄弟块正常显示；FoldState 默认不因单块结构或数据校验失败拒绝整条消息。manifest 一致性测试显式启用 strictBlocks 生产方严格模式；消息级字节预算、seq/rev 与事件顺序检查仍有效。

正文默认使用 `Text` / `RichText`，不创建带 longPress 的只读输入控件；选择复制由宿主在列表外包 `SelectionArea`，或使用消息操作栏的“复制”。

默认组件在自己的 build、流 builder 和布局 builder 内执行解析、格式化、取数据与布局参数计算，并在同一边界里捕获异常。默认组件及注册表 `parse` / `build` 内的异常均保证逐块降级；边界内同步布局 / 绘制异常同样降级，兄弟块继续显示。

对每个块：

0. **每个块单独包一层错误边界**：默认组件、注册表工厂的 `parse` / `build` 及边界内同步布局 / 绘制异常会让该块原地换成自己的 `fallbackText`，同一条消息里的其他块照常显示。通过宿主注入的 `onBlockRenderError` 上报，**每个块 ID + 类型只上报一次**（列表反复重建不会刷屏）。
1. 注册了该类型、`schemaVersion` 不超过支持版本、`parse` 成功、`build` 不抛异常 → 正常组件。
2. 否则沿 `fallback` 链尝试下一个类型（内置链：`time_series → dataset`、`comparison → dataset`、`breakdown → dataset`、`category_series → dataset`、`metric_group → metric 列表`）。
3. 否则显示 `FallbackNote`：块的 `fallbackText`（中性样式，带一个小提示“更新 App 可查看完整内容”，读屏读出文字本身）。
4. `fallbackText` 也没有 → “此内容无法显示”。

每次降级通过宿主注入的回调上报一次（类型、版本、原因），库本身不做任何遥测、不联网。

**Markdown-only 模式**：`BlockRegistry.markdownOnly()` 只保留 markdown，其他全部走 `fallbackText`。用于排障开关、极简宿主，或作为发布时的应急降级。

### 4.1 生成中的消息

生成中的消息不显示复制、转发等操作栏，结束后才出现（[streaming.md 第 6 节](streaming.md#6-中断与不完整的块)）；被停止或出错时保留已出现的内容，并在末尾标“已停止”或错误说明。

- **临时进度提示**：收到 `message.activity` 时，在消息末尾（或正在等待的占位旁）用弱化的样式显示 `label`（没有 `label` 时按 `phase` 显示默认文案，如“正在处理…”“仍在处理，请稍候”）。提示不进消息内容、不被复制、不被搜索；读屏只在提示变化时礼貌播报一次。**有步骤正在运行时不显示**，以过程条为准（4.3）。
- **停止按钮**：生成中和暂停中都显示“停止”；点按后变成“正在停止…”并禁用，直到 `message.end` 或持久化版本到达（[streaming.md 4.4](streaming.md#44-停止生成)）。离开页面、切后台不会触发停止。
- **消息级操作插槽**：结束后的操作栏除了库自带的复制，还可以放宿主自己的操作，例如点赞 / 点踩。库只提供插槽和回调（`messageActionsBuilder`、`onMessageFeedback` 之类），**不保存、不上传**这些数据，协议里也没有对应字段（[D47](decisions.md)）。

### 4.2 交互块的显示状态

动作遇到超时、网络错误或 `unavailable` 时，控制器先调用 `onRefresh`。块仍为 open 时，以同一个已持久化的 ActionRequest（ID 与 payload 不变）自动退避重试，默认最多再试 3 次（250 / 500 / 1000 ms）。达到上限进入 retryable；卡片显示“重试”，调用 `retry(messageId, blockId)` 继续使用该 ID。恢复消息后宿主调用一次 `await interactions.restore(messageId)`，会刷新并自动恢复这些意图，不需要另调 retryPending。宿主须把 `onRefresh` 接到权威同步并将结果应用到 BlockStore；组件回收重建无需 restore。

交互块的显示由两部分决定：服务端写的 `state`（[protocol.md 3.4](protocol.md#34-交互块的状态choice--confirmation--form_intent)），加上 `InteractionController` 里的本地显示状态。

| 本地 / 服务端状态 | 显示 | 控件 |
|---|---|---|
| `open`，未操作 | 正常 | 可用 |
| `open`，提交中 | 被点的按钮显示进度指示，整个块显示“提交中…”；**不把选项画成已选中** | 全部禁用，防止双击或改选 |
| `open`，已排队（离线） | “已排队，联网后提交” | 禁用 |
| `open`，服务端明确拒绝（`invalid_payload`、`forbidden`、`conflict` 等） | 回到未操作状态，并在块内显示服务端给的 `message`（表单显示 `fieldErrors`） | 可用（重新操作会生成新幂等键） |
| `open`，`unavailable` 或客户端超时 | “暂时无法确认结果，正在刷新…”；**不说“失败”**，因为动作可能已经执行 | 禁用，直到刷新到服务端状态；重试复用同一幂等键 |
| `resolved` | 服务端记录的答案（选中的选项 / 文字回答 / 已确认或已取消 / 表单值摘要）+ 回答者与时间（宿主把 `resolvedBy` 解析成显示名；一对一会话里可以不显示回答者）。如果答案不是这台设备点的（群聊里别人先答，或一对一时同一用户在另一台设备上先答），照实显示服务端记录的那个答案。用户在确认卡上点“取消”也在这里，显示“你已取消” | 禁用 |
| `expired` / `cancelled` / `superseded` | “已过期” / “已作废” + `reason.text`（没有时按 `reason.code` 给默认文案，如“相关记录已被删除”；`stopped` 无说明时为“已停止，没有等到回答”；有 `reason.text` 时如实显示该说明，不附加“没有等到回答”）/ “已被新的请求取代”；措辞要和用户自己点的“取消”区分开 | 禁用 |
| 没有 `ActionTransport`、会话只读，或宿主判定当前查看者不能回答 | 内容与状态照常显示，附一行简短说明（例如“仅可查看”） | 禁用；**不会**改为把选项文字作为消息发出 |

文案原则：只有服务端明确拒绝时才用“没能完成”这类说法；结果未知时只说“正在确认”。

### 4.3 运行过程条（ProcessStrip）

助手消息有运行步骤（`message.steps`，[protocol.md 4.7](protocol.md#47-运行步骤stepstarted--stepfinished)）时，`MessageView` 在**正文之上**画一条“过程”。它是消息级组件，不是块：不在 `BlockRegistry` 里，不参与块的降级链；数据来自 `BlockStore` 里与块分开保存的步骤列表。没有步骤的消息不显示过程条。宿主可以用 `processStripBuilder` 换掉默认外观，或者完全关闭（关闭后客户端不声明 `stream.steps`）。

**两种形态**

| 时机 | 形态 |
|---|---|
| 生成中（`status = streaming`） | **展开**：每个步骤一行，按 `step.started` 的顺序。运行中“对比上周 ⏳”；完成“查北京本周天气 ✓ 0.8 秒”；失败“查上海本周天气 · 没有完成”（有 `summary` 时显示它，如“天气服务暂时不可用”） |
| 暂停中（`status = paused`） | **保持展开**：等用户的那一行“删除待办“交水费” · 等你确认”（选项 / 表单为“等你回答”），其他行照常。回答之后这一行回到运行中，再变成完成，例如“删除待办“交水费” ✓ 0.7 秒 · 你已确认” |
| 消息结束后（`message.end` 或持久化版本到达） | **自动收起成一行摘要**，例如“查了 3 项 · 用时 4 秒”；有失败时“查了 3 项（1 项没有完成）· 用时 4 秒”；被停止时“查了 2 项 · 已停止”。点按展开 / 收起 |

- **行的内容**：状态图标 + `label` + 结果（耗时或状态文字）+ 可选的一行 `summary`（弱化样式，在 `label` 下方或同一行末尾）。原始查询结果不显示（协议里也没有）。
- **耗时**：按 `durationMs` 显示（不含等用户的时间），不足 10 秒保留一位小数（“0.8 秒”），否则取整（“12 秒”）；运行中的步骤不显示走字计时。摘要里的总用时 = 消息的 `completedAt − createdAt`，缺少时用最上层各步骤 `durationMs` 之和；**暂停过的消息**（规范判据：`step.blockId` 指向三种交互类型之一的中断块）不显示总用时（总时长里有等用户的时间，没有意义），改为“查了 3 项 · 你确认了 1 项”这类说法。
- **数几项**：摘要里的“查了 N 项”只数最上层（主 Agent）的步骤；一个委派步骤算一项。
- **失败只影响这一行**：失败的行用主题的 `status.warning` 样式 + 图标 + 文字“没有完成”，不用“错误”这类吓人的词；其他行和正文照常显示。
- **等你确认**：`awaiting_user` 的行显示“等你确认”（确认卡）或“等你回答”（选项、表单），用主题的强调样式，点这一行滚动到 `blockId` 指向的块。确认卡本身只在正文里，不在过程条里重复。回答之后这一行先回到运行中（⏳），结束时照常显示结果和耗时，并在末尾附上回答的简短说明（“你已确认”“你选了：北京”，取自块的 `state`）；以后从历史打开也一样（步骤记录保留 `blockId`）。停止或过期时这一行显示“已停止”。
- **子 Agent（嵌套步骤）**：带 `parentStepId` 的步骤画在它的委派步骤下面、缩进一级；**默认收起**：委派步骤那一行显示自己的状态，行尾是子步骤数（“3 步”）和展开箭头，点按展开 / 收起子步骤（与整条过程条的展开互相独立，展开状态同样放在 `chatweave_core`，按消息 ID + 步骤 ID）。收起时委派步骤这一行代表整个子 Agent：子 Agent 里有一步在等用户时，这一行显示“等你确认”并可点按滚动到那个块（不强制展开）；子步骤失败只在展开后的那一行显示，委派步骤自己的状态由宿主给出。最多 3 层，每层缩进一级。
- **收起与展开**：自动收起只在 `message.end` 那一刻发生一次（暂停不算结束，暂停时不收起）。用户在生成中手动收起或展开过，就尊重用户的选择，不再自动切换。从历史记录打开的消息默认收起；打开一条暂停中的消息时默认展开，让“等你确认”那一行看得见。用户手动收起或展开时，以被点按的那一行为锚点保持不动（它下面的正文随之移动）；只有自动变化（新增步骤、`message.end` 自动收起）才以用户正在看的正文为锚点。展开状态是本地显示状态，放在 `chatweave_core`（按消息 ID），列表回收不丢，不进协议。
- **与临时提示的关系**：有步骤处于运行中时不显示 `message.activity` 提示；没有运行中的步骤时（例如第一个步骤之前、所有步骤结束后模型还在组织回答）照常在消息末尾显示提示。
- **不显示**：工具名、参数、原始数据、模型的思考文字——这些都不在协议里。
- **纯文本与复制**：过程条不进 `fallbackText`、`plainTextSummary()`、复制内容和搜索。
- **主题**：颜色与图标取自主题（`status.*`、`icons` 里的运行中 / 完成 / 没有完成 / 等待 / 已停止 / 展开子步骤图标），文字用 `caption`；运行中图标的转动受“减少动态效果”控制，开启时换成静态图标。

### 4.4 暂停与继续（中断）

历史暂停的规范判据是 `step.blockId` 指向中断块；无需新增暂停历史字段。

运行中途要用户确认或回答时，消息暂停（[protocol.md 4.8](protocol.md#48-中断暂停与继续同一条消息)）。界面上它仍是**同一条消息**：

- **暂停中**：已出现的文字和组件照常显示；问题所在的交互块可操作；没有生成中的光标和临时提示，也不显示“连接中断”；过程条保持展开，那一行“等你确认 / 等你回答”。停止按钮可用；点按后显示“正在停止…”并禁用重复点按，继续接收实时连接直到 message.end，兜底刷新持续退避直到最终 rev 到达（停止后卡片优先显示服务端 `state.reason.text`；无说明时显示“已停止，没有等到回答”）。
- **回答**：交互块照常“提交中 → 服务端结果”（4.2，不乐观显示）。回答显示在**卡片上**（选中的选项打勾、“已确认”、文字回答显示为卡片里的一行“你的回答：……”），**不**在对话里多出一条用户气泡。
- **继续**：收到继续之后的事件，新内容接在这条消息下面出现（不是新的一条消息），过程条那一行回到运行中；滚动规则与生成中相同（用户在底部时跟随）。
- **输入框**：有一个暂停中的中断、当前查看者可以回答时，输入框**锁定**；用户点卡片上的“输入其他内容”后输入框解锁并挂上“回答：<问题>”标签，发出的文字是这张卡的回答（经 `ActionTransport`），不是新消息。完整契约见 4.5。
- **通知**：暂停时宿主可以发一条“需要你确认”的通知，文字取 `message.paused.fallbackText`；库只提供回调，不发通知。
- **最终回答里带着问题**（消息已经结束，例如“要我给‘交水费’设个提醒吗？”）不是暂停：用户的回答是一条新消息，AI 的回复是新的一条。

### 4.5 输入框联动（Composer 契约）

消息暂停等一个中断时，输入框要配合，让用户清楚“现在打的字算什么”。这是库级的界面契约（[D61](decisions.md)）：状态和动作由 `chatweave_core` 的 `InterruptComposerController` 管理（按会话一个，纯本地显示状态，不进协议），`ChatWeaveComposer` 默认实现全部行为；宿主用自己的输入框时接同一个控制器。

**状态**

| 状态 | 何时 | 输入框 | 交互块 |
|---|---|---|---|
| `free` | 没有开着的中断；或当前查看者不能回答（只读、没有 `ActionTransport`、宿主判定不能答）；或锁定策略为 `never` | 照常发新消息 | — |
| `locked` | 会话里有一条 `paused` 的消息，中断的块仍是 `open`，当前查看者可以回答 | **锁定**：发不出普通消息，附件等入口也禁用；显示提示（默认“先回答上面的问题”）；已有草稿保留不清空；点锁定的输入框 = 滚动到中断的块并提示“其他内容”入口，不弹键盘 | 可操作；`otherInput` 不为 `false` 时带“输入其他内容” |
| `answering` | 用户点了“输入其他内容”（`beginOtherInput()`） | **解锁**并聚焦；上方挂“回答”标签 `InterruptAnswerChip`：“回答：<问题>”+ ✕；发出的文字是这个中断的 `freeText` 回答，不是消息；只收文字，附件仍禁用 | 照常可点；点了卡上的控件就按控件回答，标签消失 |
| `submitting` | 文字回答已提交、服务端结果还没到（含离线排队） | 锁定；标签显示“提交中…”或“已排队，联网后提交”；提交的文字留在控制器里 | “提交中 / 已排队”（4.2） |

**转换**

- `free → locked`：中断出现（流里的 `message.paused`、快照、活动消息列表或同步下来的暂停检查点）。草稿不清空。
- `locked → answering`：`beginOtherInput()`；`otherInput: false` 时卡上没有入口，调用无效。
- `answering → locked`：点标签上的 ✕（`cancelOtherInput()`），已经打的字保留，下次进入 `answering` 时还在。
- `answering → submitting`：`submitOtherInput(text)`：生成 `{freeText}` 动作（动作 ID 规则同 [protocol.md 5.1](protocol.md#51-三个对象)，重发复用同一个 ID），经 `ActionTransport` 提交。文字为空或超过 500 字符时不提交。
- `submitting →`：`accepted`（带 `resume`）→ `free`，清空草稿；服务端明确拒绝且块仍 `open`（`invalid_payload`、`conflict` 等）→ 回到 `answering`，文字放回输入框，标签下显示服务端的 `message`；`unavailable` 或超时 → 保持 `submitting`，刷新块状态、用同一个 ID 重试。
- **中断在别处被关闭**（另一台设备已回答、过期、停止、块变成 `cancelled` / `superseded`）：任何状态 → `free`，控制器给出 `closedReason`（`answered_elsewhere` / `expired` / `stopped` / `withdrawn`）；草稿留在输入框里变回普通草稿，宿主据此提示一句，免得用户把它当成回答发出去。
- 消息继续（`message.resumed`）后按生成中的普通规则处理。最终回答里带着问题（消息已经结束）**不**进入 `locked`。

多条消息同时暂停时，默认选择创建时间最近的消息；时间相同按消息 ID 降序。接入方可用 `selectInterrupt` 钩子选择。

**宿主接线（草图，未编译；Flutter 类型由 Flutter 层适配）**

```dart
final composer = InterruptComposerController(
  store: blockStore,
  interactions: interactionController,
  conversationId: conversationId,
  lockPolicy: ComposerLockPolicy.answerers,
)..attachDraft(myDraftPort); // DraftPort 与状态流属于 Core；TextEditingController 由 Flutter 层适配。

StreamBuilder<InterruptComposerState>(
  stream: composer.changes,
  initialData: composer.state,
  builder: (context, snapshot) {
    final state = snapshot.data!;
    return MyComposer(
      locked: state.mode == ComposerMode.locked || state.mode == ComposerMode.submitting,
      onTapLocked: composer.revealInterrupt,
      onSend: state.mode == ComposerMode.answering
          ? composer.submitOtherInput
          : sendMessage,
    );
  },
);
```

- 标签里的问题取块的 `choice.prompt` / `confirmation.title` / `form_intent.title`（没有时 `purpose`），单行省略。
- 外观：`answerChipBuilder`、`lockedComposerBuilder` 可换成宿主皮肤；文案经宿主本地化，库自带中文、英文默认值（“输入其他内容”“先回答上面的问题”“回答：”）。
- **锁定策略**：`answerers`（默认：只锁能回答这个中断的人；一对一会话就是那位用户；群聊里其他成员照常聊天）/ `everyone` / `never`（宿主自己处理，此时“输入其他内容”仍会进入 `answering`）。服务端对“中断开着时到达的新消息”的处理见 [protocol.md 4.8](protocol.md#48-中断暂停与继续同一条消息) 第 16 条。
- **无障碍**：锁定时输入框语义为“已锁定”并读出提示；进入 `answering` 时焦点移到输入框，读出“正在回答：<问题>”；✕ 的语义标签是“取消回答，返回选项”；状态变化礼貌播报一次。

## 5. 主题接口

### 5.1 设计

宿主把自己的设计系统“翻译”成一个 `ChatWeaveThemeData`，库的所有默认组件只从这里取样式。主题是**语义令牌**，不是组件参数：

```dart
@immutable
class ChatWeaveThemeData {
  final Brightness brightness;            // 允许宿主提供深色主题；库不强制
  final ChatWeaveColors colors;           // surface, surfaceVariant, onSurface, onSurfaceMuted, outline, accent, onAccent
  final ChatWeaveStatusColors status;     // positive / negative / warning / critical / neutral / info，各含 fg / bg / icon
  final List<Color> chartPalette;         // 序列颜色，按序列顺序取；宿主需保证与背景对比度
  final ChatWeaveTextStyles text;         // body, bodyStrong, caption, title, numeric（大数字）, numericSmall, code
  final ChatWeaveSpacing spacing;         // xs / s / m / l / xl
  final ChatWeaveShapes shapes;           // 卡片、按钮、输入框的圆角与描边宽度
  final ChatWeaveMotion motion;           // 出现 / 尺寸变化 的时长与曲线；系统“减少动态效果”时库自动置 0
  final ChatWeaveIcons icons;             // 状态图标、箭头、展开等，宿主可替换成自己的图标
  final BlockFrameBuilder? blockFrame;    // 可选：给每个组件块套统一的外框（例如宿主的“纸片”卡片）
  final MessageFrameBuilder? messageFrame;// 可选：助手消息 / 用户消息的外框
}
```

- 默认文案由 `ChatWeaveLocalizations(locale: "zh" / "en", resolve: …, child: …)` 注入；`resolve(key, fallback)` 可覆盖库文案，协议正文、字段标签与服务端错误保持原文。
- 通过 `ChatWeaveTheme(data: …, child: …)`（`InheritedWidget`）注入；`ChatWeaveTheme.of(context)` 读取。
- 库自带两套中性默认主题 `ChatWeaveThemeData.neutralLight()` / `neutralDark()`，用于示例 App 与 golden 测试。宿主可以只实现浅色主题（例如宿主 v1 不做深色模式），系统切到深色时继续使用浅色主题即可。
- `blockFrame` 让宿主不必重写每个组件，就能给所有组件统一“换外壳”；需要更深的定制时用注册表 `override` 替换单个组件。
- 主题不暴露给生产方：服务端和模型永远看不到主题，也无法影响它。

### 5.2 语义映射

| 语义 | 主题来源 | 同时必须有的非颜色线索 |
|---|---|---|
| `assessment.status = positive / negative / warning / critical / info / neutral` | `status.*` | 图标 + 文字标签（`assessment.label` 或默认词） |
| `delta.direction = up / down / flat` | 中性色（方向本身不代表好坏）；好坏看 `delta.assessment` | 箭头 + 带符号的数值 |
| `confirmation.severity = destructive` | `status.critical` | 按钮文字说明后果 + 二次确认 |
| 图表序列 | `chartPalette[i]` | 图例文字；序列 ≥ 3 时线型也区分（实线 / 虚线 / 点线） |

## 6. 无障碍

- **读屏**：每个组件提供完整语义描述。指标读作“最高气温 18 摄氏度，较昨天上升 3，适合出门”；表格按“表头：值”逐行可读；图表提供包含全部关键数值的文字摘要（默认用 `fallbackText`，并可切换到表格视图）。装饰元素对读屏隐藏。
- **过程条**：收起时是一个按钮，读作“过程：查了 3 项，用时 4 秒，已收起，双击展开”，并带展开 / 收起的语义状态；展开后每行读作“查北京本周天气，完成，0.8 秒”或“查上海本周天气，没有完成，天气服务暂时不可用”，状态不只靠图标和颜色表达。委派步骤读作“交给天气助手对比两城天气，运行中，包含 2 步，已收起”；子步骤读出层级（“第 2 层”）。步骤开始和完成不逐条播报；消息暂停等用户时礼貌播报一次（“需要你确认：删除待办”）；继续时不播报；消息结束时的播报里带上一句摘要。整行可点区域 ≥ 48 逻辑像素高。
- **流式播报**：不逐 token 播报。块结束时（或整条消息结束时）用一次“礼貌”级别的实时区域播报新内容摘要；用户正在用读屏浏览时不打断。
- **触控**：可点区域 ≥ 48×48 逻辑像素（选项按钮、确认按钮、表格展开等）。
- **字号**：支持系统字体放大到 200%；指标网格自动减列，表格允许内部横向滚动，金额与数值允许换行而不截断。
- **颜色不单独承载信息**：见 5.2 的“非颜色线索”列；主题实现方须保证正文对比度 ≥ 4.5:1、大字 ≥ 3:1（库提供对比度检查的测试工具函数）。
- **减少动态效果**：读取 `MediaQuery.disableAnimationsOf(context)`，为真时所有过渡时长为 0，骨架占位不做闪烁动画。
- **焦点与键盘**：表单字段有正确的标签与错误提示关联；提交失败时焦点移到第一个出错字段。

## 7. 测试

- **组件测试**：每个默认组件 × 正常 / 边界（最长标签、最多行、空数据）/ 降级 / 交互状态（open、提交中、已排队、resolved（这台设备答 / 另一台设备或群聊里别人先答 / 用户取消）、expired、cancelled（带原因）、superseded、只读）；生成中的消息 × 临时进度提示 / 正在停止；过程条 × 运行中 / 全部完成 / 有失败 / 暂停等你确认 / 回答后继续并完成（行尾显示回答）/ 暂停中停止 / 中断过期 / 子 Agent 收起与展开（含 3 层）/ 子 Agent 里的中断（委派行显示“等你确认”）/ 生成中停止 / 手动展开后不再自动收起 / 历史消息默认收起 / 最长标签 / 200% 字号；暂停中的消息 × 输入框 `locked` / `answering`（带标签）/ ✕ 返回且草稿保留 / `submitting`（在线、已排队）/ 被拒绝后放回文字 / 被另一台设备回答后回到 `free` / `otherInput: false` 时卡上没有入口 / 已结束消息里的问题不锁定；`InterruptComposerController` 的状态转换用纯 Dart 单元测试逐条覆盖。
- **golden 截图**（把界面渲染成图片与基准图逐像素比对）：在包内测试舞台（示例 App 在 T10 复用）中，每个组件 × 中性浅色 / 深色主题 × 两种宽度（360、430）× 100% / 200% 字号；固定 Noto Sans CJK SC Regular 子集与工具链生成；测试加载前校验 manifest 中的 SHA-256，CI 检查新文案缺字。库运行时默认字体不变。
- **流式测试**：用一致性夹具驱动 `BlockStore`，断言每一步的组件树与最终 `fold` 结果；断言块类型在 `block.start` 后不变、已渲染的文字不会被替换成组件。
- **无障碍测试**：`meetsGuideline(androidTapTargetGuideline)`、`textContrastGuideline`、语义树快照。

## 8. 调试面板（只读）

`chatweave_flutter` 提供一个可选的 `ChatWeaveDebugOverlay`，帮助宿主开发者排查“为什么这条消息没续上 / 为什么这个块降级了”：

- **严格只读**：只调用 `chatweave_core` 的 `inspect()` 拿快照，不写状态、不发请求、不碰宿主存储；打开或关闭它不会改变任何行为。
- **内容**：`BlockStore.inspect()` 汇总 `diagnostics.resume`（触发原因、轮数、阶段、已应用游标、错误码）与 `diagnostics.actions`（阶段、幂等键、错误码）；诊断元数据使用白名单，不接收 payload 或错误正文。每条消息的已应用 `seq`、`rev`、状态；块列表与各自的降级原因；续传状态（上次触发原因、结果、轮数）；进行中 / 已排队的动作与幂等键；最近 N 个（默认 50）`apply` 事件的环形缓冲，可按消息过滤。
- **导出**：一键复制成 JSON 方便贴进问题报告，**默认去掉正文文本和块数据**，只保留 ID、类型、序号、状态和错误码；宿主显式允许时才包含内容。
- **不进生产包**：宿主决定在哪些构建里启用以及怎么打开（例如只在调试构建里，用构建期常量控制，release 构建会被 tree-shake 掉）。库本身不提供任何默认的打开方式。
