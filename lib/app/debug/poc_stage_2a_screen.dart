// Phase 5 POC Stage 2A-1 — debug-only Flutter screen.
//
// Gated by `--dart-define=POC_STAGE_2A=true`. main.dart branches on
// `PocStage2aScreen.isEnabled` and replaces the production
// PlatformApp with this screen when the flag is set. Production
// builds never touch any of this — both kPocStage2a and the branch in
// main.dart inline-constant out under tree-shaking.
//
// What it does:
//   1. Calls `pocStage2aStart` on the screen recorder method channel
//      (the existing one — no new channel). Native side allocates a
//      DXGI shared-handle D3D11 texture, registers it with the
//      Flutter Windows TextureRegistrar, returns the texture id.
//   2. Mounts a `Texture(textureId: ...)` widget — Flutter samples the
//      shared handle through its own ANGLE / EGL context.
//   3. Attaches SchedulerBinding.instance.addTimingsCallback to track
//      buildDuration / rasterDuration / totalSpan for the last
//      `kTimingWindow` frames. Median + p99 are computed on the fly.
//   4. On dispose (or the Stop button), invokes `pocStage2aStop` with
//      the final timing stats so the native side can write
//      `build/windows-poc/stage2a_result.md`.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:clingfy/core/bridges/native_method_channel.dart';

class PocStage2aScreen extends StatefulWidget {
  const PocStage2aScreen({super.key});

  static const bool isEnabled = bool.fromEnvironment('POC_STAGE_2A');

  @override
  State<PocStage2aScreen> createState() => _PocStage2aScreenState();
}

class _PocStage2aScreenState extends State<PocStage2aScreen> {
  static const MethodChannel _channel = MethodChannel(
    NativeChannel.screenRecorder,
  );

  // How many recent frames participate in the live stats. 30 s × 60 fps = 1800.
  static const int _kTimingWindow = 2048;

  int? _textureId;
  bool _sharedHandleOk = false;
  List<String> _eglExtensions = const <String>[];
  String? _startError;
  int _textureWidth = 0;
  int _textureHeight = 0;

  // Ring buffer of recent Flutter pipeline timings (microseconds).
  final List<int> _buildUs = <int>[];
  final List<int> _rasterUs = <int>[];
  final List<int> _totalUs = <int>[];
  int _framesObserved = 0;

  TimingsCallback? _timingsCallback;
  Timer? _statsRefresh;
  Timer? _autoStop;
  bool _stopRequested = false;

  /// Seconds to keep the screen running before auto-calling
  /// pocStage2aStop. Mirrors Stage 1D's 30-second window so the p99
  /// settles past Flutter's first-paint ramp (initial frames include
  /// shader compilation + cache warming that skew small windows).
  /// Default 25 s gives time for graceful shutdown before a 35 s
  /// taskkill in CI-style runs. Override with
  /// `--dart-define=POC_STAGE_2A_AUTO_STOP_SECONDS=N`. Zero disables.
  static const int autoStopSeconds = int.fromEnvironment(
    'POC_STAGE_2A_AUTO_STOP_SECONDS',
    defaultValue: 25,
  );

  @override
  void initState() {
    super.initState();
    _attachTimings();
    // Defer the native call by one frame so the Texture widget mounts
    // before we ask Flutter to read from it. Avoids a single-frame
    // first-paint flash where the widget exists but the texture id is
    // unregistered.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    // Re-render the stats panel ~4 Hz so the live numbers refresh
    // without flooding rebuilds on every frame.
    _statsRefresh = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    // Auto-stop so a non-interactive launch captures real timings.
    if (autoStopSeconds > 0) {
      _autoStop = Timer(Duration(seconds: autoStopSeconds), () async {
        if (_stopRequested) return;
        _stopRequested = true;
        await _invokeStop();
      });
    }
  }

