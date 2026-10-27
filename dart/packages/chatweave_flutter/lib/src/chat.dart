import 'dart:async';
import 'dart:convert';

import 'components.dart';
import 'localizations.dart';
import 'markdown.dart';

import 'package:chatweave_core/chatweave_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'registry.dart';
import 'theme.dart';

typedef BlockAnchorKey = GlobalKey<State<StatefulWidget>>;

class ProcessStrip extends StatefulWidget {
  const ProcessStrip({
    super.key,
    required this.message,
    required this.state,
    this.onReveal,
    this.onBeforeResize,
    this.onManualResize,
  });
  final Message message;
  final ProcessState state;
  final void Function(String)? onReveal;
  final VoidCallback? onBeforeResize;
  final void Function(BlockAnchorKey)? onManualResize;
  @override
  State<ProcessStrip> createState() => _ProcessStripState();
}

class _ProcessStripState extends State<ProcessStrip> {
  final _rowKeys = <String, BlockAnchorKey>{};
  BlockAnchorKey rowKey(String id) =>
      _rowKeys.putIfAbsent(id, GlobalKey<State<StatefulWidget>>.new);
  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final steps = message.steps.map((s) => s.json).toList();
    if (steps.isEmpty) return const SizedBox.shrink();
    final expanded = widget.state.expanded(message);
    final roots = steps.where((s) => s['parentStepId'] == null).toList();
    final pausedHistory = steps.any(
      (s) =>
          s['blockId'] != null &&
          message.blocks.any(
            (b) =>
                b.id == s['blockId'] &&
                const [
                  'choice',
                  'confirmation',
                  'form_intent',
                ].contains(b.type),
          ),
    );
    final failures = steps.where((s) => s['state'] == 'failed').length;
    var summary = '${cw(context, '查了')} ${roots.length} ${cw(context, '项')}';
    if (message.status == 'interrupted') {
      summary += ' · ${cw(context, '已停止')}';
    } else if (pausedHistory) {
      final answered = steps
          .where((s) => s['blockId'] != null && s['state'] == 'succeeded')
          .length;
      if (answered > 0)
        summary += ' · ${cw(context, '你确认了')} $answered ${cw(context, '项')}';
    } else if (message.status == 'complete') {
      final created = DateTime.tryParse(message['createdAt'] as String? ?? '');
      final completed = DateTime.tryParse(
        message['completedAt'] as String? ?? '',
      );
      final duration = created != null && completed != null
          ? completed.difference(created).inMilliseconds
          : roots.fold<int>(
              0,
              (sum, s) => sum + (s['durationMs'] as int? ?? 0),
            );
      summary += ' · ${cw(context, '用时')} ${_duration(duration)}';
    }
    if (failures > 0) summary += ' ($failures ${cw(context, '项没有完成')})';
    final waiting =
        steps.where((s) => s['state'] == 'awaiting_user').firstOrNull;
    final interruptBlock = waiting == null
        ? null
        : message.blocks.where((b) => b.id == waiting['blockId']).firstOrNull;
    if (waiting != null)
      summary +=
          ' · ${cw(context, interruptBlock?.type == 'confirmation' ? '等你确认' : '等你回答')}';
    final waitingPath = <Object?>{};
    Json? current = waiting;
    while (current != null) {
      waitingPath.add(current['id']);
      final parent = current['parentStepId'];
      current = parent == null
          ? null
          : steps.where((s) => s['id'] == parent).firstOrNull;
    }
    String rowLabel(Json step) {
      final status = waitingPath.contains(step['id'])
          ? cw(
              context,
              interruptBlock?.type == 'confirmation' ? '等你确认' : '等你回答',
            )
          : stateLabel(step['state'], context);
      var text = '${step['label']} · $status';
      if (step['durationMs'] != null) {
        text += ' ${_duration(step['durationMs'] as int)}';
      }
      if (step['summary'] != null && step['summary'] != '') {
        text += ' · ${step['summary']}';
      }
      final answered =
          message.blocks.where((b) => b.id == step['blockId']).firstOrNull;
      if (answered != null && step['state'] == 'succeeded') {
        text += ' · ${interactionSummary(answered, context)}';
      }
      if (step['kind'] == 'delegate') {
        final count =
            steps.where((s) => s['parentStepId'] == step['id']).length;
        if (count > 0) text += ' · $count ${cw(context, '步')}';
      }
      return text;
    }

