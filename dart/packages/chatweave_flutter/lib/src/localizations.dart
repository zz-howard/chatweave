import 'package:flutter/material.dart';

import 'default_boundary.dart';

/// Override [resolve] to supply application wording. Values from the protocol
/// (titles, labels, errors and body text) are never passed through this resolver.
class ChatWeaveLocalizations extends InheritedWidget {
  const ChatWeaveLocalizations(
      {super.key, required super.child, this.locale = 'zh', this.resolve});
  final String locale;
  final String Function(String key, String fallback)? resolve;
  static String text(BuildContext context, String key) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ChatWeaveLocalizations>();
    final fallback =
        scope?.locale.startsWith('en') == true ? english[key] ?? key : key;
    return scope?.resolve?.call(key, fallback) ?? fallback;
  }

  static const english = <String, String>{
    '内容正在生成': 'Content is being generated',
    '正在生成…': 'Generating…',
    '暂无数据': 'No data',
    '是': 'Yes',
    '否': 'No',
    '查看图表': 'View chart',
    '查看数据表': 'View data table',
    '此内容无法显示': 'Unable to display content',
    '更新 App 可查看完整内容': 'Update the app to view this content',
    '提交': 'Submit',
    '确认': 'Confirm',
    '取消': 'Cancel',
    '输入其他内容': 'Enter another answer',
    '仅可查看': 'Read only',
    '重试': 'Retry',
    '暂时无法确认结果，请重试': 'Could not confirm the result. Please retry.',
    '已排队，联网后提交': 'Queued; will submit when online',
    '暂时无法确认结果，正在刷新…': 'Checking the result…',
    '提交中…': 'Submitting…',
    '停止': 'Stop',
    '已停止': 'Stopped',
    '正在停止…': 'Stopping…',
    '正在处理…': 'Working…',
    '复制': 'Copy',
    '输入消息': 'Message',
    '先回答上面的问题': 'Answer the question above first',
    '已锁定，先回答上面的问题': 'Locked; answer the question above first',
    '发送': 'Send',
    '取消回答，返回选项': 'Cancel answer and return to options',
    'ChatWeave 状态': 'ChatWeave status',
    '复制诊断信息': 'Copy diagnostics',
    '打开链接': 'Open link',
    '打开': 'Open',
    '请选择': 'Select a value',
    '请填写': 'Required',
    '文字太长': 'Text is too long',
    '请输入有效数字': 'Enter a valid number',
    '数值太小': 'Value is too small',
    '数值太大': 'Value is too large',
    '请输入有效日期': 'Enter a valid date',
    '运行中': 'Running',
    '等待中': 'Waiting',
    '等你回答': 'Awaiting your answer',
    '等你确认': 'Awaiting your confirmation',
    '完成': 'Completed',
    '没有完成': 'Failed',
    '你已取消': 'You cancelled',
    '你已确认': 'You confirmed',
    '已过期': 'Expired',
    '已被新的请求取代': 'Replaced by a newer request',
    '已作废': 'Withdrawn',
    '已停止，没有等到回答': 'Stopped before an answer arrived',
    '相关记录已被删除': 'The record was deleted',
    '相关记录已变化': 'The record changed',
    '权限已变化': 'Permissions changed',
    '请求已撤回': 'The request was withdrawn',
    '问题已过期，草稿已保留': 'Question expired; draft kept',
    '生成已停止，草稿已保留': 'Generation stopped; draft kept',
    '问题已撤回，草稿已保留': 'Question withdrawn; draft kept',
    '问题已在别处回答，草稿已保留': 'Answered elsewhere; draft kept',
    '序列': 'Series',
    '时间': 'Time',
    '数值': 'Value',
    '项目': 'Attribute',
    '回答者：': 'Answered by: ',
    '步': 'steps',
    '图片：': 'Image: ',
    '显示': 'Showing',
    '共': 'of',
    '条': 'rows',
    '再次确认：': 'Confirm again: ',
    '需要你回答：': 'Your answer is needed: ',
    '第': 'Level',
    '层': '',
    '查了': 'Checked',
    '项': 'items',
    '你确认了': 'You confirmed',
    '用时': 'Duration',
    '项没有完成': 'items failed',
    '过程：': 'Process: ',
    '已展开': 'Expanded',
    '已收起': 'Collapsed',
    '秒': 's',
    '有': 'There are',
    '条新内容': 'new messages',
    '回答：': 'Answer: ',
    '你的回答：': 'Your answer: ',
    '已回答：': 'Answered: ',
    '已提交：': 'Submitted: ',
    '已作废 · ': 'Withdrawn · ',
  };
  @override
  bool updateShouldNotify(ChatWeaveLocalizations oldWidget) =>
      locale != oldWidget.locale || resolve != oldWidget.resolve;
}

/// Only library default literals use this widget, never producer-supplied text.
class DefaultLabel extends StatelessWidget {
  const DefaultLabel(this.label, {super.key, this.style});
  final String label;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => guardedDefaultBuild(context,
      () => Text(ChatWeaveLocalizations.text(context, label), style: style),
      emergencyFallback: Text(label, style: style));
}

String cw(BuildContext context, String key) =>
    ChatWeaveLocalizations.text(context, key);
