import 'dart:convert';
import 'dart:io';

import 'package:chatweave_core/testing.dart';
import 'package:chatweave_flutter/chatweave_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flutter_test_config.dart' as test_fonts;

class Stage {
  const Stage(
    this.component,
    this.state,
    this.build, {
    this.main = false,
    this.sensitive = false,
  });
  final String component;
  final String state;
  final Widget Function() build;
  final bool main;
  final bool sensitive;
}

Block fixture(String type) {
  final json = object(
    jsonDecode(
      File('../../../fixtures/conformance/blocks/$type-valid.json')
          .readAsStringSync(),
    ),
  );
  if (type == 'time_series') {
    final data = object(json['data']);
    final series = objects(data['series']);
    return Block.fromJson({
      ...json,
      'data': {
        ...data,
        'series': [
          {
            ...series.first,
            'points': [
              {'x': '2026-10-26', 'y': 18},
              {'x': '2026-10-27', 'y': 21},
              {'x': '2026-10-28', 'y': 19},
            ],
          },
        ],
      },
    });
  }
  return Block.fromJson(json);
}

Message message({String status = 'complete', List<Json> steps = const []}) =>
    Message.fromJson({
      'id': 'weather',
      'conversationId': 'weather_todo',
      'protocolVersion': '0.1',
      'role': 'assistant',
      'status': status,
      'rev': const ['streaming', 'paused'].contains(status) ? 0 : 1,
      'createdAt': '2026-10-26T09:30:00Z',
      if (!const ['streaming', 'paused'].contains(status))
        'completedAt': '2026-10-26T09:30:04Z',
      'fallbackText': '天气晴朗，记得浇花。',
      'blocks': [
        {...fixture('markdown').json, 'id': 'text'},
        {...fixture('metric').json, 'id': 'metric'},
        if (status == 'paused' || steps.any((s) => s['blockId'] == 'card'))
          {...fixture('confirmation').json, 'id': 'card'},
      ],
      if (status == 'paused') 'lastSeq': 6,
      if (status == 'paused')
        'interrupt': {
          'id': 'interrupt',
          'stepId': 's1',
          'blockId': 'card',
          'reason': 'confirmation',
        },
      'steps': steps.isEmpty && status == 'paused'
          ? [
              {
                'id': 's1',
                'label': '删除待办',
                'state': 'awaiting_user',
                'blockId': 'card',
              },
            ]
          : steps,
    });

