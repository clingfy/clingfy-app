/// Phase 10.4 (Windows): result of the native startup crash-recovery
/// sweep returned by `getStartupRecoveryReport`.
///
/// Wire shape (see the Windows bridge handler):
/// ```
/// {
///   "interruptedProjects": [
///     { "projectPath": String, "sessionId": String }
///   ],
///   "cleanedTempFileCount": int,
///   "cleanedTempBytes": int
/// }
/// ```
///
/// Parsing is deliberately defensive — wrong-typed fields degrade to
/// empty/zero instead of throwing, because this runs once at startup and
/// must never take the home screen down.
class InterruptedRecordingProject {
  const InterruptedRecordingProject({
    required this.projectPath,
    required this.sessionId,
  });

  final String projectPath;
  final String sessionId;

  /// Returns null when [raw] is not a map or has no usable projectPath.
  static InterruptedRecordingProject? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final projectPath = raw['projectPath'];
    if (projectPath is! String || projectPath.isEmpty) return null;
    final sessionId = raw['sessionId'];
    return InterruptedRecordingProject(
      projectPath: projectPath,
      sessionId: sessionId is String ? sessionId : '',
    );
  }
}

class StartupRecoveryReport {
  const StartupRecoveryReport({
    required this.interruptedProjects,
    required this.cleanedTempFileCount,
    required this.cleanedTempBytes,
  });

  static const StartupRecoveryReport empty = StartupRecoveryReport(
    interruptedProjects: [],
    cleanedTempFileCount: 0,
    cleanedTempBytes: 0,
  );

  final List<InterruptedRecordingProject> interruptedProjects;
  final int cleanedTempFileCount;
  final int cleanedTempBytes;

  bool get hasInterruptedProjects => interruptedProjects.isNotEmpty;
  bool get hasCleanedTempFiles => cleanedTempFileCount > 0;

  static StartupRecoveryReport fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return empty;

    final projects = <InterruptedRecordingProject>[];
    final rawProjects = raw['interruptedProjects'];
    if (rawProjects is List) {
      for (final entry in rawProjects) {
        final project = InterruptedRecordingProject.fromMap(entry);
        if (project != null) {
          projects.add(project);
        }
      }
    }

    return StartupRecoveryReport(
      interruptedProjects: projects,
      cleanedTempFileCount: _asInt(raw['cleanedTempFileCount']),
      cleanedTempBytes: _asInt(raw['cleanedTempBytes']),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
