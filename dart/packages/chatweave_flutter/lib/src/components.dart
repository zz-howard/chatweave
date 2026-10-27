import 'dart:math' as math;

import 'default_boundary.dart';
import 'localizations.dart';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

String formatValue(
  Object? value, {
  Json format = const {},
  BuildContext? context,
}) {
  String say(String key) => context == null ? key : cw(context, key);
  if (value == null) return say('暂无数据');
  if (value is bool) return say(value ? '是' : '否');
  if (value is! num) return value.toString();
  final digits = format['maximumFractionDigits'] as int? ?? 1;
  return switch (format['style']) {
    'percent' => '${(value * 100).toStringAsFixed(digits)}%',
    'integer' => value.round().toString(),
    'currency' =>
      '${format['currency'] ?? ''} ${(format['minorUnits'] == true ? value / 100 : value).toStringAsFixed(2)}',
    'duration' => '$value ${say('秒')}',
    _ => value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(digits),
  };
}

class BlockSkeleton extends StatelessWidget {
  const BlockSkeleton({super.key, required this.type});
  final String type;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) => Semantics(
        label: cw(context, '内容正在生成'),
        child: SizedBox(
          height: type == 'time_series' ? 180 : 96,
          child: const Center(child: DefaultLabel('正在生成…')),
        ),
      );
}

class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) {
    final theme = ChatWeaveTheme.of(context);
    final assessment = object(data['assessment'] ?? <String, Object?>{});
    final delta = object(data['delta'] ?? <String, Object?>{});
    final value = formatValue(
      data['value'],
      format: object(data['format'] ?? <String, Object?>{}),
      context: context,
    );
    return Padding(
      padding: EdgeInsets.all(theme.spacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${data['label']}', style: theme.body),
          Text('$value ${data['unit'] ?? ''}', style: theme.numeric),
          if (delta.isNotEmpty)
            Text(
              '${delta['direction'] == 'up' ? '↑' : delta['direction'] == 'down' ? '↓' : '→'} ${delta['value']} ${delta['period'] ?? ''}',
            ),
          if (assessment.isNotEmpty)
            Text(
              '● ${assessment['label'] ?? assessment['status']}',
              style: theme.caption,
            ),
          if (data['note'] != null)
            Text('${data['note']}', style: theme.caption),
        ],
      ),
    );
  }
}

class MetricGrid extends StatelessWidget {
  const MetricGrid({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => guardedDefaultBuild(context, () {
          final single = constraints.maxWidth < 400 ||
              MediaQuery.textScalerOf(context).scale(16) > 20;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (data['title'] != null)
                Text('${data['title']}',
                    style: ChatWeaveTheme.of(context).title),
              Wrap(
                children: [
                  for (final metric in objects(data['metrics']))
                    SizedBox(
                      width: single
                          ? constraints.maxWidth
                          : constraints.maxWidth / 2,
                      child: MetricTile(data: metric),
                    ),
                ],
              ),
              if (data['summary'] != null) Text('${data['summary']}'),
            ],
          );
        }),
      );
}