    List<Widget> rows(Object? parent, int depth) => [
          for (final step
              in steps.where((s) => s['parentStepId'] == parent)) ...[
            Padding(
              padding: EdgeInsets.only(left: depth * 12.0),
              child: Semantics(
                label: '${cw(context, '第')} ${depth + 1} ${cw(context, '层')}',
                expanded: step['kind'] == 'delegate'
                    ? widget.state
                        .expanded(message, stepId: step['id'] as String)
                    : null,
                child: ChatWeaveTextButton(
                  key: rowKey(step['id'] as String),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: () {
                    if (waiting != null && waitingPath.contains(step['id'])) {
                      widget.onReveal?.call(waiting['blockId'] as String);
                    }
                    if (step['kind'] == 'delegate') {
                      widget.onManualResize?.call(rowKey(step['id'] as String));
                      setState(() {
                        widget.state.setExpanded(
                          message.id,
                          !widget.state.expanded(
                            message,
                            stepId: step['id'] as String,
                          ),
                          stepId: step['id'] as String,
                        );
                      });
                    }
                  },
                  child: Text(rowLabel(step)),
                ),
              ),
            ),
            if (step['kind'] == 'delegate' &&
                widget.state.expanded(message, stepId: step['id'] as String))
              ...rows(step['id'], depth + 1),
          ],
        ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          child: ChatWeaveTextButton(
            key: rowKey('summary'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              alignment: Alignment.centerLeft,
            ),
            onPressed: () {
              widget.onManualResize?.call(rowKey('summary'));
              setState(() {
                widget.state.setExpanded(message.id, !expanded);
              });
            },
            child: Text('${cw(context, '过程：')}$summary'),
          ),
        ),
        if (expanded) ...rows(null, 0),
      ],
    );
  }

  String _duration(int ms) => ms < 10000
      ? '${(ms / 1000).toStringAsFixed(1)} ${cw(context, '秒')}'
      : '${(ms / 1000).round()} ${cw(context, '秒')}';
}

/// A stable live region changes only at protocol boundaries, never per token.
class MessageAnnouncements extends StatefulWidget {
  const MessageAnnouncements({super.key, required this.message});
  final Message message;
  @override
  State<MessageAnnouncements> createState() => _MessageAnnouncementsState();
}

class _MessageAnnouncementsState extends State<MessageAnnouncements> {
  String label = '';
  @override
  void didUpdateWidget(MessageAnnouncements oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.message;
    final after = widget.message;
    if (before.status != after.status && after.status == 'paused') {
      label = '${cw(context, '需要你回答：')}${after['fallbackText'] ?? ''}';
    } else if (before.status != after.status &&
        const ['complete', 'interrupted', 'error'].contains(after.status)) {
      label =
          '${stateLabel(after.status, context)}：${after['fallbackText'] ?? ''}';
    } else {
      final ended = after.blocks.where(
        (b) =>
            (b['status'] == null || b['status'] == 'complete') &&
            !before.blocks.any(
              (old) => old.id == b.id && old['status'] != 'pending',
            ),
      );
      if (ended.isNotEmpty) {
        label = ended.map((b) => b['fallbackText'] ?? '').join('，');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        liveRegion: true,
        label: label,
        child: const SizedBox.shrink(),
      );
}

class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.message,
    required this.registry,
    required this.processState,
    this.interactions,
    this.composer,
    this.activity,
    this.onStop,
    this.stopRequested = false,
    this.messageActionsBuilder,
    this.readOnly = false,
    this.blockKeys,
    this.onProcessResize,
    this.onManualProcessResize,
  });
  final Message message;
  final BlockRegistry registry;
  final ProcessState processState;
  final InteractionController? interactions;
  final InterruptComposerController? composer;
  final Json? activity;
  final VoidCallback? onStop;
  final bool stopRequested;
  final bool readOnly;
  final Map<String, BlockAnchorKey>? blockKeys;
  final VoidCallback? onProcessResize;
  final void Function(BlockAnchorKey)? onManualProcessResize;
  final Widget Function(BuildContext, Message)? messageActionsBuilder;
  @override
  Widget build(BuildContext context) {
    final active = message.status == 'streaming' || message.status == 'paused';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MessageAnnouncements(message: message),
        if (message.steps.isNotEmpty)
          ProcessStrip(
            message: message,
            state: processState,
            onBeforeResize: onProcessResize,
            onManualResize: onManualProcessResize,
          ),
        for (final block in message.blocks)
          KeyedSubtree(
            key: blockKeys?[block.id] ?? ValueKey(block.id),
            child: Semantics(
              liveRegion: false,
              child: registry.render(
                block,
                interactions: interactions,
                messageId: message.id,
                composer: composer,
                readOnly: readOnly,
              ),
            ),
          ),
        if (message.status == 'streaming' &&
            activity != null &&
            !message.steps.any((s) => s['state'] == 'running'))
          Semantics(
            liveRegion: false,
            child: Text('${activity!['label'] ?? cw(context, '正在处理…')}'),
          ),
        if (active && onStop != null)
          ChatWeaveTextButton(
            onPressed: stopRequested ? null : onStop,
            child: DefaultLabel(stopRequested ? '正在停止…' : '停止'),
          ),
        if (message.status == 'interrupted') const DefaultLabel('已停止'),
        if (!active)
          messageActionsBuilder?.call(context, message) ??
              Align(
                alignment: Alignment.centerLeft,
                child: ChatWeaveTextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: plainTextSummary(message, 16000)),
                  ),
                  child: const DefaultLabel('复制'),
                ),
              ),
      ],
    );
  }
}

