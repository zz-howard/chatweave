import 'components.dart';
import 'default_boundary.dart';
import 'localizations.dart';
import 'markdown.dart';
import 'package:chatweave_core/chatweave_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'theme.dart';

typedef BlockWidgetBuilder = Widget Function(BuildContext, Block);
typedef BlockRenderError = void Function(Block, Object);

class BlockRegistration {
  const BlockRegistration(
      {required this.build,
      this.parse,
      this.when,
      this.placeholder,
      this.fallback,
      this.maxSchemaVersion = 1});
  final BlockWidgetBuilder build;
  final void Function(Json)? parse;
  final bool Function(Block)? when;
  final BlockWidgetBuilder? placeholder;
  final Block? Function(Block)? fallback;
  final int maxSchemaVersion;
}

class BlockRegistry {
  BlockRegistry._(this.onBlockRenderError);
  factory BlockRegistry.markdownOnly({BlockRenderError? onBlockRenderError}) {
    final registry = BlockRegistry._(onBlockRenderError);
    registry._entries['markdown'] = [
      BlockRegistration(
          build: (_, b) => MarkdownBlockView(
              text: b.data['text'] as String,
              complete: b['status'] != 'pending'))
    ];
    return registry;
  }
  factory BlockRegistry.withDefaults({BlockRenderError? onBlockRenderError}) {
    final registry =
        BlockRegistry.markdownOnly(onBlockRenderError: onBlockRenderError);
    for (final type in builtinTypes.where((t) => t != 'markdown')) {
      registry._entries[type] = [
        BlockRegistration(
            parse: (_) {},
            placeholder: (_, b) => BlockSkeleton(type: b.type),
            build: (context, b) {
              final scope = InteractionScope.of(context);
              return BuiltinBlockView(
                  block: b,
                  interactions: scope?.interactions,
                  messageId: scope?.messageId,
                  composer: scope?.composer,
                  readOnly: scope?.readOnly ?? false);
            })
      ];
    }
    return registry;
  }
  final BlockRenderError? onBlockRenderError;
  final _entries = <String, List<BlockRegistration>>{};
  final _reported = <String>{};
  void register(String type, BlockRegistration registration) {
    if (builtinTypes.contains(type))
      throw ArgumentError('Use override for built-in types');
    _entries.putIfAbsent(type, () => []).add(registration);
  }

  void override(String type, BlockRegistration registration) {
    _entries[type] = [registration];
  }

  void report(Block block, Object error) {
    if (_reported.add('${block.id}/${block.type}'))
      onBlockRenderError?.call(block, error);
  }

  ClientCapabilities capabilities({String locale = 'zh-CN'}) =>
      ClientCapabilities.fromJson({
        'protocolVersions': ['0.1'],
        'blocks': {
          for (final e in _entries.entries)
            e.key: e.value.first.maxSchemaVersion
        },
        'features': [
          'stream.resume',
          'stream.snapshot',
          'stream.activity',
          'stream.steps',
          if (_entries.containsKey('markdown')) 'markdown.tables',
          if (_entries.containsKey('choice')) 'action.choice',
          if (_entries.containsKey('confirmation')) 'action.confirmation',
          if (_entries.containsKey('form_intent')) 'action.form'
        ],
        'locale': locale
      });
  Widget render(Block block,
          {InteractionController? interactions,
          String? messageId,
          InterruptComposerController? composer,
          bool readOnly = false}) =>
      InteractionScope(
          interactions: interactions,
          messageId: messageId,
          composer: composer,
          readOnly: readOnly,
          child: _BlockBoundary(
              key: ValueKey('${block.id}/${block.type}'),
              registry: this,
              block: block));

  Widget build(BuildContext context, Block block,
      [Set<String> visited = const {}]) {
    if (visited.contains(block.type)) return FallbackNote(block: block);
    try {
      if (block['status'] == 'error') throw const ProtocolError('block_error');
      final registration = _entries[block.type]
          ?.where((r) => r.when?.call(block) ?? true)
          .firstOrNull;
      if (registration == null ||
          (block['schemaVersion'] as int) > registration.maxSchemaVersion) {
        throw const ProtocolError('unsupported_type_or_version');
      }
      if (block['status'] == 'pending' && !block.json.containsKey('data')) {
        return registration.placeholder?.call(context, block) ??
            BlockSkeleton(type: block.type);
      }
      validateBlock(block.json);
      registration.parse?.call(block.data);
      return registration.build(context, block);
    } catch (error) {
      report(block, error);
      final registration = _entries[block.type]?.firstOrNull;
      try {
        final converted = registration?.fallback?.call(block) ??
            fallbackConversion(block, context);
        if (converted != null && _entries.containsKey(converted.type)) {
          return build(context, converted, {...visited, block.type});
        }
      } catch (fallbackError) {
        report(block, fallbackError);
      }
      return FallbackNote(block: block);
    }
  }
}