class DataTableView extends StatelessWidget {
  const DataTableView({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) {
    final columns = objects(data['columns']);
    final rows = objects(data['rows']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data['title'] != null)
          Text('${data['title']}', style: ChatWeaveTheme.of(context).title),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: columns.length * 180.0,
            child: Table(
              defaultColumnWidth: const FixedColumnWidth(180),
              border: TableBorder.all(
                color: ChatWeaveTheme.of(context).outline,
              ),
              children: [
                TableRow(
                  children: [
                    for (final col in columns)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Semantics(
                          header: true,
                          child: Text(
                            '${col['label']}',
                            softWrap: true,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
                for (final row in rows)
                  TableRow(
                    children: [
                      for (final col in columns)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Semantics(
                            label:
                                '${col['label']}: ${formatValue(row[col['key']], context: context)}',
                            excludeSemantics: true,
                            child: Text(
                              formatValue(row[col['key']], context: context),
                              softWrap: true,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        if (rows.isEmpty) const DefaultLabel('暂无数据'),
        if ((data['totalRows'] as int? ?? rows.length) > rows.length)
          Text(
            '${cw(context, '显示')} ${rows.length} / ${cw(context, '共')} ${data['totalRows']} ${cw(context, '条')}',
          ),
      ],
    );
  }
}

class ComparisonTable extends StatelessWidget {
  const ComparisonTable({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) {
    final subjects = objects(data['subjects']);
    final values = objects(data['values']);
    return DataTableView(
      data: {
        'title': data['title'],
        'columns': [
          {'key': 'attribute', 'label': cw(context, '项目')},
          for (final s in subjects) {'key': s['id'], 'label': s['label']},
        ],
        'rows': [
          for (final a in objects(data['attributes']))
            {
              'attribute': a['label'],
              for (final s in subjects)
                s['id'] as String: values
                    .where(
                      (v) =>
                          v['subject'] == s['id'] && v['attribute'] == a['key'],
                    )
                    .firstOrNull?['value'],
            },
        ],
      },
    );
  }
}

class LineChartView extends StatefulWidget {
  const LineChartView({super.key, required this.data, required this.summary});
  final Json data;
  final String summary;
  @override
  State<LineChartView> createState() => _LineChartViewState();
}

class _LineChartViewState extends State<LineChartView> {
  bool table = false;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) {
    final series = objects(widget.data['series']);
    final palette = ChatWeaveTheme.of(context).chartPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.data['title'] != null) Text('${widget.data['title']}'),
        if (!table)
          Semantics(
            label: widget.summary,
            child: ExcludeSemantics(
              child: SizedBox(
                height: 180,
                width: double.infinity,
                child: CustomPaint(painter: _LinePainter(series, palette)),
              ),
            ),
          ),
        Wrap(
          spacing: 12,
          children: [
            for (var i = 0; i < series.length; i++)
              Text(
                '${i + 1}. ${series[i]['label']}',
                style: TextStyle(color: palette[i % palette.length]),
              ),
          ],
        ),
        ChatWeaveTextButton(
          onPressed: () => setState(() {
            table = !table;
          }),
          child: DefaultLabel(table ? '查看图表' : '查看数据表'),
        ),
        if (table)
          DataTableView(
            data: {
              'columns': [
                {'key': 'series', 'label': cw(context, '序列')},
                {'key': 'x', 'label': cw(context, '时间')},
                {'key': 'y', 'label': cw(context, '数值')},
              ],
              'rows': [
                for (final s in series)
                  for (final p in objects(s['points']))
                    {'series': s['label'], 'x': p['x'], 'y': p['y']},
              ],
            },
          ),
      ],
    );
  }
}

({double low, double high}) lineChartRange(List<double> values) {
  if (values.isEmpty) return (low: -0.01, high: 0.01);
  var low = values.reduce(math.min);
  var high = values.reduce(math.max);
  if (high == low) {
    final padding = math.max(low.abs() * 0.05, 0.01);
    low -= padding;
    high += padding;
  }
  return (low: low, high: high);
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.series, this.palette);
  final List<Json> series;
  final List<Color> palette;
  @override
  void paint(Canvas canvas, Size size) {
    final values = [
      for (final s in series)
        for (final p in objects(s['points']))
          if (p['y'] is num) (p['y'] as num).toDouble(),
    ];
    if (values.isEmpty) return;
    final range = lineChartRange(values);
    final low = range.low;
    final high = range.high;
    for (var i = 0; i < series.length; i++) {
      final points = objects(series[i]['points']);
      Offset? previous;
      final paint = Paint()
        ..color = palette[i % palette.length]
        ..strokeWidth = 2;
      for (var n = 0; n < points.length; n++) {
        if (points[n]['y'] is! num) {
          previous = null;
          continue;
        }
        final y = (points[n]['y'] as num).toDouble();
        final point = Offset(
          8 + n * (size.width - 16) / math.max(1, points.length - 1),
          size.height - 8 - (y - low) / (high - low) * (size.height - 16),
        );
        if (previous != null) {
          if (i < 2) {
            canvas.drawLine(previous, point, paint);
          } else {
            final distance = (point - previous).distance;
            for (var d = 0.0; d < distance; d += 8) {
              canvas.drawLine(
                Offset.lerp(previous, point, d / distance)!,
                Offset.lerp(
                  previous,
                  point,
                  math.min(d + 4, distance) / distance,
                )!,
                paint,
              );
            }
          }
        }
        canvas.drawCircle(point, 3, paint);
        previous = point;
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter oldDelegate) =>
      oldDelegate.series != series || oldDelegate.palette != palette;
}

class StatusView extends StatelessWidget {
  const StatusView({super.key, required this.data});
  final Json data;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${data['label']} · ${stateLabel(data['state'], context)}'),
          if (data['progress'] is Map<Object?, Object?>)
            Text(
              '${object(data['progress'])['current']} / ${object(data['progress'])['total']} ${object(data['progress'])['unit'] ?? ''}',
              style: ChatWeaveTheme.of(context)
                  .body
                  .copyWith(
                      color: ChatWeaveTheme.of(context).onSurface,
                      fontWeight: FontWeight.w600),
            ),
          for (final step in objects(data['steps']))
            Text('${step['label']} · ${stateLabel(step['state'], context)}'),
        ],
      );
}

String stateLabel(Object? state, [BuildContext? context]) {
  final label = switch (state) {
    'running' => '运行中',
    'pending' || 'waiting' => '等待中',
    'awaiting_user' => '等你回答',
    'succeeded' || 'complete' => '完成',
    'failed' || 'error' => '没有完成',
    'cancelled' || 'interrupted' => '已停止',
    _ => '$state',
  };
  return context == null ? label : cw(context, label);
}

String interactionSummary(Block block, [BuildContext? context]) {
  String say(String key) => context == null ? key : cw(context, key);
  try {
    validateBlock(block.json);
  } catch (_) {
    final fallback = block['fallbackText'];
    return fallback is String ? fallback : say('此内容无法显示');
  }
  final state = object(block.data['state'] ?? <String, Object?>{});
  final reason = object(state['reason'] ?? <String, Object?>{});
  return switch (state['status'] ?? 'open') {
    'open' => '',
    'resolved' => state['freeText'] != null
        ? '${say('你的回答：')}${state['freeText']}'
        : state['outcome'] == 'cancel'
            ? say('你已取消')
            : state['outcome'] == 'confirm'
                ? say('你已确认')
                : state['selected'] != null
                    ? '${say('已回答：')}${(state['selected'] as List<Object?>).map((id) => objects(block.data['options']).where((o) => o['id'] == id).firstOrNull?['label'] ?? id).join('、')}'
                    : '${say('已提交：')}${state['values']}',
    'cancelled' => reason['text'] != null
        ? '${say('已作废 · ')}${reason['text']}'
        : reason['code'] == 'stopped'
            ? say('已停止，没有等到回答')
            : '${say('已作废 · ')}${switch (reason['code']) {
                'record_deleted' => say('相关记录已被删除'),
                'record_changed' => say('相关记录已变化'),
                'permission_changed' => say('权限已变化'),
                _ => say('请求已撤回'),
              }}',
    'expired' => say('已过期'),
    'superseded' => say('已被新的请求取代'),
    _ => '',
  };
}

class BuiltinBlockView extends StatelessWidget {
  const BuiltinBlockView({
    super.key,
    required this.block,
    this.interactions,
    this.messageId,
    this.composer,
    this.readOnly = false,
  });
  final Block block;
  final InteractionController? interactions;
  final String? messageId;
  final InterruptComposerController? composer;
  final bool readOnly;
  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) => switch (block.type) {
        'metric' => MetricTile(data: block.data),
        'metric_group' => MetricGrid(data: block.data),
        'dataset' => DataTableView(data: block.data),
        'time_series' => LineChartView(
            data: block.data,
            summary: block['fallbackText'] as String? ?? '',
          ),
        'comparison' => ComparisonTable(data: block.data),
        'status' => StatusView(data: block.data),
        'choice' || 'confirmation' || 'form_intent' => InteractionBlockView(
            block: block,
            interactions: interactions,
            messageId: messageId,
            composer: composer,
            readOnly: readOnly,
          ),
        _ => Text(block['fallbackText'] as String? ?? cw(context, '此内容无法显示')),
      };
}

class InteractionBlockView extends StatefulWidget {
  const InteractionBlockView({
    super.key,
    required this.block,
    this.interactions,
    this.messageId,
    this.composer,
    this.readOnly = false,
  });
  final Block block;
  final InteractionController? interactions;
  final String? messageId;
  final InterruptComposerController? composer;
  final bool readOnly;
  @override
  State<InteractionBlockView> createState() => _InteractionBlockViewState();
}

class _InteractionBlockViewState extends State<InteractionBlockView> {
  final _form = GlobalKey<FormState>();
  final _values = <String, Object?>{};
  final _selected = <String>{};
  bool _armed = false;
  final _focusNodes = <String, FocusNode>{};
  InteractionState? _lastErrors;
  FocusNode _focusFor(String key) =>
      _focusNodes.putIfAbsent(key, () => FocusNode(debugLabel: key));
  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      guardedDefaultBuild(context, () => buildDefault(context));

  Widget buildDefault(BuildContext context) => StreamBuilder<void>(
        stream: widget.interactions?.changes,
        builder: (context, _) => guardedDefaultBuild(context, () {
          final b = widget.block;
          final local =
              widget.interactions?.stateFor(widget.messageId ?? '', b.id) ??
                  const InteractionState();
          if (!identical(local, _lastErrors) && local.fieldErrors.isNotEmpty) {
            _lastErrors = local;
            final first = objects(b.data['fields'])
                .where((f) => local.fieldErrors.containsKey(f['key']))
                .firstOrNull;
            if (first != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _focusFor(first['key'] as String).requestFocus();
              });
            }
          }
          final open =
              (object(b.data['state'] ?? <String, Object?>{})['status'] ??
                      'open') ==
                  'open';
          final enabled = open &&
              !local.locked &&
              !widget.readOnly &&
              widget.interactions?.transport != null;
          final children = <Widget>[
            Text(
              '${b.data['prompt'] ?? b.data['title'] ?? ''}',
              style: ChatWeaveTheme.of(context).title,
            ),
            if (b.data['body'] != null) Text('${b.data['body']}'),
            if (!open) Text(interactionSummary(b, context)),
            if (!open && object(b.data['state'])['resolvedBy'] != null)
              Text(
                '${cw(context, '回答者：')}${object(b.data['state'])['resolvedBy']}',
              ),
            if (!open && object(b.data['state'])['resolvedAt'] != null)
              Text('${object(b.data['state'])['resolvedAt']}'),
            if (local.locked && open)
              DefaultLabel(switch (local.phase) {
                InteractionPhase.queued => '已排队，联网后提交',
                InteractionPhase.confirming => '暂时无法确认结果，正在刷新…',
                InteractionPhase.retryable => '暂时无法确认结果，请重试',
                _ => '提交中…',
              }),
            if (local.error != null) Text(local.error!),
            if (open &&
                local.phase == InteractionPhase.retryable &&
                !widget.readOnly)
              ChatWeaveTextButton(
                onPressed: () =>
                    widget.interactions?.retry(widget.messageId!, b.id),
                child: const DefaultLabel('重试'),
              ),
            if (widget.readOnly || widget.interactions?.transport == null)
              const DefaultLabel('仅可查看'),
          ];
          Future<void> submit(Json payload) async {
            await widget.interactions?.submit(
              widget.messageId!,
              b.id,
              payload,
              canAnswer: !widget.readOnly,
            );
          }

          if (b.type == 'choice') {
            children.add(
              Wrap(
                spacing: 8,
                children: [
                  for (final option in objects(b.data['options']))
                    ChatWeaveTextButton(
                      onPressed: enabled
                          ? () {
                              if (b.data['selection'] == 'multiple') {
                                setState(() {
                                  final id = option['id'] as String;
                                  if (!_selected.add(id)) _selected.remove(id);
                                });
                              } else {
                                submit({
                                  'selected': [option['id']],
                                });
                              }
                            }
                          : null,
                      child: Text('${option['label']}'),
                    ),
                ],
              ),
            );
            if (b.data['selection'] == 'multiple') {
              children.add(
                ChatWeaveTextButton(
                  onPressed: enabled && _selected.isNotEmpty
                      ? () => submit({'selected': _selected.toList()})
                      : null,
                  child: const DefaultLabel('提交'),
                ),
              );
            }
          } else if (b.type == 'confirmation') {
            for (final detail in objects(b.data['details'])) {
              children.add(
                Text(
                  '${detail['label']}: '
                  '${formatValue(detail['value'], context: context, format: object(detail['format'] ?? <String, Object?>{}))}'
                  ' ${detail['unit'] ?? ''}',
                ),
              );
            }
            children.add(
              Wrap(
                spacing: 8,
                children: [
                  ChatWeaveTextButton(
                    onPressed: enabled
                        ? () {
                            if (b.data['severity'] == 'destructive' &&
                                !_armed) {
                              setState(() {
                                _armed = true;
                              });
                              return;
                            }
                            submit({'outcome': 'confirm'});
                          }
                        : null,
                    child: Text(
                      _armed
                          ? '${cw(context, '再次确认：')}${b.data['confirmLabel'] ?? cw(context, '确认')}'
                          : '${b.data['confirmLabel'] ?? cw(context, '确认')}',
                    ),
                  ),
                  ChatWeaveTextButton(
                    onPressed:
                        enabled ? () => submit({'outcome': 'cancel'}) : null,
                    child:
                        Text('${b.data['cancelLabel'] ?? cw(context, '取消')}'),
                  ),
                ],
              ),
            );
          } else {
            children.add(
              Form(
                key: _form,
                child: Column(
                  children: [
                    for (final field in objects(b.data['fields']))
                      _field(field, enabled, local),
                    ChatWeaveTextButton(
                      onPressed: enabled
                          ? () {
                              if (_form.currentState!.validate()) {
                                _form.currentState!.save();
                                submit({'values': _values});
                              }
                            }
                          : null,
                      child:
                          Text('${b.data['submitLabel'] ?? cw(context, '提交')}'),
                    ),
                  ],
                ),
              ),
            );
          }
          final composer = widget.composer;
          if (open &&
              composer?.state.block?.id == b.id &&
              object(composer!.state.message!['interrupt'])['otherInput'] !=
                  false) {
            children.add(
              ChatWeaveTextButton(
                onPressed: enabled ? composer.beginOtherInput : null,
                child: const DefaultLabel('输入其他内容'),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          );
        }),
      );

  Widget _field(Json field, bool enabled, InteractionState local) {
    final key = field['key'] as String;
    if (field.containsKey('defaultValue'))
      _values.putIfAbsent(key, () => field['defaultValue']);
    if (field['type'] == 'multi_select') {
      return Focus(
        focusNode: _focusFor(key),
        child: FormField<List<String>>(
          initialValue: (_values[key] as List<Object?>? ?? []).cast<String>(),
          validator: (value) =>
              field['required'] == true && (value == null || value.isEmpty)
                  ? cw(context, '请选择')
                  : null,
          onSaved: (value) {
            _values[key] = value;
          },
          builder: (state) => guardedDefaultBuild(
            context,
            () => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${field['label']}'),
                for (final option in objects(field['options']))
                  CheckboxListTile(
                    title: Text('${option['label']}'),
                    value: state.value?.contains(option['id']) ?? false,
                    onChanged: enabled
                        ? (checked) {
                            final values = [...?state.value];
                            if (checked == true) {
                              values.add(option['id'] as String);
                            } else {
                              values.remove(option['id']);
                            }
                            state.didChange(values);
                          }
                        : null,
                  ),
                if (state.errorText != null)
                  Text(state.errorText!,
                      style: TextStyle(
                          color: ChatWeaveTheme.of(context).critical)),
              ],
            ),
          ),
        ),
      );
    }
    if (field['type'] == 'boolean') {
      _values.putIfAbsent(key, () => false);
      return CheckboxListTile(
        focusNode: _focusFor(key),
        value: _values[key] as bool? ?? field['defaultValue'] as bool? ?? false,
        onChanged: enabled
            ? (v) => setState(() {
                  _values[key] = v;
                })
            : null,
        title: Text('${field['label']}'),
        controlAffinity: ListTileControlAffinity.leading,
      );
    }
    if (field['type'] == 'single_select') {
      return DropdownButtonFormField<String>(
        focusNode: _focusFor(key),
        decoration: InputDecoration(
            labelText: '${field['label']}',
            errorStyle: TextStyle(color: ChatWeaveTheme.of(context).critical)),
        items: [
          for (final o in objects(field['options']))
            DropdownMenuItem(
              value: o['id'] as String,
              child: Text('${o['label']}'),
            ),
        ],
        onChanged: enabled
            ? (v) {
                _values[key] = v;
              }
            : null,
        validator: (v) =>
            field['required'] == true && v == null ? cw(context, '请选择') : null,
      );
    }
    return TextFormField(
      focusNode: _focusFor(key),
      enabled: enabled,
      initialValue: '${field['defaultValue'] ?? ''}',
      decoration: InputDecoration(
        labelText: '${field['label']}',
        helperText: field['help'] as String?,
        errorStyle: TextStyle(
            color: ChatWeaveTheme.of(context).critical,
            fontSize: 14,
            fontWeight: FontWeight.w600),
        errorText: local.fieldErrors[key] as String?,
      ),
      maxLines: field['type'] == 'multiline_text' ? null : 1,
      validator: (v) {
        final value = v ?? '';
        if (field['required'] == true && value.trim().isEmpty)
          return cw(context, '请填写');
        if (field['maxLength'] is int &&
            value.runes.length > (field['maxLength'] as int))
          return cw(context, '文字太长');
        if (const ['number', 'integer'].contains(field['type']) &&
            value.isNotEmpty) {
          final number = num.tryParse(value);
          if (number == null ||
              (field['type'] == 'integer' && number != number.roundToDouble()))
            return cw(context, '请输入有效数字');
          if (field['min'] is num && number < (field['min'] as num))
            return cw(context, '数值太小');
          if (field['max'] is num && number > (field['max'] as num))
            return cw(context, '数值太大');
        }
        if (const ['date', 'datetime'].contains(field['type']) &&
            value.isNotEmpty &&
            DateTime.tryParse(value) == null) return cw(context, '请输入有效日期');
        return null;
      },
      onSaved: (v) {
        _values[key] = const ['number', 'integer'].contains(field['type'])
            ? num.tryParse(v ?? '')
            : v;
      },
    );
  }
}

class ChoiceView extends BuiltinBlockView {
  const ChoiceView({
    super.key,
    required super.block,
    super.interactions,
    super.messageId,
    super.composer,
    super.readOnly,
  });
}

class ConfirmationCard extends BuiltinBlockView {
  const ConfirmationCard({
    super.key,
    required super.block,
    super.interactions,
    super.messageId,
    super.composer,
    super.readOnly,
  });
}

class IntentForm extends BuiltinBlockView {
  const IntentForm({
    super.key,
    required super.block,
    super.interactions,
    super.messageId,
    super.composer,
    super.readOnly,
  });
}
