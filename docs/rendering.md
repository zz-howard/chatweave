# 渲染（草案）

> **状态：草案。** 本文描述 `chatweave_flutter` 的组件注册表、降级规则、主题接口、Markdown 安全子集和无障碍要求。协议层的降级顺序见 [protocol.md 第 6 节](protocol.md#6-降级规则任何时候都能只看文本)。

## 1. 原则

- **渲染器是确定性的**：同样的消息、同样的主题，画出来永远一样；不依赖模型才能工作。
- **颜色表达语义，由主题决定**：块里没有颜色和尺寸；`assessment.status` 之类的语义字段由主题映射成颜色、图标和文字标签。
- **克制**：组件只做“把数据读清楚”这一件事，不做花哨动效，不为了展示 UI 而展示 UI。
- **失败只影响一个块**：任何组件构建出错，都只把这个块换成兜底文本，整条消息照常显示。
- **结果以服务端为准**：交互块不乐观显示结果，点按之后只显示“提交中”，服务端确认后才显示结果。

## 2. 组件注册表（BlockRegistry）

注册表是一张“块类型 → 组件构建器”的表：

```dart
final registry = BlockRegistry.withDefaults()          // 内置 10 种类型的默认组件
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
| `status` | `StatusView` | 状态图标 + 文字；有 `progress` 显示进度条；有 `steps` 显示步骤列表 |
| `choice` | `ChoiceView` | 选项按钮组；单选 / 多选；`allowFreeText` 时提示“也可以直接输入回答”（文字回答作为普通消息从输入框发出）；点按后整组显示“提交中”；`state` 非 `open` 时显示**服务端记录的**选项、回答者与时间，并禁用 |
| `confirmation` | `ConfirmationCard` | 标题、说明、细节表；破坏性操作的确认按钮用主题的“危险”样式，且必须二次点按（或按住）才能提交；点按后显示“提交中”，服务端确认后才显示“已确认 / 已取消” |
| `form_intent` | `IntentForm` | 按字段类型生成输入控件；客户端先做必填 / 范围 / 长度校验；服务端返回的 `fieldErrors` 显示在对应字段下 |

默认组件只用 Flutter `widgets` 层能力和主题接口取样式，不依赖 Material 的颜色或文字主题（Markdown 渲染依赖的 `flutter_markdown_plus` 内部用到 Material，样式表仍完全由主题接口提供）。

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

- 单块文本上限 32 KB（协议限制）；超长时截断并提示。
- 解析在每批 delta 后只对“活动尾部”进行（[streaming.md 第 7 节](streaming.md#7-布局稳定避免界面跳动)）。
- 文本可选择、可复制；复制时得到原始 Markdown 去除标记后的纯文本。
- 代码块与行内代码里的内容一律原样显示，不解释其中的任何语法或链接。
- 库提供 `plainTextSummary(message, maxChars)`：去掉 Markdown 标记、组件块用 `fallbackText`，供宿主做通知、会话列表预览、搜索摘要，保证各处的“纯文本版本”一致。

## 4. 降级规则（客户端实现）

对每个块：

0. **每个块单独包一层错误边界**：组件在 `parse`、`build` 或之后的布局 / 绘制中抛出异常，只影响这个块——它原地换成自己的 `fallbackText`，同一条消息里的其他块照常显示。通过宿主注入的 `onBlockRenderError` 上报，**每个块 ID + 类型只上报一次**（列表反复重建不会刷屏）。
1. 注册了该类型、`schemaVersion` 不超过支持版本、`parse` 成功、`build` 不抛异常 → 正常组件。
2. 否则沿 `fallback` 链尝试下一个类型（内置链：`time_series → dataset`、`comparison → dataset`、`metric_group → metric 列表`）。
3. 否则显示 `FallbackNote`：块的 `fallbackText`（中性样式，带一个小提示“更新 App 可查看完整内容”，读屏读出文字本身）。
4. `fallbackText` 也没有 → “此内容无法显示”。

每次降级通过宿主注入的回调上报一次（类型、版本、原因），库本身不做任何遥测、不联网。

**Markdown-only 模式**：`BlockRegistry.markdownOnly()` 只保留 markdown，其他全部走 `fallbackText`。用于排障开关、极简宿主，或作为发布时的应急降级。

### 4.1 生成中的消息

生成中的消息不显示复制、转发等操作栏，结束后才出现（[streaming.md 第 6 节](streaming.md#6-中断与不完整的块)）；被停止或出错时保留已出现的内容，并在末尾标“已停止”或错误说明。

### 4.2 交互块的显示状态

交互块的显示由两部分决定：服务端写的 `state`（[protocol.md 3.4](protocol.md#34-交互块的状态choice--confirmation--form_intent)），加上 `InteractionController` 里的本地显示状态。

| 本地 / 服务端状态 | 显示 | 控件 |
|---|---|---|
| `open`，未操作 | 正常 | 可用 |
| `open`，提交中 | 被点的按钮显示进度指示，整个块显示“提交中…”；**不把选项画成已选中** | 全部禁用，防止双击或改选 |
| `open`，已排队（离线） | “已排队，联网后提交” | 禁用 |
| `open`，服务端明确拒绝（`invalid_payload`、`forbidden`、`conflict` 等） | 回到未操作状态，并在块内显示服务端给的 `message`（表单显示 `fieldErrors`） | 可用（重新操作会生成新幂等键） |
| `open`，`unavailable` 或客户端超时 | “暂时无法确认结果，正在刷新…”；**不说“失败”**，因为动作可能已经执行 | 禁用，直到刷新到服务端状态；重试复用同一幂等键 |
| `resolved` | 服务端记录的答案（选中的选项 / 已确认或已取消 / 表单值摘要）+ 回答者与时间（宿主把 `resolvedBy` 解析成显示名）。如果答案来自别人，照实显示别人的答案 | 禁用 |
| `expired` / `cancelled` / `superseded` | “已过期” / “已取消” / “已被新的请求取代” | 禁用 |
| 没有 `ActionTransport`、会话只读，或宿主判定当前查看者不能回答 | 内容与状态照常显示，附一行简短说明（例如“仅可查看”） | 禁用；**不会**改为把选项文字作为消息发出 |

文案原则：只有服务端明确拒绝时才用“没能完成”这类说法；结果未知时只说“正在确认”。

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
- **流式播报**：不逐 token 播报。块结束时（或整条消息结束时）用一次“礼貌”级别的实时区域播报新内容摘要；用户正在用读屏浏览时不打断。
- **触控**：可点区域 ≥ 48×48 逻辑像素（选项按钮、确认按钮、表格展开等）。
- **字号**：支持系统字体放大到 200%；指标网格自动减列，表格允许内部横向滚动，金额与数值允许换行而不截断。
- **颜色不单独承载信息**：见 5.2 的“非颜色线索”列；主题实现方须保证正文对比度 ≥ 4.5:1、大字 ≥ 3:1（库提供对比度检查的测试工具函数）。
- **减少动态效果**：读取 `MediaQuery.disableAnimationsOf(context)`，为真时所有过渡时长为 0，骨架占位不做闪烁动画。
- **焦点与键盘**：表单字段有正确的标签与错误提示关联；提交失败时焦点移到第一个出错字段。

## 7. 测试

- **组件测试**：每个默认组件 × 正常 / 边界（最长标签、最多行、空数据）/ 降级 / 交互状态（open、提交中、已排队、resolved（自己答 / 别人先答）、expired、superseded、只读）。
- **golden 截图**（把界面渲染成图片与基准图逐像素比对）：在示例 App 中，每个组件 × 中性浅色 / 深色主题 × 两种宽度（360、430）× 100% / 200% 字号；固定字体与工具链生成。
- **流式测试**：用一致性夹具驱动 `BlockStore`，断言每一步的组件树与最终 `fold` 结果；断言块类型在 `block.start` 后不变、已渲染的文字不会被替换成组件。
- **无障碍测试**：`meetsGuideline(androidTapTargetGuideline)`、`textContrastGuideline`、语义树快照。

## 8. 调试面板（只读）

`chatweave_flutter` 提供一个可选的 `ChatWeaveDebugOverlay`，帮助宿主开发者排查“为什么这条消息没续上 / 为什么这个块降级了”：

- **严格只读**：只调用 `chatweave_core` 的 `inspect()` 拿快照，不写状态、不发请求、不碰宿主存储；打开或关闭它不会改变任何行为。
- **内容**：每条消息的已应用 `seq`、`rev`、状态；块列表与各自的降级原因；续传状态（上次触发原因、结果、轮数）；进行中 / 已排队的动作与幂等键；最近 N 个（默认 50）`apply` 事件的环形缓冲，可按消息过滤。
- **导出**：一键复制成 JSON 方便贴进问题报告，**默认去掉正文文本和块数据**，只保留 ID、类型、序号、状态和错误码；宿主显式允许时才包含内容。
- **不进生产包**：宿主决定在哪些构建里启用以及怎么打开（例如只在调试构建里，用构建期常量控制，release 构建会被 tree-shake 掉）。库本身不提供任何默认的打开方式。
