import 'dart:math' as math;

import 'package:clingfy/ui/platform/widgets/pane_divider_handle.dart';
import 'package:flutter/material.dart';

enum DesktopPaneId {
  homeLeftSidebar,
  homeOptionsPanel,
  homeWorkspaceColumn,
  homeRightWorkspace,
  recordingSidebar,
  postProcessingSidebar,
  postProcessingSidebarContainer,
  recordingSidebarContainer,
}

@immutable
class DesktopPaneSpec {
  const DesktopPaneSpec({
    required this.id,
    required this.defaultWidth,
    required this.minWidth,
    this.maxWidth,
    this.collapsedWidth = 0,
    this.resizable = false,
    this.collapsible = false,
    this.autoCollapsePriority = 0,
    this.autoCollapseAllowed = true,
    this.flex = false,
  }) : assert(minWidth > 0),
       assert(defaultWidth >= minWidth),
       assert(maxWidth == null || maxWidth >= minWidth),
       assert(maxWidth == null || maxWidth >= defaultWidth),
       assert(!collapsible || collapsedWidth <= minWidth),
       assert(!(resizable && flex));

  final DesktopPaneId id;
  final double defaultWidth;
  final double minWidth;
  final double? maxWidth;
  final double collapsedWidth;
  final bool resizable;
  final bool collapsible;
  final int autoCollapsePriority;
  final bool autoCollapseAllowed;
  final bool flex;

  double clampWidth(double width) {
    final maxWidth = this.maxWidth;
    if (maxWidth == null) {
      return math.max(minWidth, width);
    }
    return width.clamp(minWidth, maxWidth).toDouble();
  }
}

@immutable
class DesktopPaneState {
  const DesktopPaneState({
    this.width,
    this.lastExpandedWidth,
    this.isCollapsed = false,
    this.userResized = false,
  });

  final double? width;
  final double? lastExpandedWidth;
  final bool isCollapsed;
  final bool userResized;

  DesktopPaneState copyWith({
    double? width,
    double? lastExpandedWidth,
    bool? isCollapsed,
    bool? userResized,
  }) {
    return DesktopPaneState(
      width: width ?? this.width,
      lastExpandedWidth: lastExpandedWidth ?? this.lastExpandedWidth,
      isCollapsed: isCollapsed ?? this.isCollapsed,
      userResized: userResized ?? this.userResized,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (width != null) 'width': width,
      if (lastExpandedWidth != null) 'lastExpandedWidth': lastExpandedWidth,
      'isCollapsed': isCollapsed,
      'userResized': userResized,
    };
  }

  factory DesktopPaneState.fromJsonObject(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return const DesktopPaneState();
    }

    double? asPositiveDouble(Object? value) {
      if (value is num && value > 0) {
        return value.toDouble();
      }
      return null;
    }

    return DesktopPaneState(
      width: asPositiveDouble(raw['width']),
      lastExpandedWidth: asPositiveDouble(raw['lastExpandedWidth']),
      isCollapsed: raw['isCollapsed'] == true,
      userResized: raw['userResized'] == true,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DesktopPaneState &&
        other.width == width &&
        other.lastExpandedWidth == lastExpandedWidth &&
        other.isCollapsed == isCollapsed &&
        other.userResized == userResized;
  }

  @override
  int get hashCode =>
      Object.hash(width, lastExpandedWidth, isCollapsed, userResized);
}

@immutable
class DesktopPaneLayoutPrefs {
  const DesktopPaneLayoutPrefs({
    this.paneStates = const <DesktopPaneId, DesktopPaneState>{},
  });

  final Map<DesktopPaneId, DesktopPaneState> paneStates;

  DesktopPaneState stateFor(DesktopPaneId id) {
    return paneStates[id] ?? const DesktopPaneState();
  }

  DesktopPaneLayoutPrefs copyWithPaneState(
    DesktopPaneId id,
    DesktopPaneState state,
  ) {
    return DesktopPaneLayoutPrefs(
      paneStates: <DesktopPaneId, DesktopPaneState>{...paneStates, id: state},
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      for (final entry in paneStates.entries)
        entry.key.name: entry.value.toJson(),
    };
  }

  factory DesktopPaneLayoutPrefs.fromJsonObject(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return const DesktopPaneLayoutPrefs();
    }

