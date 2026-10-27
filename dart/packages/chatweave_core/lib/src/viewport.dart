class ViewportState {
  const ViewportState(
      {this.follow = true,
      this.anchorId,
      this.anchorOffset = 0,
      this.newMessages = 0});
  final bool follow;
  final String? anchorId;
  final double anchorOffset;
  final int newMessages;
}

enum ViewportEvent {
  userScroll,
  historyPrepend,
  resize,
  newMessage,
  streamGrowth,
  jumpToLatest
}

class ViewportMeasurements {
  const ViewportMeasurements(
      {required this.pixels,
      this.atBottom = false,
      this.anchorId,
      this.anchorBefore = 0,
      this.anchorAfter = 0});
  final double pixels;
  final bool atBottom;
  final String? anchorId;
  final double anchorBefore;
  final double anchorAfter;
}

class ViewportTransition {
  const ViewportTransition(this.state, this.scrollTo);
  final ViewportState state;
  final double? scrollTo;
}

class ViewportController {
  static ViewportTransition reduce(
      ViewportState state, ViewportEvent event, ViewportMeasurements m) {
    if (event == ViewportEvent.jumpToLatest) {
      return const ViewportTransition(ViewportState(), 0);
    }
    if (event == ViewportEvent.userScroll) {
      return ViewportTransition(
          ViewportState(
              follow: m.atBottom,
              anchorId: m.anchorId,
              anchorOffset: m.anchorBefore,
              newMessages: m.atBottom ? 0 : state.newMessages),
          null);
    }
    if (state.follow) return ViewportTransition(state, 0);
    final next = ViewportState(
        follow: false,
        anchorId: state.anchorId,
        anchorOffset: state.anchorOffset,
        newMessages:
            state.newMessages + (event == ViewportEvent.newMessage ? 1 : 0));
    return ViewportTransition(
        next,
        event == ViewportEvent.historyPrepend || event == ViewportEvent.resize
            ? m.pixels + m.anchorAfter - m.anchorBefore
            : null);
  }
}
