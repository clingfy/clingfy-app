#ifndef RUNNER_SERVICES_SHELL_REVEAL_H_
#define RUNNER_SERVICES_SHELL_REVEAL_H_

#include <string>

namespace clingfy::storage {

// Phase 10.1: real Explorer reveal/open for the storage_router handlers
// that used to be silent no-ops (one of which showed a fake success toast).

// Pure decision for what a reveal request should do — unit-testable
// without Explorer. kSelectInFolder = open the parent folder with the item
// selected; kOpenFolder = open the directory itself; kNone = nothing to
// reveal (caller replies a structured error instead of pretending).
enum class RevealAction { kNone, kOpenFolder, kSelectInFolder };
RevealAction ResolveRevealAction(bool path_exists, bool is_directory);

// UTF-8 → UTF-16 for paths arriving over the method channel.
std::wstring Utf8ToWide(const std::string& utf8);

// Open the directory in Explorer. False when the shell refuses the launch.
bool OpenFolderInExplorer(const std::wstring& folder);

// Open Explorer at the file's parent with the file selected
// (SHOpenFolderAndSelectItems); falls back to opening the parent folder
// when item selection fails. False when nothing could be opened.
bool SelectInExplorer(const std::wstring& file);

}  // namespace clingfy::storage

#endif  // RUNNER_SERVICES_SHELL_REVEAL_H_