    final states = <DesktopPaneId, DesktopPaneState>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) {
        continue;
      }
      final paneId = DesktopPaneId.values.where((value) => value.name == key);
      if (paneId.isEmpty) {
        continue;
      }
      states[paneId.first] = DesktopPaneState.fromJsonObject(entry.value);
    }

    return DesktopPaneLayoutPrefs(paneStates: states);
  }

  @override
  bool operator ==(Object other) {
    if (other is! DesktopPaneLayoutPrefs) {
      return false;
    }
    if (identical(this, other)) {
      return true;
    }
    if (paneStates.length != other.paneStates.length) {
      return false;
    }
    for (final entry in paneStates.entries) {
      if (other.paneStates[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(
    paneStates.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

@immutable
class DesktopPanePresentation {
  const DesktopPanePresentation({
    required this.id,
    required this.effectiveWidth,
    required this.effectiveCollapsed,
    required this.isCompact,
    required this.isUserCollapsed,
    required this.isAutoCollapsed,
    required this.showExpandHandle,
    required this.showCollapseHandle,
    required this.canResize,
    required this.canCollapse,
  });

  final DesktopPaneId id;
  final double effectiveWidth;
  final bool effectiveCollapsed;
  final bool isCompact;
  final bool isUserCollapsed;
  final bool isAutoCollapsed;
  final bool showExpandHandle;
  final bool showCollapseHandle;
  final bool canResize;
  final bool canCollapse;
}

typedef DesktopPaneBuilder =
    Widget Function(BuildContext context, DesktopPanePresentation presentation);

@immutable
class DesktopPaneSlot {
  const DesktopPaneSlot({required this.spec, required this.builder});

  final DesktopPaneSpec spec;
  final DesktopPaneBuilder builder;
}

class DesktopPaneController extends ChangeNotifier {
  DesktopPaneController({
    DesktopPaneLayoutPrefs initialLayout = const DesktopPaneLayoutPrefs(),
  }) : _layout = initialLayout;

  DesktopPaneLayoutPrefs _layout;

  DesktopPaneLayoutPrefs get layout => _layout;

  DesktopPaneState stateFor(DesktopPaneId id) => _layout.stateFor(id);

  void applyPersistedLayout(DesktopPaneLayoutPrefs layout) {
    if (_layout == layout) {
      return;
    }
    _layout = layout;
    notifyListeners();
  }

  void setPaneWidth(
    DesktopPaneSpec spec,
    double width, {
    bool userResized = true,
  }) {
    final current = stateFor(spec.id);
    final clampedWidth = spec.clampWidth(width);
    final next = current.copyWith(
      width: clampedWidth,
      lastExpandedWidth: clampedWidth,
      isCollapsed: false,
      userResized: userResized,
    );
    if (next == current) {
      return;
    }
    _layout = _layout.copyWithPaneState(spec.id, next);
    notifyListeners();
  }

  void setPaneCollapsed(DesktopPaneSpec spec, bool collapsed) {
    final current = stateFor(spec.id);
    final expandedWidth = spec.clampWidth(
      current.width ?? current.lastExpandedWidth ?? spec.defaultWidth,
    );
    final next = current.copyWith(
      isCollapsed: collapsed,
      width: collapsed ? current.width : expandedWidth,
      lastExpandedWidth: collapsed
          ? expandedWidth
          : (current.lastExpandedWidth ?? expandedWidth),
    );
    if (next == current) {
      return;
    }
    _layout = _layout.copyWithPaneState(spec.id, next);
    notifyListeners();
  }

  void togglePaneCollapsed(DesktopPaneSpec spec) {
    setPaneCollapsed(spec, !stateFor(spec.id).isCollapsed);
  }
}

class DesktopSplitLayout extends StatefulWidget {
  const DesktopSplitLayout({
    super.key,
    required this.controller,
    required this.panes,
    required this.gap,
    this.minHeight,
    this.forcedCollapsedPaneIds = const <DesktopPaneId>{},
    this.onLayoutCommitted,
  });

  final DesktopPaneController controller;
  final List<DesktopPaneSlot> panes;
  final double gap;
  final double? minHeight;
  final Set<DesktopPaneId> forcedCollapsedPaneIds;

  /// Fires only for committed layout changes, such as drag end or an explicit
  /// collapse/expand action. Live drag updates remain local to the controller
  /// so callers can persist the final layout without writing on every frame.
  final ValueChanged<DesktopPaneLayoutPrefs>? onLayoutCommitted;

  @override
  State<DesktopSplitLayout> createState() => _DesktopSplitLayoutState();
}

class _DesktopSplitLayoutState extends State<DesktopSplitLayout> {
  DesktopPaneId? _activeResizePaneId;
  double? _resizeStartDx;
  double? _resizeStartWidth;
  Map<DesktopPaneId, bool> _lastCollapsedStates = const <DesktopPaneId, bool>{};
  double? _lastAvailableWidth;

  bool get _isDragging => _activeResizePaneId != null;

  @override
  Widget build(BuildContext context) {
    assert(() {
      _debugValidatePaneSpecs(widget.panes);
      return true;
    }());

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : _fallbackWidth();
            final previousAvailableWidth = _lastAvailableWidth;
            _lastAvailableWidth = availableWidth;
            final resolved = _resolveLayout(availableWidth);
            final previousCollapsedStates = _lastCollapsedStates;
            final currentCollapsedStates = <DesktopPaneId, bool>{
              for (final pane in resolved.panes)
                pane.presentation.id: pane.presentation.effectiveCollapsed,
            };
            _lastCollapsedStates = currentCollapsedStates;
            final widthChanged =
                previousAvailableWidth != null &&
                (previousAvailableWidth - availableWidth).abs() > 0.1;
            final collapseStateChanged =
                previousCollapsedStates.length !=
                    currentCollapsedStates.length ||
                currentCollapsedStates.entries.any(
                  (entry) => previousCollapsedStates[entry.key] != entry.value,
                );
            final row = SizedBox(
              width: resolved.layoutWidth,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var index = 0;
                        index < resolved.panes.length;
                        index++
                      ) ...[
                        _buildPane(
                          resolved.panes[index],
                          disableAnimation:
                              collapseStateChanged || widthChanged,
                        ),
                        if (index < resolved.panes.length - 1)
                          SizedBox(width: widget.gap),
                      ],
                    ],
                  ),
                  ..._buildDividerOverlays(resolved),
                ],
              ),
            );

            final constrained = ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.minHeight ?? 0),
              child: row,
            );

            if (!resolved.requiresHorizontalScroll) {
              return constrained;
            }

            return SingleChildScrollView(
              key: const Key('desktop_split_layout_scroll_view'),
              scrollDirection: Axis.horizontal,
              child: constrained,
            );
          },
        );
      },
    );
  }

  double _fallbackWidth() {
    var totalWidth = 0.0;
    for (final pane in widget.panes) {
      final state = widget.controller.stateFor(pane.spec.id);
      final isForcedCollapsed =
          pane.spec.collapsible &&
          widget.forcedCollapsedPaneIds.contains(pane.spec.id);
      totalWidth += (state.isCollapsed || isForcedCollapsed)
          ? pane.spec.collapsedWidth
          : pane.spec.defaultWidth;
    }
    totalWidth += math.max(0, widget.panes.length - 1) * widget.gap;
    return totalWidth;
  }

  Widget _buildPane(_ResolvedPane pane, {required bool disableAnimation}) {
    return AnimatedContainer(
      duration: _isDragging || disableAnimation
          ? Duration.zero
          : const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      width: pane.presentation.effectiveWidth,
      child: pane.slot.builder(context, pane.presentation),
    );
  }

  List<Widget> _buildDividerOverlays(_ResolvedDesktopPaneLayout resolved) {
    final overlays = <Widget>[];
    var offset = 0.0;
    for (var index = 0; index < resolved.panes.length - 1; index++) {
      final left = resolved.panes[index];
      offset += left.presentation.effectiveWidth;
      final handleLeft =
          offset + (widget.gap / 2) - (PaneDividerHandle.hitWidth / 2);
      offset += widget.gap;

      if (!left.slot.spec.resizable || left.presentation.effectiveCollapsed) {
        continue;
      }

      overlays.add(
        Positioned(
          left: handleLeft,
          top: 0,
          bottom: 0,
          width: PaneDividerHandle.hitWidth,
          child: PaneDividerHandle(
            key: ValueKey('desktop_pane_handle_${left.slot.spec.id.name}'),
            isActive: _activeResizePaneId == left.slot.spec.id,
            onHorizontalDragStart: (details) {
              _activeResizePaneId = left.slot.spec.id;
              _resizeStartDx = details.globalPosition.dx;
              _resizeStartWidth = left.presentation.effectiveWidth;
              setState(() {});
            },
            onHorizontalDragUpdate: (details) {
              if (_activeResizePaneId != left.slot.spec.id ||
                  _resizeStartDx == null ||
                  _resizeStartWidth == null) {
                return;
              }
              final delta = details.globalPosition.dx - _resizeStartDx!;
              widget.controller.setPaneWidth(
                left.slot.spec,
                _resizeStartWidth! + delta,
              );
            },
            onHorizontalDragEnd: (_) {
              if (_activeResizePaneId == left.slot.spec.id) {
                widget.onLayoutCommitted?.call(widget.controller.layout);
              }
              _activeResizePaneId = null;
              _resizeStartDx = null;
              _resizeStartWidth = null;
              if (mounted) {
                setState(() {});
              }
            },
          ),
        ),
      );
    }
    return overlays;
  }

  _ResolvedDesktopPaneLayout _resolveLayout(double availableWidth) {
    final panes = widget.panes;
    final forcedCollapsed = widget.forcedCollapsedPaneIds;
    final squeezedWidths = <DesktopPaneId, double>{};
    final effectiveCollapsed = <DesktopPaneId, bool>{};
    final autoCollapsed = <DesktopPaneId, bool>{};

    DesktopPaneSlot? flexPane;
    for (final pane in panes) {
      if (pane.spec.flex) {
        flexPane = pane;
      }

      final state = widget.controller.stateFor(pane.spec.id);
      final baseExpandedWidth = pane.spec.clampWidth(
        state.width ?? state.lastExpandedWidth ?? pane.spec.defaultWidth,
      );
      final isForcedCollapsed =
          pane.spec.collapsible && forcedCollapsed.contains(pane.spec.id);
      final isCollapsed =
          pane.spec.collapsible && (state.isCollapsed || isForcedCollapsed);

      squeezedWidths[pane.spec.id] = isCollapsed
          ? pane.spec.collapsedWidth
          : baseExpandedWidth;
      effectiveCollapsed[pane.spec.id] = isCollapsed;
      autoCollapsed[pane.spec.id] = isForcedCollapsed && !state.isCollapsed;
    }

    final flexSpec = flexPane?.spec;
    if (flexSpec != null) {
      var requiredWidth = _requiredWidth(
        panes: panes,
        widths: squeezedWidths,
        flexWidth: flexSpec.minWidth,
      );
      var overflow = math.max(0.0, requiredWidth - availableWidth);

      if (overflow > 0) {
        // Keep the workspace dominant by squeezing resizable panes before
        // auto-collapsing any pane under width pressure.
        final resizableOrder =
            panes
                .where(
                  (pane) =>
                      !pane.spec.flex &&
                      pane.spec.resizable &&
                      !(effectiveCollapsed[pane.spec.id] ?? false),
                )
                .toList()
              ..sort(
                (a, b) => a.spec.autoCollapsePriority.compareTo(
                  b.spec.autoCollapsePriority,
                ),
              );

        for (final pane in resizableOrder) {
          final currentWidth = squeezedWidths[pane.spec.id]!;
          final minWidth = pane.spec.minWidth;
          final reducible = currentWidth - minWidth;
          if (reducible <= 0) {
            continue;
          }
          final reduction = math.min(reducible, overflow);
          squeezedWidths[pane.spec.id] = currentWidth - reduction;
          overflow -= reduction;
          if (overflow <= 0) {
            break;
          }
        }
      }

      if (overflow > 0) {
        // Auto-collapse eligible panes in priority order only after squeezing
        // widths to their pane minimums. If that still does not fit, the layout
        // falls back to horizontal scrolling below.
        final collapseOrder =
            panes
                .where(
                  (pane) =>
                      !pane.spec.flex &&
                      pane.spec.collapsible &&
                      !(effectiveCollapsed[pane.spec.id] ?? false) &&
                      pane.spec.autoCollapseAllowed,
                )
                .toList()
              ..sort(
                (a, b) => a.spec.autoCollapsePriority.compareTo(
                  b.spec.autoCollapsePriority,
                ),
              );

        for (final pane in collapseOrder) {
          final currentWidth = squeezedWidths[pane.spec.id]!;
          if (currentWidth <= pane.spec.collapsedWidth) {
            continue;
          }
          squeezedWidths[pane.spec.id] = pane.spec.collapsedWidth;
          effectiveCollapsed[pane.spec.id] = true;
          if (!widget.controller.stateFor(pane.spec.id).isCollapsed) {
            autoCollapsed[pane.spec.id] = true;
          }
          requiredWidth = _requiredWidth(
            panes: panes,
            widths: squeezedWidths,
            flexWidth: flexSpec.minWidth,
          );
          overflow = math.max(0.0, requiredWidth - availableWidth);
          if (overflow <= 0) {
            break;
          }
        }
      }

      final finalRequiredWidth = _requiredWidth(
        panes: panes,
        widths: squeezedWidths,
        flexWidth: flexSpec.minWidth,
      );
      final requiresHorizontalScroll = finalRequiredWidth > availableWidth;
      final flexWidth = requiresHorizontalScroll
          ? flexSpec.minWidth
          : math.max(
              flexSpec.minWidth,
              availableWidth -
                  _requiredFixedWidth(panes: panes, widths: squeezedWidths),
            );
      squeezedWidths[flexSpec.id] = flexWidth;

      final resolvedPanes = panes
          .map(
            (pane) => _ResolvedPane(
              slot: pane,
              presentation: DesktopPanePresentation(
                id: pane.spec.id,
                effectiveWidth: squeezedWidths[pane.spec.id]!,
                effectiveCollapsed: effectiveCollapsed[pane.spec.id] ?? false,
                isCompact:
                    (effectiveCollapsed[pane.spec.id] ?? false) ||
                    squeezedWidths[pane.spec.id]! <=
                        pane.spec.collapsedWidth + 4,
                isUserCollapsed: widget.controller
                    .stateFor(pane.spec.id)
                    .isCollapsed,
                isAutoCollapsed: autoCollapsed[pane.spec.id] ?? false,
                showExpandHandle:
                    (effectiveCollapsed[pane.spec.id] ?? false) &&
                    pane.spec.collapsible,
                showCollapseHandle:
                    !(effectiveCollapsed[pane.spec.id] ?? false) &&
                    pane.spec.collapsible,
                canResize: pane.spec.resizable,
                canCollapse: pane.spec.collapsible,
              ),
            ),
          )
          .toList();

      return _ResolvedDesktopPaneLayout(
        panes: resolvedPanes,
        layoutWidth: requiresHorizontalScroll
            ? finalRequiredWidth
            : availableWidth,
        requiresHorizontalScroll: requiresHorizontalScroll,
      );
    }

    final resolvedPanes = panes
        .map(
          (pane) => _ResolvedPane(
            slot: pane,
            presentation: DesktopPanePresentation(
              id: pane.spec.id,
              effectiveWidth: squeezedWidths[pane.spec.id]!,
              effectiveCollapsed: effectiveCollapsed[pane.spec.id] ?? false,
              isCompact:
                  (effectiveCollapsed[pane.spec.id] ?? false) ||
                  squeezedWidths[pane.spec.id]! <= pane.spec.collapsedWidth + 4,
              isUserCollapsed: widget.controller
                  .stateFor(pane.spec.id)
                  .isCollapsed,
              isAutoCollapsed: autoCollapsed[pane.spec.id] ?? false,
              showExpandHandle:
                  (effectiveCollapsed[pane.spec.id] ?? false) &&
                  pane.spec.collapsible,
              showCollapseHandle:
                  !(effectiveCollapsed[pane.spec.id] ?? false) &&
                  pane.spec.collapsible,
              canResize: pane.spec.resizable,
              canCollapse: pane.spec.collapsible,
            ),
          ),
        )
        .toList();

    final requiredWidth = _requiredFixedWidth(
      panes: panes,
      widths: squeezedWidths,
    );
    return _ResolvedDesktopPaneLayout(
      panes: resolvedPanes,
      layoutWidth: math.max(requiredWidth, availableWidth),
      requiresHorizontalScroll: requiredWidth > availableWidth,
    );
  }

  double _requiredFixedWidth({
    required List<DesktopPaneSlot> panes,
    required Map<DesktopPaneId, double> widths,
  }) {
    var total = 0.0;
    for (final pane in panes) {
      if (pane.spec.flex) {
        continue;
      }
      total += widths[pane.spec.id]!;
    }
    total += math.max(0, panes.length - 1) * widget.gap;
    return total;
  }

  double _requiredWidth({
    required List<DesktopPaneSlot> panes,
    required Map<DesktopPaneId, double> widths,
    required double flexWidth,
  }) {
    return _requiredFixedWidth(panes: panes, widths: widths) + flexWidth;
  }

  void _debugValidatePaneSpecs(List<DesktopPaneSlot> panes) {
    final ids = <DesktopPaneId>{};
    var flexCount = 0;

    for (final pane in panes) {
      final spec = pane.spec;
      assert(ids.add(spec.id), 'Duplicate DesktopPaneId: ${spec.id.name}');
      if (spec.flex) {
        flexCount += 1;
      }
    }

    assert(
      flexCount <= 1,
      'DesktopSplitLayout supports at most one flex pane.',
    );
  }
}

@immutable
class _ResolvedPane {
  const _ResolvedPane({required this.slot, required this.presentation});

  final DesktopPaneSlot slot;
  final DesktopPanePresentation presentation;
}

@immutable
class _ResolvedDesktopPaneLayout {
  const _ResolvedDesktopPaneLayout({
    required this.panes,
    required this.layoutWidth,
    required this.requiresHorizontalScroll,
  });

  final List<_ResolvedPane> panes;
  final double layoutWidth;
  final bool requiresHorizontalScroll;
}