Block? fallbackConversion(Block b, [BuildContext? context]) {
  String say(String key) => context == null ? key : cw(context, key);
  if (b.type == 'time_series') {
    final series = objects(b.data['series']);
    return Block.fromJson({
      ...b.json,
      'type': 'dataset',
      'data': {
        'columns': [
          {'key': 'series', 'label': say('序列'), 'type': 'string'},
          {'key': 'x', 'label': say('时间'), 'type': 'string'},
          {'key': 'y', 'label': b.data['yUnit'] ?? say('数值'), 'type': 'number'}
        ],
        'rows': [
          for (final s in series)
            for (final p in objects(s['points']))
              {'series': s['label'], 'x': p['x'], 'y': p['y']}
        ],
      }
    });
  }
  if (b.type == 'comparison') {
    final subjects = objects(b.data['subjects']);
    final attributes = objects(b.data['attributes']);
    final values = objects(b.data['values']);
    return Block.fromJson({
      ...b.json,
      'type': 'dataset',
      'data': {
        'columns': [
          {'key': 'attribute', 'label': say('项目'), 'type': 'string'},
          for (final s in subjects)
            {'key': s['id'], 'label': s['label'], 'type': 'string'}
        ],
        'rows': [
          for (final a in attributes)
            {
              'attribute': a['label'],
              for (final s in subjects)
                s['id'] as String: values
                    .where((v) =>
                        v['subject'] == s['id'] && v['attribute'] == a['key'])
                    .firstOrNull?['value']
            }
        ],
      }
    });
  }
  if (b.type == 'breakdown') {
    return Block.fromJson({
      ...b.json,
      'type': 'dataset',
      'data': {
        'columns': [
          {'key': 'label', 'label': say('类别'), 'type': 'string'},
          {
            'key': 'value',
            'label': b.data['unit'] ?? say('数值'),
            'type': 'number'
          }
        ],
        'rows': [
          for (final p in objects(b.data['parts']))
            {'label': p['label'], 'value': p['value']}
        ],
      }
    });
  }
  if (b.type == 'category_series') {
    return Block.fromJson({
      ...b.json,
      'type': 'dataset',
      'data': {
        'columns': [
          {
            'key': 'label',
            'label': b.data['xLabel'] ?? say('类别'),
            'type': 'string'
          },
          {
            'key': 'value',
            'label': b.data['unit'] ?? say('数值'),
            'type': 'number'
          }
        ],
        'rows': [
          for (final p in objects(b.data['points']))
            {'label': p['label'], 'value': p['value']}
        ],
      }
    });
  }
  if (b.type == 'metric_group') {
    return Block.fromJson({
      ...b.json,
      'type': 'markdown',
      'data': {
        'text': objects(b.data['metrics'])
            .map((m) =>
                '${m['label']}: ${m['value'] ?? say('暂无数据')} ${m['unit'] ?? ''}')
            .join('\n'),
      }
    });
  }
  return null;
}

class FallbackNote extends StatelessWidget {
  const FallbackNote({super.key, required this.block});
  final Block block;
  @override
  Widget build(BuildContext context) {
    final theme = ChatWeaveTheme.of(context);
    final raw = block['fallbackText'];
    final text = raw is String ? raw : null;
    return Padding(
        padding: EdgeInsets.all(theme.spacing),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text == null || text.isEmpty ? cw(context, '此内容无法显示') : text,
              style: theme.body.copyWith(color: theme.onSurface)),
          DefaultLabel('更新 App 可查看完整内容',
              style: theme.caption.copyWith(color: theme.muted)),
        ]));
  }
}

class _BlockBoundary extends StatefulWidget {
  const _BlockBoundary(
      {super.key, required this.registry, required this.block});
  final BlockRegistry registry;
  final Block block;
  @override
  State<_BlockBoundary> createState() => _BlockBoundaryState();
}

class _BlockBoundaryState extends State<_BlockBoundary> {
  bool failed = false;
  void fail(Object error) {
    widget.registry.report(widget.block, error);
    if (failed) return;
    failed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) => failed
      ? FallbackNote(block: widget.block)
      : DefaultBuildScope(
          fallback: () => FallbackNote(block: widget.block),
          report: fail,
          child: Builder(
              builder: (context) => _RenderGuard(
                  onError: fail,
                  child: widget.registry.build(context, widget.block))));
}

/// Flutter catches render errors internally, so observe its synchronous reporting
/// while this subtree is laid out or painted and always restore the prior hook.
class _RenderGuard extends SingleChildRenderObjectWidget {
  const _RenderGuard({required this.onError, required super.child});
  final void Function(Object) onError;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _GuardRenderBox(onError);
  @override
  void updateRenderObject(BuildContext context, _GuardRenderBox renderObject) {
    renderObject.onError = onError;
  }
}

class _GuardRenderBox extends RenderProxyBox {
  _GuardRenderBox(this.onError);
  void Function(Object) onError;
  bool _failed = false;
  void guard(VoidCallback work) {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      _failed = true;
      onError(details.exception);
    };
    try {
      work();
    } catch (error) {
      _failed = true;
      onError(error);
    } finally {
      FlutterError.onError = previous;
    }
  }

  @override
  void performLayout() {
    guard(() {
      super.performLayout();
    });
    if (!hasSize) size = constraints.constrain(const Size(0, 48));
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (!_failed) super.visitChildrenForSemantics(visitor);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_failed)
      guard(() {
        super.paint(context, offset);
      });
  }
}

class InteractionScope extends InheritedWidget {
  const InteractionScope(
      {super.key,
      this.interactions,
      this.messageId,
      this.composer,
      this.readOnly = false,
      required super.child});
  final InteractionController? interactions;
  final String? messageId;
  final InterruptComposerController? composer;
  final bool readOnly;
  static InteractionScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InteractionScope>();
  @override
  bool updateShouldNotify(InteractionScope oldWidget) =>
      interactions != oldWidget.interactions ||
      messageId != oldWidget.messageId ||
      composer != oldWidget.composer ||
      readOnly != oldWidget.readOnly;
}