List<Stage> stages() {
  final stages = <Stage>[];
  for (final type in builtinTypes.toList()..sort()) {
    final b = fixture(type);
    Widget render(Block block) => BlockRegistry.withDefaults().render(block);
    stages.add(
      Stage(
        type,
        'normal',
        () => const {'choice', 'confirmation', 'form_intent'}.contains(type)
            ? _InteractiveStage(type, 'open')
            : render(b),
        main: true,
      ),
    );
    stages.add(Stage(type, 'skeleton', () => BlockSkeleton(type: type)));
    stages.add(Stage(type, 'fallback', () => FallbackNote(block: b)));
    stages.add(
      Stage(
        type,
        'long_label',
        () {
          final data = {...b.data};
          for (final key in ['label', 'title', 'prompt']) {
            if (data.containsKey(key)) data[key] = '天气与待办的最长标签需要完整阅读' * 5;
          }
          return render(Block.fromJson({...b.json, 'data': data}));
        },
        sensitive: const {
          'metric',
          'dataset',
          'comparison',
          'form_intent',
        }.contains(type),
      ),
    );
  }
  for (final type in ['choice', 'confirmation', 'form_intent']) {
    final b = fixture(type);
    for (final local in ['submitting', 'queued', 'confirming', 'rejected']) {
      stages.add(Stage(type, local, () => _InteractiveStage(type, local)));
    }
    for (final state in [
      'resolved_self',
      'resolved_other',
      'user_cancel',
      'free_text',
      'expired',
      'cancelled',
      'stopped',
      'superseded',
      'readonly',
    ].where((state) => state != 'user_cancel' || type == 'confirmation')) {
      stages.add(
        Stage(type, state, () {
          final resolved = state.startsWith('resolved') ||
              state == 'user_cancel' ||
              state == 'free_text';
          final serverState = <String, Object?>{
            'status': resolved
                ? 'resolved'
                : state == 'readonly'
                    ? 'open'
                    : state == 'stopped'
                        ? 'cancelled'
                        : state,
            if (resolved) 'resolvedAt': '2026-10-26T09:31:00Z',
            if (state == 'resolved_other') 'resolvedBy': 'member_7',
            if (state == 'cancelled' || state == 'stopped')
              'reason': {
                'code': state == 'stopped' ? 'stopped' : 'record_deleted',
                if (state == 'cancelled') 'text': '待办记录已删除',
              },
            if (state == 'superseded') 'supersededBy': 'new_card',
          };
          if (state == 'free_text') {
            serverState['freeText'] = '先保留这条待办';
          } else if (resolved) {
            serverState[type == 'choice'
                ? 'selected'
                : type == 'confirmation'
                    ? 'outcome'
                    : 'values'] = type == 'choice'
                ? ['bj']
                : type == 'confirmation'
                    ? (state == 'user_cancel' ? 'cancel' : 'confirm')
                    : {'title': '浇花'};
          }
          return BuiltinBlockView(
            block: Block.fromJson({
              ...b.json,
              'data': {...b.data, 'state': serverState},
            }),
            readOnly: state == 'readonly',
          );
        }),
      );
    }
  }
  for (final state in [
    'running',
    'succeeded',
    'failed',
    'awaiting_user',
    'cancelled',
  ]) {
    stages.add(
      Stage(
        'process_strip',
        state,
        () => ProcessStrip(
          message: message(
            status: state == 'running'
                ? 'streaming'
                : state == 'awaiting_user'
                    ? 'paused'
                    : 'complete',
            steps: [
              {
                'id': 's1',
                'label': '查天气并读取待办',
                'state': state,
                if (state == 'awaiting_user') 'blockId': 'card',
                if (state != 'running' && state != 'awaiting_user')
                  'durationMs': 850,
              },
            ],
          ),
          state: ProcessState()..setExpanded('weather', true),
        ),
        main: state == 'running',
      ),
    );
  }
  stages.add(
    Stage(
      'process_strip',
      'nested',
      () => ProcessStrip(
        message: message(
          status: 'streaming',
          steps: [
            {
              'id': 's1',
              'label': '对比两城天气',
              'kind': 'delegate',
              'state': 'running',
            },
            {
              'id': 's2',
              'parentStepId': 's1',
              'label': '读取北京天气',
              'kind': 'delegate',
              'state': 'running',
            },
            {
              'id': 's3',
              'parentStepId': 's2',
              'label': '读取气温',
              'state': 'running',
            },
          ],
        ),
        state: ProcessState()
          ..setExpanded('weather', true, stepId: 's1')
          ..setExpanded('weather', true, stepId: 's2'),
      ),
      sensitive: true,
    ),
  );
  for (final state in [
    'complete',
    'streaming',
    'paused',
    'interrupted',
    'error',
  ]) {
    stages.add(
      Stage(
        'message_view',
        state,
        () => MessageView(
          message: message(status: state),
          registry: BlockRegistry.withDefaults(),
          processState: ProcessState(),
          onStop: () {},
          activity: const {'label': '正在查天气…'},
        ),
        main: state == 'complete',
      ),
    );
  }
  for (final mode in [
    'free',
    'locked',
    'answering',
    'submitting',
    'queued',
    'other_input_false',
    'rejected',
    'expired',
    'stopped',
    'withdrawn',
    'answered_elsewhere',
  ]) {
    stages.add(
      Stage('composer', mode, () => _ComposerStage(mode), main: mode == 'free'),
    );
  }
  for (final type in builtinTypes.toList()..sort()) {
    stages.add(
      Stage(
        type,
        'maximum_data',
        () {
          final b = fixture(type);
          final maximum = boundary(b, maximum: true);
          validateBlock(maximum.json);
          return SizedBox(
            height: 600,
            child: SingleChildScrollView(
              child: BlockRegistry.withDefaults().render(maximum),
            ),
          );
        },
        sensitive: const [
          'dataset',
          'comparison',
          'form_intent',
        ].contains(type),
      ),
    );
  }
  for (final type in [
    'markdown',
    'metric',
    'dataset',
    'time_series',
    'comparison',
  ]) {
    stages.add(
      Stage(
        type,
        'legal_empty',
        () => BlockRegistry.withDefaults().render(boundary(fixture(type))),
      ),
    );
  }
  for (final state in [
    'history',
    'manual_expanded',
    'resumed_complete',
    'paused_stopped',
    'interrupt_expired',
    'child_interrupt',
    'nested_collapsed',
    'long_label',
  ]) {
    stages.add(
      Stage('process_strip', state, () {
        final nested =
            state == 'child_interrupt' || state == 'nested_collapsed';
        final paused = state == 'child_interrupt';
        final m = message(
          status: paused
              ? 'paused'
              : state == 'paused_stopped'
                  ? 'interrupted'
                  : 'complete',
          steps: [
            if (nested)
              {
                'id': 'parent',
                'label': '对比天气',
                'kind': 'delegate',
                'state': paused ? 'running' : 'succeeded',
              },
            {
              'id': 's1',
              'label': state == 'long_label' ? '天气与待办' * 20 : '删除待办',
              if (nested) 'parentStepId': 'parent',
              'state': paused
                  ? 'awaiting_user'
                  : state == 'interrupt_expired' || state == 'paused_stopped'
                      ? 'cancelled'
                      : 'succeeded',
              if (paused || state == 'resumed_complete') 'blockId': 'card',
              'summary': state == 'resumed_complete' ? '你已确认' : '',
            },
          ],
        );
        final display = ProcessState();
        if (!const ['history', 'nested_collapsed'].contains(state)) {
          display.setExpanded(m.id, true);
        }
        if (paused) display.setExpanded(m.id, true, stepId: 'parent');
        return ProcessStrip(message: m, state: display);
      }, sensitive: state == 'child_interrupt' || state == 'long_label'),
    );
  }
  for (final state in ['all_field_types', 'required_and_limits']) {
    stages.add(
      Stage('form_intent', state, () {
        final b = fixture('form_intent');
        return BuiltinBlockView(
          block: Block.fromJson({
            ...b.json,
            'data': {
              ...b.data,
              'fields': [
                for (final type in [
                  'text',
                  'multiline_text',
                  'number',
                  'integer',
                  'date',
                  'datetime',
                  'boolean',
                  'single_select',
                  'multi_select',
                ])
                  {
                    'key': type,
                    'label': '待办 $type',
                    'type': type,
                    'required': true,
                    if (type == 'number' || type == 'integer') ...{
                      'min': 0,
                      'max': 100,
                    },
                    if (type.endsWith('text')) 'maxLength': 2000,
                    if (type.endsWith('select'))
                      'options': [
                        {'id': 'water', 'label': '浇花'},
                        {'id': 'weather', 'label': '查天气'},
                      ],
                  },
              ],
            },
          }),
        );
      }, sensitive: true),
    );
  }
  stages.add(
    Stage('time_series', 'maximum_points', () {
      final b = fixture('time_series');
      final maximum = Block.fromJson({
        ...b.json,
        'data': {
          ...b.data,
          'xType': 'number',
          'series': [
            {
              'key': 'weather',
              'label': '天气',
              'points': [
                for (var j = 0; j < 500; j++) {'x': j, 'y': j % 20},
              ],
            },
          ],
        },
      });
      validateBlock(maximum.json);
      return BlockRegistry.withDefaults().render(maximum);
    }),
  );
  stages.add(
    Stage(
      'form_intent',
      'field_error',
      () => const _InteractiveStage('form_intent', 'field_error'),
      sensitive: true,
    ),
  );
  stages.add(
    Stage('choice', 'multiple_selection', () {
      final b = fixture('choice');
      return BuiltinBlockView(
        block: Block.fromJson({
          ...b.json,
          'data': {
            ...b.data,
            'selection': 'multiple',
            'minSelect': 1,
            'maxSelect': 2,
          },
        }),
      );
    }),
  );
  stages.add(
    Stage(
      'message_view',
      'stop_requested',
      () => MessageView(
        message: message(status: 'streaming'),
        registry: BlockRegistry.withDefaults(),
        processState: ProcessState(),
        onStop: () {},
        stopRequested: true,
      ),
    ),
  );
  return stages;
}