class ChatWeaveList extends StatefulWidget {
  const ChatWeaveList({
    super.key,
    required this.store,
    required this.registry,
    required this.conversationId,
    this.interactions,
    this.composer,
    this.userMessageBuilder,
    this.messageFrameBuilder,
    this.onStop,
    this.stopRequested = const {},
  });
  final BlockStore store;
  final BlockRegistry registry;
  final String conversationId;
  final InteractionController? interactions;
  final InterruptComposerController? composer;
  final Widget Function(BuildContext, Message)? userMessageBuilder;
  final Widget Function(BuildContext, Message, Widget)? messageFrameBuilder;
  final void Function(String)? onStop;
  final Set<String> stopRequested;
  @override
  State<ChatWeaveList> createState() => _ChatWeaveListState();
}

class _ChatWeaveListState extends State<ChatWeaveList> {
  final _scroll = ScrollController();
  final _process = ProcessState();
  late StreamSubscription<StoreSnapshot> _subscription;
  var _viewport = const ViewportState();
  var _scheduled = false;
  var _ids = <String>{};
  final _stopRequested = <String>{};
  final _blockKeys = <String, Map<String, BlockAnchorKey>>{};
  (BlockAnchorKey, double)? _anchor;
  void _restoreAnchor() {
    final anchor = _anchor;
    final box = anchor?.$1.currentContext?.findRenderObject();
    if (anchor != null &&
        box is RenderBox &&
        box.hasSize &&
        _scroll.hasClients) {
      final after = box.localToGlobal(Offset.zero).dy;
      _writeScroll(_scroll.offset + anchor.$2 - after);
    }
    _anchor = null;
  }

