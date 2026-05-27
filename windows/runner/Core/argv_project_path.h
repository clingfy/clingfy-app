// Step 5.6 argv pickup. Helper that scans a Windows command-line
// (Unicode) for the first argument that looks like a `.clingfyproj`
// bundle path and returns it.
//
// Why a separate helper:
//   * Flutter's tooling sometimes adds its own command-line flags
//     (--observatory-port, --enable-dart-profiling, etc.) that must
//     not be mistaken for a project path.
//   * `CommandLineToArgvW` is the Win32-blessed way to tokenize the
//     raw L"" command line; rolling our own splitter mishandles quoted
//     paths with spaces (the common Explorer case for paths under
//     "C:\Users\…").
//
// The helper is *not* responsible for verifying the file exists on disk
// — that check belongs to the downstream consumer. Returning an absent
// optional means "no .clingfyproj-looking argument was passed".

#ifndef RUNNER_CORE_ARGV_PROJECT_PATH_H_
#define RUNNER_CORE_ARGV_PROJECT_PATH_H_

#include <optional>
#include <string>
#include <vector>

namespace clingfy::core {

// Extract the first argument that ends in `.clingfyproj` (case-insensitive)
// and is not a flag (does not start with `-` or `/`). The leading argv[0]
// (executable path) is skipped — `wWinMain`'s command_line parameter
// already excludes it, but for unit-testable purity the helper accepts a
// full argv-shaped vector that *may* include argv[0].
//
// Returns the matched path as a UTF-16 string (Windows native).
std::optional<std::wstring> ExtractClingfyProjPath(
    const std::vector<std::wstring>& argv);

// Convenience: tokenize a raw command-line via `CommandLineToArgvW`
// then call ExtractClingfyProjPath. Returns absent on tokenization
// failure.
std::optional<std::wstring> ExtractClingfyProjPathFromCommandLine(
    const wchar_t* command_line);

// UTF-16 → UTF-8 for handing the path to the bridge layer.
std::string WideToUtf8(const std::wstring& w);

}  // namespace clingfy::core

#endif  // RUNNER_CORE_ARGV_PROJECT_PATH_H_
