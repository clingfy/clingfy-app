/// Result of the native startup sweep returned by `getStartupRecoveryReport`.
///
/// Wire shape (see the Windows and macOS bridge handlers):
/// ```
/// {
///   "interruptedProjects": [
///     { "projectPath": String, "sessionId": String }
///   ],
///   "cleanedTempFileCount": int,
///   "cleanedTempBytes": int,
///   "repairedProjects": [String]   // macOS only: paused takes whose parts
///                                  // were joined at launch
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
    this.repairedProjects = const [],
  });

  static const StartupRecoveryReport empty = StartupRecoveryReport(
    interruptedProjects: [],
    cleanedTempFileCount: 0,
    cleanedTempBytes: 0,
  );

  final List<InterruptedRecordingProject> interruptedProjects;
  final int cleanedTempFileCount;
  final int cleanedTempBytes;

  /// Project paths of paused recordings whose parts, which could not be
  /// joined when they stopped, were joined by the launch repair.
  final List<String> repairedProjects;

  bool get hasInterruptedProjects => interruptedProjects.isNotEmpty;
  bool get hasRepairedProjects => repairedProjects.isNotEmpty;
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

    final rawRepaired = raw['repairedProjects'];
    final repaired = rawRepaired is List
        ? rawRepaired.whereType<String>().where((p) => p.isNotEmpty).toList()
        : const <String>[];

    return StartupRecoveryReport(
      interruptedProjects: projects,
      cleanedTempFileCount: _asInt(raw['cleanedTempFileCount']),
      cleanedTempBytes: _asInt(raw['cleanedTempBytes']),
      repairedProjects: repaired,
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