  void _captureAnchor({Set<String>? preferredMessages}) {
    if (_viewport.follow || _anchor != null) return;
    (BlockAnchorKey, double)? candidate;
    final viewport = context.findRenderObject();
    final top =
        viewport is RenderBox ? viewport.localToGlobal(Offset.zero).dy : 0.0;
    final bottom =
        viewport is RenderBox ? top + viewport.size.height : double.infinity;
    for (final entry in _blockKeys.entries) {
      if (preferredMessages != null && !preferredMessages.contains(entry.key))
        continue;
      for (final key in entry.value.values) {
        final box = key.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.hasSize || !box.attached) continue;
        final y = box.localToGlobal(Offset.zero).dy;
        if (y >= top && y < bottom && (candidate == null || y < candidate.$2))
          candidate = (key, y);
      }
    }
    _anchor = candidate;
    if (candidate == null && preferredMessages != null) _captureAnchor();
  }

  @override
  void initState() {
    super.initState();
    _ids = widget.store.snapshot.messages.keys.toSet();
    _listen();
  }

  void _listen() {
    var previous = widget.store.snapshot.messages;
    _subscription = widget.store.changes.listen((snapshot) {
      _captureAnchor(
        preferredMessages: {
          for (final entry in snapshot.messages.entries)
            if (!identical(previous[entry.key], entry.value)) entry.key,
        },
      );
      previous = snapshot.messages;
      final ids = snapshot.messages.keys.toSet();
      final newMessage = ids.difference(_ids).isNotEmpty;
      _ids = ids;
      _viewport = ViewportController.reduce(
        _viewport,
        newMessage ? ViewportEvent.newMessage : ViewportEvent.streamGrowth,
        ViewportMeasurements(pixels: _scroll.hasClients ? _scroll.offset : 0),
      ).state;
      if (_scheduled) return;
      _scheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduled = false;
        if (!mounted) return;
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_viewport.follow) {
            _writeScroll(0);
          } else {
            final anchor = _anchor;
            final box = anchor?.$1.currentContext?.findRenderObject();
            if (anchor != null &&
                box is RenderBox &&
                box.hasSize &&
                _scroll.hasClients) {
              final after = box.localToGlobal(Offset.zero).dy;
              final transition = ViewportController.reduce(
                _viewport,
                ViewportEvent.resize,
                ViewportMeasurements(
                  pixels: _scroll.offset,
                  anchorBefore: -anchor.$2,
                  anchorAfter: -after,
                ),
              );
              if (transition.scrollTo != null)
                _writeScroll(transition.scrollTo!);
            }
          }
          _anchor = null;
        });
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  /// The only place that mutates the scroll position.
  void _writeScroll(double pixels) {
    if (mounted && _scroll.hasClients)
      _scroll.jumpTo(
        pixels.clamp(0, _scroll.position.maxScrollExtent).toDouble(),
      );
  }

  @override
  void didUpdateWidget(ChatWeaveList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      _subscription.cancel();
      _listen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.store.snapshot.messages.values
        .where((m) => m['conversationId'] == widget.conversationId)
        .toList()
      ..sort(
        (a, b) =>
            (b['createdAt'] as String).compareTo(a['createdAt'] as String),
      );
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is UserScrollNotification) {
              _viewport = ViewportController.reduce(
                _viewport,
                ViewportEvent.userScroll,
                ViewportMeasurements(
                  pixels: notification.metrics.pixels,
                  atBottom: notification.metrics.pixels < 24,
                ),
              ).state;
            }
            return false;
          },
          child: CustomScrollView(
            controller: _scroll,
            reverse: true,
            slivers: [
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final message = messages[index];
                  final keys = _blockKeys.putIfAbsent(
                    message.id,
                    () => <String, BlockAnchorKey>{},
                  );
                  for (final block in message.blocks) {
                    keys.putIfAbsent(
                      block.id,
                      GlobalKey<State<StatefulWidget>>.new,
                    );
                  }
                  Widget child = message['role'] == 'user' &&
                          widget.userMessageBuilder != null
                      ? widget.userMessageBuilder!(context, message)
                      : MessageView(
                          message: message,
                          registry: widget.registry,
                          processState: _process,
                          interactions: widget.interactions,
                          composer: widget.composer,
                          blockKeys: keys,
                          onManualProcessResize: (key) {
                            final box = key.currentContext?.findRenderObject();
                            if (box is RenderBox && box.hasSize) {
                              _anchor = (
                                key,
                                box.localToGlobal(Offset.zero).dy,
                              );
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) _restoreAnchor();
                              });
                            }
                          },
                          onProcessResize: () {
                            _captureAnchor(preferredMessages: {message.id});
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _restoreAnchor();
                            });
                          },
                          stopRequested: _stopRequested.contains(message.id) ||
                              widget.stopRequested.contains(message.id),
                          activity: widget.store.activityFor(message.id),
                          onStop: widget.onStop == null
                              ? null
                              : () {
                                  setState(() {
                                    _stopRequested.add(message.id);
                                  });
                                  widget.onStop!(message.id);
                                },
                        );
                  child = widget.messageFrameBuilder?.call(
                        context,
                        message,
                        child,
                      ) ??
                      child;
                  return Padding(
                    key: ValueKey(message.id),
                    padding: const EdgeInsets.all(12),
                    child: child,
                  );
                }, childCount: messages.length),
              ),
            ],
          ),
        ),
        if (_viewport.newMessages > 0)
          Positioned(
            bottom: 12,
            right: 12,
            child: ChatWeaveTextButton(
              onPressed: () {
                setState(() {
                  _viewport = const ViewportState();
                });
                _writeScroll(0);
              },
              child: Text(
                '${cw(context, '有')} ${_viewport.newMessages} ${cw(context, '条新内容')}',
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    _scroll.dispose();
    super.dispose();
  }
}

class TextControllerDraft implements DraftPort {
  TextControllerDraft(this.controller, this.focusNode);
  final TextEditingController controller;
  final FocusNode focusNode;
  @override
  String get text => controller.text;
  @override
  set text(String value) {
    controller.text = value;
  }

  @override
  void focus() => focusNode.requestFocus();
}

class InterruptAnswerChip extends StatelessWidget {
  const InterruptAnswerChip({
    super.key,
    required this.question,
    this.onClose,
    this.pending = false,
  });
  final String question;
  final VoidCallback? onClose;
  final bool pending;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              pending ? question : '${cw(context, '回答：')}$question',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onClose != null)
            IconButton(
              tooltip: cw(context, '取消回答，返回选项'),
              onPressed: onClose,
              icon: const ChatWeaveControlIcon(close: true),
            ),
        ],
      );
}

