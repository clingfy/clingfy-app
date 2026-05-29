// Windows save-folder resolution + folder picker — the Windows analog of
// macOS `SaveFolderStore` (macos/Runner/Services/SaveFolderStore.swift).
//
// macOS defaults exports to `~/Movies/Clingfy` and `ExportEngine` falls
// back to it whenever the Dart-supplied `directoryOverride` is empty. The
// Windows port shipped Slice 1 with neither a default nor a working
// folder picker (storage_router's `getSaveFolder` / `chooseSaveFolder`
// were null stubs), so every export with no explicit folder failed with
// `kNoDestination`. This module supplies both halves:
//
//   * DefaultSaveFolder()      — %USERPROFILE%\Videos\Clingfy (the
//                                analog of ~/Movies/Clingfy).
//   * ChooseSaveFolderDialog() — a real IFileOpenDialog folder picker so
//                                Settings → Workspace and the export
//                                dialog's "Change" button work.
//
// Persistence stays on the Dart side: `WorkspaceSettingsController`
// caches the picked path in SharedPreferences (it only calls
// `getSaveFolder` to seed the first-run default). So this module is
// stateless — it resolves a default and shows a picker; it does not
// persist anything itself.

#ifndef RUNNER_SERVICES_SAVE_FOLDER_H_
#define RUNNER_SERVICES_SAVE_FOLDER_H_

#include <windows.h>

#include <optional>
#include <string>

namespace clingfy::storage {

// The default export folder as a wide path, WITHOUT creating it on disk
// (creation is lazy, on first export — matching macOS). Resolution order:
//   1. CLINGFY_DEFAULT_SAVE_FOLDER env var (test seam / power-user
//      override), if set and non-empty.
//   2. SHGetKnownFolderPath(FOLDERID_Videos) + "\\Clingfy".
//   3. %USERPROFILE%\Videos\Clingfy.
// Returns empty only when none of the above resolve (no env, no known
// folder, no USERPROFILE) — pathological.
std::wstring DefaultSaveFolder();

// UTF-8 form of DefaultSaveFolder(); does not create the folder.
std::string DefaultSaveFolderUtf8();

// Create `path` and any missing parents. Returns true if the directory
// exists after the call.
bool EnsureDirectoryExists(const std::wstring& path);

// UTF-8 from a wide string. Exposed so callers (e.g. export_passthrough)
// can convert a resolved DefaultSaveFolder() without duplicating the
// WideCharToMultiByte dance.
std::string WideToUtf8(const std::wstring& wide);

// Show the Windows folder picker (IFileOpenDialog with FOS_PICKFOLDERS).
// Returns the chosen absolute path (UTF-8), or std::nullopt when the user
// cancels or the dialog cannot be created. `parent` may be nullptr.
// Initializes COM (apartment-threaded) for the duration of the call.
std::optional<std::string> ChooseSaveFolderDialog(HWND parent);

}  // namespace clingfy::storage

#endif  // RUNNER_SERVICES_SAVE_FOLDER_H_