  @override
  void dispose() {
    _detachTimings();
    _statsRefresh?.cancel();
    _autoStop?.cancel();
    // Best-effort stop. dispose runs synchronously; the unawaited
    // future is fine because the native side handles late-arriving
    // shutdown gracefully and we don't have anything to do after.
    if (!_stopRequested) {
      _stopRequested = true;
      unawaited(_invokeStop());
    }
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final dynamic raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pocStage2aStart',
      );
      if (raw is! Map) {
        if (mounted) {
          setState(() {
            _startError =
                'pocStage2aStart returned unexpected type ${raw.runtimeType}';
          });
        }
        return;
      }
      final Map<String, dynamic> result = raw.cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _textureId = (result['textureId'] as num?)?.toInt();
        _sharedHandleOk = result['sharedHandleOk'] as bool? ?? false;
        _eglExtensions =
            (result['eglExtensions'] as List?)
                ?.cast<dynamic>()
                .map((e) => e.toString())
                .toList(growable: false) ??
            const <String>[];
        _textureWidth = (result['width'] as num?)?.toInt() ?? 0;
        _textureHeight = (result['height'] as num?)?.toInt() ?? 0;
        _startError = result['error'] as String?;
      });
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _startError = '${e.code}: ${e.message ?? e.toString()}';
        });
      }
    }
  }

  Future<void> _invokeStop() async {
    final build = _percentiles(_buildUs);
    final raster = _percentiles(_rasterUs);
    final total = _percentiles(_totalUs);
    try {
      await _channel.invokeMethod<void>('pocStage2aStop', <String, dynamic>{
        'buildMedianMs': build.medianMs,
        'buildP99Ms': build.p99Ms,
        'rasterMedianMs': raster.medianMs,
        'rasterP99Ms': raster.p99Ms,
        'totalMedianMs': total.medianMs,
        'totalP99Ms': total.p99Ms,
        'flutterFramesObserved': _framesObserved,
      });
    } on PlatformException {
      // Shutdown best-effort.
    }
  }

  void _attachTimings() {
    _timingsCallback = (List<FrameTiming> timings) {
      for (final t in timings) {
        _buildUs.add(t.buildDuration.inMicroseconds);
        _rasterUs.add(t.rasterDuration.inMicroseconds);
        _totalUs.add(t.totalSpan.inMicroseconds);
        if (_buildUs.length > _kTimingWindow) _buildUs.removeAt(0);
        if (_rasterUs.length > _kTimingWindow) _rasterUs.removeAt(0);
        if (_totalUs.length > _kTimingWindow) _totalUs.removeAt(0);
        _framesObserved++;
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_timingsCallback!);
  }

  void _detachTimings() {
    if (_timingsCallback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_timingsCallback!);
      _timingsCallback = null;
    }
  }

  _Percentiles _percentiles(List<int> samplesUs) {
    if (samplesUs.isEmpty) return const _Percentiles(0, 0, 0, 0);
    final sorted = List<int>.from(samplesUs)..sort();
    final n = sorted.length;
    final medianIdx = (n - 1) * 0.5;
    final p99Idx = (n - 1) * 0.99;
    double lerp(double idx) {
      final lower = idx.floor();
      final upper = math.min(lower + 1, n - 1);
      final frac = idx - lower;
      return sorted[lower] + (sorted[upper] - sorted[lower]) * frac;
    }

    return _Percentiles(
      n,
      sorted.first / 1000.0,
      lerp(medianIdx) / 1000.0,
      lerp(p99Idx) / 1000.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final build = _percentiles(_buildUs);
    final raster = _percentiles(_rasterUs);
    final total = _percentiles(_totalUs);
    return Scaffold(
      backgroundColor: const Color(0xFF101012),
      appBar: AppBar(
        title: const Text('Stage 2A-1 — Flutter Texture / shared-handle spike'),
        backgroundColor: const Color(0xFF1A1A1F),
        actions: [
          IconButton(
            tooltip: 'Stop POC and pop',
            onPressed: () async {
              // Capture the navigator before the async gap so the
              // post-await use doesn't depend on the BuildContext
              // still being mounted (use_build_context_synchronously).
              final navigator = Navigator.of(context);
              _stopRequested = true;
              await _invokeStop();
              if (mounted) navigator.maybePop();
            },
            icon: const Icon(Icons.stop_circle_outlined),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(child: _buildTexturePanel()),
          SizedBox(width: 360, child: _buildStatsPanel(build, raster, total)),
        ],
      ),
    );
  }

  Widget _buildTexturePanel() {
    if (_startError != null && _textureId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'pocStage2aStart failed:\n\n$_startError',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      );
    }
    if (_textureId == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Container(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _textureHeight > 0
              ? _textureWidth / _textureHeight
              : 16 / 9,
          child: Texture(textureId: _textureId!),
        ),
      ),
    );
  }

  Widget _buildStatsPanel(
    _Percentiles build,
    _Percentiles raster,
    _Percentiles total,
  ) {
    final headerStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
    );
    final bodyStyle = const TextStyle(
      color: Colors.white70,
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.4,
    );
    return Container(
      color: const Color(0xFF15151A),
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Texture / bridge', style: headerStyle),
            const SizedBox(height: 8),
            Text(
              'textureId        : ${_textureId ?? "—"}\n'
              'sharedHandleOk   : $_sharedHandleOk\n'
              'size             : $_textureWidth × $_textureHeight\n'
              'error            : ${_startError ?? "—"}',
              style: bodyStyle,
            ),
            const SizedBox(height: 16),
            Text('EGL / ANGLE extensions', style: headerStyle),
            const SizedBox(height: 8),
            Text(
              _eglExtensions.isEmpty
                  ? '(not reachable through PluginRegistrar — left empty)'
                  : _eglExtensions.join('\n'),
              style: bodyStyle,
            ),
            const SizedBox(height: 16),
            Text('Flutter pipeline timings', style: headerStyle),
            const SizedBox(height: 8),
            Text(
              'frames observed  : $_framesObserved\n'
              '\n'
              'bucket  median  p99\n'
              '------  ------  ------\n'
              'build  ${_fmt(build.medianMs)} ${_fmt(build.p99Ms)}\n'
              'raster ${_fmt(raster.medianMs)} ${_fmt(raster.p99Ms)}\n'
              'total  ${_fmt(total.medianMs)} ${_fmt(total.p99Ms)}\n',
              style: bodyStyle,
            ),
            const SizedBox(height: 16),
            Text('Pass bar', style: headerStyle),
            const SizedBox(height: 8),
            Text(
              'raster median ≤ 16 ms AND raster p99 ≤ 25 ms\n'
              '\n'
              'shared-handle ok : ${_sharedHandleOk ? "PASS" : "FAIL"}\n'
              'raster median    : ${raster.medianMs <= 16 ? "PASS" : "FAIL"}\n'
              'raster p99       : ${raster.p99Ms <= 25 ? "PASS" : "FAIL"}',
              style: bodyStyle,
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(double ms) {
    return ms.toStringAsFixed(2).padLeft(6);
  }
}

class _Percentiles {
  final int sampleCount;
  final double minMs;
  final double medianMs;
  final double p99Ms;
  const _Percentiles(this.sampleCount, this.minMs, this.medianMs, this.p99Ms);
}

/// Wraps the debug screen in a tiny MaterialApp shell so it can be the
/// top-level widget when `--dart-define=POC_STAGE_2A=true` is set.
/// Lives next to the screen so main.dart never has to import a long
/// widget tree just to dispatch on the flag.
class PocStage2aApp extends StatelessWidget {
  const PocStage2aApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Clingfy POC Stage 2A',
      home: PocStage2aScreen(),
    );
  }
}