class ChatWeaveComposer extends StatefulWidget {
  const ChatWeaveComposer({
    super.key,
    required this.controller,
    required this.draft,
    required this.onSend,
  });
  final InterruptComposerController controller;
  final TextEditingController draft;
  final void Function(String) onSend;
  @override
  State<ChatWeaveComposer> createState() => _ChatWeaveComposerState();
}

class _ChatWeaveComposerState extends State<ChatWeaveComposer> {
  final _focus = FocusNode();
  @override
  void initState() {
    super.initState();
    widget.controller.attachDraft(TextControllerDraft(widget.draft, _focus));
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<InterruptComposerState>(
        stream: widget.controller.changes,
        initialData: widget.controller.state,
        builder: (context, snapshot) {
          final state = snapshot.data!;
          final locked = state.mode == ComposerMode.locked ||
              state.mode == ComposerMode.submitting;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state.mode == ComposerMode.answering ||
                  state.mode == ComposerMode.submitting)
                InterruptAnswerChip(
                  question: state.mode == ComposerMode.submitting
                      ? cw(context, state.queued ? '已排队，联网后提交' : '提交中…')
                      : state.question,
                  pending: state.mode == ComposerMode.submitting,
                  onClose: state.mode == ComposerMode.answering
                      ? widget.controller.cancelOtherInput
                      : null,
                ),
              if (state.error != null) Text(state.error!),
              if (state.closedReason != null)
                DefaultLabel(switch (state.closedReason) {
                  'expired' => '问题已过期，草稿已保留',
                  'stopped' => '生成已停止，草稿已保留',
                  'withdrawn' => '问题已撤回，草稿已保留',
                  _ => '问题已在别处回答，草稿已保留',
                }),
              Semantics(
                label: cw(context, locked ? '已锁定，先回答上面的问题' : '输入消息'),
                liveRegion: false,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.draft,
                        focusNode: _focus,
                        readOnly: locked,
                        maxLines: 5,
                        minLines: 1,
                        onTap:
                            locked ? widget.controller.revealInterrupt : null,
                        decoration: InputDecoration(
                          hintText: cw(context, locked ? '先回答上面的问题' : '输入消息'),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: cw(context, '发送'),
                      onPressed: locked
                          ? null
                          : () {
                              if (state.mode == ComposerMode.answering) {
                                widget.controller.submitOtherInput(
                                  widget.draft.text,
                                );
                              } else if (widget.draft.text.trim().isNotEmpty) {
                                widget.onSend(widget.draft.text);
                                widget.draft.clear();
                              }
                            },
                      icon: const ChatWeaveControlIcon(),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }
}

class ChatWeaveDebugOverlay extends StatelessWidget {
  const ChatWeaveDebugOverlay({super.key, required this.store});
  final BlockStore store;
  @override
  Widget build(BuildContext context) {
    final inspection =
        const JsonEncoder.withIndent('  ').convert(store.inspect());
    return Material(
      color: ChatWeaveTheme.of(context).surface,
      child: Column(
        children: [
          const DefaultLabel('ChatWeave 状态'),
          Expanded(
            child: SingleChildScrollView(child: SelectableText(inspection)),
          ),
          ChatWeaveTextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: inspection)),
            child: const DefaultLabel('复制诊断信息'),
          ),
        ],
      ),
    );
  }
}