void main() {
  final all = stages();
  for (final stage in all) {
    for (final dark in [false, true]) {
      for (final width in [360, 430]) {
        for (final scale in [1.0, 2.0]) {
          final name =
              '${stage.component}_${stage.state}_${dark ? 'dark' : 'light'}_${width}_${(scale * 100).round()}';
          final golden = stage.main ||
              (!dark && width == 360 && (scale == 1 || stage.sensitive));
          testWidgets(name, (tester) async {
            tester.view.physicalSize = Size(width.toDouble(), 1800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final theme = test_fonts.testFontTheme(dark);
            final semantics = tester.ensureSemantics();
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(
                    fontFamily: 'ChatWeaveTestSans',
                    brightness: theme.brightness,
                    textButtonTheme: TextButtonThemeData(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        foregroundColor: theme.accent,
                      ),
                    ),
                  ),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width.toDouble(), 1800),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: Scaffold(
                      backgroundColor: theme.surface,
                      body: ChatWeaveTheme(
                        data: theme,
                        child: SingleChildScrollView(
                          child: RepaintBoundary(
                            key: const ValueKey('stage'),
                            child: Container(
                              width: width.toDouble(),
                              color: theme.surface,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: DefaultTextStyle(
                                  style: theme.body.copyWith(
                                    color: theme.onSurface,
                                  ),
                                  child: stage.build(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull, reason: name);
              expect(materialIconFontUses(tester), isEmpty,
                  reason: '$name renders a MaterialIcons glyph');
              await expectLater(
                tester,
                meetsGuideline(androidTapTargetGuideline),
              );
              await expectLater(
                tester,
                meetsGuideline(labeledTapTargetGuideline),
              );
              await expectLater(tester, meetsGuideline(textContrastGuideline));
              expect(
                tester.getSize(find.byKey(const ValueKey('stage'))).width,
                width.toDouble(),
              );
              if (golden) {
                await expectLater(
                  find.byKey(const ValueKey('stage')),
                  matchesGoldenFile('goldens/$name.png'),
                );
              }
            } finally {
              semantics.dispose();
            }
          });
        }
      }
    }
  }
  test('golden_inventory_is_bounded', () {
    final count = all.fold<int>(
      0,
      (sum, s) =>
          sum +
          (s.main
              ? 8
              : s.sensitive
                  ? 2
                  : 1),
    );
    expect(count, lessThanOrEqualTo(300));
    expect(count, 256);
  });
}

class _ComposerStage extends StatefulWidget {
  const _ComposerStage(this.mode);
  final String mode;
  @override
  State<_ComposerStage> createState() => _ComposerStageState();
}

class _ComposerStageState extends State<_ComposerStage> {
  final store = BlockStore();
  final persistence = MemoryStore();
  final draft = TextEditingController(text: '记得浇花');
  late final InteractionController interactions;
  late final InterruptComposerController composer;
  @override
  void initState() {
    super.initState();
    final b = fixture('choice');
    if (widget.mode != 'free')
      store.apply(
        SyncMessage(
          Message.fromJson({
            ...message().json,
            'status': 'paused',
            'rev': 0,
            'lastSeq': 5,
            'blocks': [b.json],
            'steps': [
              {
                'id': 'ask',
                'label': '选择城市',
                'state': 'awaiting_user',
                'blockId': b.id,
              },
            ],
            'interrupt': {
              'id': 'interrupt',
              'stepId': 'ask',
              'blockId': b.id,
              'reason': 'input_required',
              'otherInput': widget.mode != 'other_input_false',
            },
          }),
        ),
      );
    interactions = _StageInteractions(store, persistence, widget.mode);
    composer = InterruptComposerController(
      store: store,
      interactions: interactions,
      conversationId: 'weather_todo',
    );
    if (widget.mode == 'answering' || widget.mode == 'rejected') {
      composer.beginOtherInput();
    }
    if (const [
      'expired',
      'stopped',
      'withdrawn',
      'answered_elsewhere',
    ].contains(widget.mode)) {
      final old = store.snapshot.messages['weather']!;
      store.apply(
        SyncMessage(
          Message.fromJson(
            {
              ...old.json,
              'status': widget.mode == 'answered_elsewhere'
                  ? 'complete'
                  : 'interrupted',
              'rev': 1,
              'steps': [
                {
                  ...old.steps.single.json,
                  'state': widget.mode == 'answered_elsewhere'
                      ? 'succeeded'
                      : 'cancelled',
                  'durationMs': 0,
                },
              ],
              'blocks': [
                {
                  ...b.json,
                  'data': {
                    ...b.data,
                    'state': {
                      'status': widget.mode == 'expired'
                          ? 'expired'
                          : widget.mode == 'answered_elsewhere'
                              ? 'resolved'
                              : 'cancelled',
                      if (widget.mode == 'answered_elsewhere') ...{
                        'resolvedAt': '2026-10-26T09:31:00Z',
                        'selected': [objects(b.data['options']).first['id']],
                      },
                      if (widget.mode == 'stopped')
                        'reason': {'code': 'stopped'},
                      if (widget.mode == 'withdrawn')
                        'reason': {'code': 'withdrawn'},
                    },
                  },
                },
              ],
            }
              ..remove('interrupt')
              ..remove('lastSeq'),
          ),
        ),
      );
      validateMessage(store.snapshot.messages['weather']!.json);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ChatWeaveComposer(controller: composer, draft: draft, onSend: (_) {});
  @override
  void dispose() {
    composer.dispose();
    interactions.dispose();
    store.dispose();
    persistence.dispose();
    draft.dispose();
    super.dispose();
  }
}

/// Golden state injection avoids timers/network while using the real widgets.
class _StageInteractions extends InteractionController {
  _StageInteractions(BlockStore store, MemoryStore persistence, this.mode)
      : super(
          store: store,
          persistence: persistence,
          nextId: () => 'intent',
          transport: ScriptedTransport(connections: []),
        );
  final String mode;
  @override
  InteractionState stateFor(String messageId, String blockId) =>
      InteractionState(
        phase: switch (mode) {
          'submitting' => InteractionPhase.submitting,
          'queued' => InteractionPhase.queued,
          'confirming' => InteractionPhase.retryable,
          'rejected' || 'field_error' => InteractionPhase.rejected,
          _ => InteractionPhase.idle,
        },
        error: mode == 'rejected' ? '待办记录已变化，请重新选择' : null,
        fieldErrors: mode == 'field_error' ? {'title': '请修改事项'} : const {},
      );
}

class _InteractiveStage extends StatefulWidget {
  const _InteractiveStage(this.type, this.mode);
  final String type;
  final String mode;
  @override
  State<_InteractiveStage> createState() => _InteractiveStageState();
}

class _InteractiveStageState extends State<_InteractiveStage> {
  final store = BlockStore();
  final persistence = MemoryStore();
  late final InteractionController interactions;
  @override
  void initState() {
    super.initState();
    store.apply(
      SyncMessage(
        Message.fromJson({
          ...message().json,
          'blocks': [fixture(widget.type).json],
        }),
      ),
    );
    interactions = _StageInteractions(store, persistence, widget.mode);
  }

  @override
  Widget build(BuildContext context) => BuiltinBlockView(
        block: fixture(widget.type),
        messageId: 'weather',
        interactions: interactions,
      );
  @override
  void dispose() {
    interactions.dispose();
    persistence.dispose();
    store.dispose();
    super.dispose();
  }
}

Block boundary(Block b, {bool maximum = false}) {
  final data = {...b.data};
  if (maximum) {
    for (final key in ['label', 'title']) {
      if (data.containsKey(key)) data[key] = '天气与待办' * 24;
    }
    if (data.containsKey('prompt')) data['prompt'] = '天气与待办' * 400;
  }
  switch (b.type) {
    case 'markdown':
      data['text'] = maximum ? 'weather ' * 4096 : '';
    case 'metric':
      data['value'] = maximum ? '9' * 64 : null;
    case 'metric_group':
      data['metrics'] = [
        for (var i = 0; i < 12; i++)
          {...fixture('metric').data, 'label': '天气 $i'},
      ];
    case 'dataset':
      data['totalRows'] = maximum ? 200 : 0;
      data.remove('sort');
      if (maximum)
        data['columns'] = [
          for (var i = 0; i < 12; i++)
            {'key': 'weather_$i', 'label': '天气 $i', 'type': 'number'},
        ];
      data['rows'] = maximum
          ? [
              for (var i = 0; i < 200; i++)
                {
                  for (final c in objects(data['columns']))
                    c['key'] as String: null,
                },
            ]
          : [];
    case 'time_series':
      data['series'] = [
        for (var i = 0; i < (maximum ? 6 : 1); i++)
          {
            'key': 'weather_$i',
            'label': '天气 $i',
            'points': maximum
                ? [
                    for (var j = 0; j < 250; j++) {'x': j, 'y': j % 20},
                  ]
                : <Object?>[],
          },
      ];
      data['xType'] = 'number';
    case 'comparison':
      if (maximum) {
        data['subjects'] = [
          for (var i = 0; i < 6; i++) {'id': 'city_$i', 'label': '城市 $i'},
        ];
        data['attributes'] = [
          for (var i = 0; i < 12; i++) {'key': 'weather_$i', 'label': '天气 $i'},
        ];
      }
      data['values'] = maximum
          ? [
              for (final subject in objects(data['subjects']))
                for (final attr in objects(data['attributes']))
                  {
                    'subject': subject['id'],
                    'attribute': attr['key'],
                    'value': 9999999,
                  },
            ]
          : [];
    case 'breakdown':
      // The fixture total no longer matches twelve replaced parts.
      data.remove('total');
      data['parts'] = [
        for (var i = 0; i < 12; i++)
          {
            'key': 'weather_$i',
            'label': maximum ? '天气与待办' * 24 : '天气 $i',
            'value': maximum ? 9999999 - i : i + 1,
          },
      ];
    case 'category_series':
      data['points'] = [
        for (var i = 0; i < 24; i++)
          {
            'key': 'weather_$i',
            'label': maximum ? '天气与待办' * 24 : '天气 $i',
            'value': maximum ? (i.isEven ? 9999999 : -9999999) : i,
          },
      ];
    case 'status':
      data['steps'] = [
        for (var i = 0; i < 12; i++) {'label': '待办 $i', 'state': 'succeeded'},
      ];
    case 'choice':
      data['options'] = [
        for (var i = 0; i < 10; i++) {'id': 'weather_$i', 'label': '查天气 $i'},
      ];
    case 'confirmation':
      data['body'] = '删除无法恢复，请确认' * 200;
      data['details'] = [
        for (var i = 0; i < 12; i++) {'label': '待办 $i', 'value': '浇花'},
      ];
    case 'form_intent':
      data['fields'] = [
        for (var i = 0; i < 12; i++)
          {
            'key': 'todo_$i',
            'type': 'text',
            'label': '待办 $i',
            'maxLength': 2000,
          },
      ];
  }
  return Block.fromJson({...b.json, 'data': data});
}

/// Every rendered icon or text run that falls back to the MaterialIcons font.
/// Hosts are not required to bundle that font, so it would show as tofu.
List<String> materialIconFontUses(WidgetTester tester) {
  bool isMaterial(String? family) =>
      family != null && family.contains('MaterialIcons');
  final uses = <String>[];
  for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
    if (isMaterial(icon.icon?.fontFamily)) uses.add('Icon(${icon.icon})');
  }
  for (final text in tester.widgetList<RichText>(find.byType(RichText))) {
    text.text.visitChildren((span) {
      if (span is TextSpan && isMaterial(span.style?.fontFamily)) {
        uses.add('RichText(${span.text})');
      }
      return true;
    });
    final root = text.text;
    if (root is TextSpan && isMaterial(root.style?.fontFamily)) {
      uses.add('RichText(${root.text})');
    }
  }
  return uses;
}
