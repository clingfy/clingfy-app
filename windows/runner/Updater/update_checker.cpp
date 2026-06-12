#include "Updater/update_checker.h"

#include <windows.h>
#include <winhttp.h>

#include <atomic>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include "Bridge/native_log_publisher.h"
#include "Bridge/platform_thread_dispatcher.h"
#include "Bridge/updater_event_publisher.h"

namespace clingfy::updater {

namespace {

constexpr char kLogCategory[] = "Updater";
// latest-windows.json is a few hundred bytes; anything past this cap is not
// our feed.
constexpr size_t kMaxFeedBytes = 256 * 1024;

bool IsHttpsUrl(const std::string& url) {
  static constexpr char kPrefix[] = "https://";
  static constexpr size_t kPrefixLen = sizeof(kPrefix) - 1;
  return url.size() > kPrefixLen && url.compare(0, kPrefixLen, kPrefix) == 0;
}

std::wstring Utf8ToWideLocal(const std::string& utf8) {
  if (utf8.empty()) return std::wstring{};
  const int needed = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) return std::wstring{};
  std::wstring out(static_cast<size_t>(needed), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                        static_cast<int>(utf8.size()), out.data(), needed);
  return out;
}

// RAII for HINTERNET handles.
struct WinHttpHandle {
  HINTERNET handle = nullptr;
  explicit WinHttpHandle(HINTERNET h) : handle(h) {}
  ~WinHttpHandle() {
    if (handle != nullptr) ::WinHttpCloseHandle(handle);
  }
  WinHttpHandle(const WinHttpHandle&) = delete;
  WinHttpHandle& operator=(const WinHttpHandle&) = delete;
  explicit operator bool() const { return handle != nullptr; }
};

// `cancel` is polled between WinHTTP calls and `deadline_ms` bounds the
// whole fetch: the per-call receive timeout (15s) only bounds ONE
// QueryDataAvailable/ReadData call, so a server dribbling a byte every
// few seconds would otherwise keep the read loop alive for hours — and
// the CRT-exit join with it.
FetchResult FetchUrlWinHttp(const std::string& url,
                            const std::atomic<bool>& cancel,
                            ULONGLONG deadline_ms) {
  FetchResult out;
  const ULONGLONG start_ms = ::GetTickCount64();
  const std::wstring wide_url = Utf8ToWideLocal(url);
  if (wide_url.empty()) {
    out.error = "feed URL is not valid UTF-8";
    return out;
  }

  URL_COMPONENTS components{};
  components.dwStructSize = sizeof(components);
  wchar_t host[256] = {};
  wchar_t path[2048] = {};
  components.lpszHostName = host;
  components.dwHostNameLength =
      static_cast<DWORD>(sizeof(host) / sizeof(host[0]));
  components.lpszUrlPath = path;
  components.dwUrlPathLength =
      static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
  if (!::WinHttpCrackUrl(wide_url.c_str(),
                         static_cast<DWORD>(wide_url.size()), 0,
                         &components) ||
      components.nScheme != INTERNET_SCHEME_HTTPS) {
    out.error = "feed URL could not be parsed as https";
    return out;
  }

  WinHttpHandle session(::WinHttpOpen(
      L"Clingfy-Windows-Updater/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
  if (!session) {
    out.error = "WinHttpOpen failed (" + std::to_string(::GetLastError()) + ")";
    return out;
  }
  // resolve / connect / send / receive, in ms. These also bound the
  // CRT-exit join when the app quits mid-check.
  ::WinHttpSetTimeouts(session.handle, 5000, 5000, 10000, 15000);

  WinHttpHandle connection(::WinHttpConnect(session.handle, host,
                                            components.nPort, 0));
  if (!connection) {
    out.error =
        "WinHttpConnect failed (" + std::to_string(::GetLastError()) + ")";
    return out;
  }

  WinHttpHandle request(::WinHttpOpenRequest(
      connection.handle, L"GET", path, nullptr, WINHTTP_NO_REFERER,
      WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
  if (!request) {
    out.error =
        "WinHttpOpenRequest failed (" + std::to_string(::GetLastError()) + ")";
    return out;
  }

  if (!::WinHttpSendRequest(request.handle, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
      !::WinHttpReceiveResponse(request.handle, nullptr)) {
    out.error =
        "feed request failed (" + std::to_string(::GetLastError()) + ")";
    return out;
  }

  DWORD status = 0;
  DWORD status_size = sizeof(status);
  if (!::WinHttpQueryHeaders(
          request.handle,
          WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
          WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size,
          WINHTTP_NO_HEADER_INDEX) ||
      status != 200) {
    out.error = "feed returned HTTP " + std::to_string(status);
    return out;
  }

  std::string body;
  for (;;) {
    if (cancel.load()) {
      out.error = "update check cancelled (app exiting)";
      return out;
    }
    if (::GetTickCount64() - start_ms > deadline_ms) {
      out.error = "feed read exceeded the time budget";
      return out;
    }
    DWORD available = 0;
    if (!::WinHttpQueryDataAvailable(request.handle, &available)) {
      out.error =
          "feed read failed (" + std::to_string(::GetLastError()) + ")";
      return out;
    }
    if (available == 0) break;
    if (body.size() + available > kMaxFeedBytes) {
      out.error = "feed body exceeds the size cap";
      return out;
    }
    std::vector<char> chunk(available);
    DWORD read = 0;
    if (!::WinHttpReadData(request.handle, chunk.data(), available, &read)) {
      out.error =
          "feed read failed (" + std::to_string(::GetLastError()) + ")";
      return out;
    }
    body.append(chunk.data(), read);
    if (read == 0) break;
  }

  out.ok = true;
  out.body = std::move(body);
  return out;
}

// Worker-thread state. Function-local static so its destructor (which joins
// the worker) runs BEFORE the publisher / log / dispatcher singletons are
// torn down — see Holder() for the forced initialization order. Mirrors the
// 10.1 temp_orphan_scan exit-race fix.
struct WorkerHolder {
  std::mutex mutex;
  std::thread worker;
  std::atomic<bool> busy{false};
  std::atomic<bool> cancel{false};
  Fetcher fetcher_override;  // tests only
  // Outer optional: is the override active? Inner: the forced version, or
  // nullopt to force the "no version resource" path. Tests only.
  std::optional<std::optional<AppVersion>> version_override;

  ~WorkerHolder() {
    cancel.store(true);
    if (worker.joinable()) {
      worker.join();
    }
  }
};

WorkerHolder& Holder() {
  // Force-init every singleton the worker touches so CRT reverse-destruction
  // keeps them alive longer than the holder (whose destructor joins the
  // worker). Construction order here is load-bearing.
  bridge::UpdaterEventPublisher::Instance();
  bridge::NativeLogPublisher::Instance();
  bridge::PlatformThreadDispatcher::Instance();
  static WorkerHolder holder;
  return holder;
}

// Total wall-clock budget for one feed fetch. Bounds both the user-facing
// "checking" duration and the CRT-exit join (one in-flight WinHTTP call,
// <= ~15s, is the residual worst case).
constexpr ULONGLONG kFetchDeadlineMs = 30'000;

void RunCheck(const std::string& feed_url,
              const std::string& expected_channel) {
  auto& holder = Holder();
  auto& publisher = bridge::UpdaterEventPublisher::Instance();
  auto& log = bridge::NativeLogPublisher::Instance();

  // Clear busy IMMEDIATELY BEFORE each terminal emit (not after): once Dart
  // has seen a terminal event, a re-click must start a fresh check. If the
  // clear came after, a re-click could land in the window where the event
  // was delivered but busy was still true — StartUpdateCheck would return
  // "started" without any new events, stranding the UI on "checking".
  const auto finish = [&holder]() { holder.busy.store(false); };

  publisher.EmitChecking();
  log.Info(kLogCategory, "Update check started: " + feed_url);

  Fetcher fetcher;
  {
    std::lock_guard<std::mutex> lock(holder.mutex);
    fetcher = holder.fetcher_override;
  }
  const FetchResult fetched =
      fetcher ? fetcher(feed_url)
              : FetchUrlWinHttp(feed_url, holder.cancel, kFetchDeadlineMs);
  if (holder.cancel.load()) return;

  if (!fetched.ok) {
    log.Warn(kLogCategory, "Update feed fetch failed: " + fetched.error);
    finish();
    publisher.EmitUpdateError(codes::kFeedUnreachable,
                              SanitizeForEvent(fetched.error));
    return;
  }

  std::optional<AppVersion> current;
  {
    std::lock_guard<std::mutex> lock(holder.mutex);
    if (holder.version_override.has_value()) {
      current = *holder.version_override;
    } else {
      current = CurrentAppVersionFromExe();
    }
  }
  if (!current.has_value()) {
    log.Error(kLogCategory,
              "Update check aborted: executable has no version resource");
    finish();
    publisher.EmitUpdateError(
        codes::kVersionUnknown,
        "The running build has no version information to compare against.");
    return;
  }

  const UpdateFeed feed = ParseUpdateFeed(fetched.body);
  const UpdateDecision decision =
      EvaluateUpdateFeed(feed, expected_channel, *current);
  if (holder.cancel.load()) return;

  switch (decision.action) {
    case UpdateDecision::Action::kUpdateAvailable: {
      const std::string build_str =
          feed.build >= 0 ? std::to_string(feed.build) : std::string{};
      // versionFull is DERIVED from the validated version + build, never
      // forwarded from the feed: the raw field is free-form remote text
      // and the Dart dialog prefers versionFull — forwarding it verbatim
      // would let a compromised feed render arbitrary prose inside the
      // trusted update dialog.
      const std::string version_full =
          build_str.empty() ? feed.version : feed.version + "+" + build_str;
      log.Info(kLogCategory, "Update available: " + feed.version + " (build " +
                                 build_str + ")");
      finish();
      publisher.EmitUpdateAvailable(SanitizeForEvent(feed.version), build_str,
                                    SanitizeForEvent(feed.url),
                                    SanitizeForEvent(version_full));
      break;
    }
    case UpdateDecision::Action::kNoUpdate:
      log.Info(kLogCategory,
               "No update available (feed version " + feed.version + ")");
      finish();
      publisher.EmitNoUpdateAvailable(SanitizeForEvent(feed.version));
      break;
    case UpdateDecision::Action::kError:
      log.Warn(kLogCategory, "Update check failed: " + decision.message);
      finish();
      // decision.message embeds feed fields (channel/platform/version) —
      // sanitize so an invalid byte can never kill the codec decode and
      // silently drop the very event that reports the problem.
      publisher.EmitUpdateError(decision.code,
                                SanitizeForEvent(decision.message));
      break;
  }
}

}  // namespace

bool StartUpdateCheck(const std::string& feed_url,
                      const std::string& expected_channel) {
  auto& holder = Holder();
  if (!IsHttpsUrl(feed_url)) {
    bridge::NativeLogPublisher::Instance().Warn(
        kLogCategory, "Update check rejected: feed URL is not https");
    bridge::UpdaterEventPublisher::Instance().EmitUpdateError(
        codes::kFeedUnreachable, "Update feed URL must be https.");
    return false;
  }

  // Reclaim the previous (finished) worker BEFORE spawning the new one,
  // and OUTSIDE the lock: the worker takes holder.mutex for its snapshot
  // reads, so joining under the lock would deadlock if it were somehow
  // still mid-flight. Joining first also means no joinable std::thread
  // local exists if the constructor below throws — destroying a joinable
  // thread during unwinding would std::terminate the process.
  std::thread stale;
  {
    std::lock_guard<std::mutex> lock(holder.mutex);
    if (holder.busy.load()) {
      // A check is already in flight; busy is cleared before its terminal
      // event is emitted (see RunCheck), so anyone who has already seen a
      // result can always start a fresh check. Treat this request as
      // started — the in-flight check's events are still coming.
      return true;
    }
    stale = std::move(holder.worker);
  }
  if (stale.joinable()) {
    stale.join();  // finished worker (busy was false) — returns immediately
  }

  std::lock_guard<std::mutex> lock(holder.mutex);
  if (holder.busy.load()) {
    return true;  // another caller won the gap between the two locks
  }
  // busy=true must precede thread start (a fast worker could otherwise
  // clear busy before we set it, wedging it true forever) — so a throwing
  // std::thread constructor (resource exhaustion, capture bad_alloc) must
  // roll it back and report honestly instead of leaving the updater dead.
  holder.busy.store(true);
  try {
    holder.worker = std::thread([feed_url, expected_channel]() {
      RunCheck(feed_url, expected_channel);
      // Safety net — RunCheck already cleared busy before its terminal
      // emit; the store is idempotent and covers the cancel early-returns.
      Holder().busy.store(false);
    });
  } catch (...) {
    holder.busy.store(false);
    bridge::NativeLogPublisher::Instance().Error(
        kLogCategory, "Update check worker could not be started");
    bridge::UpdaterEventPublisher::Instance().EmitUpdateError(
        codes::kFeedUnreachable, "The update check could not be started.");
    return false;
  }
  return true;
}

std::optional<AppVersion> CurrentAppVersionFromExe() {
  wchar_t exe_path[MAX_PATH] = {};
  const DWORD path_len =
      ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  if (path_len == 0 || path_len >= MAX_PATH) {
    return std::nullopt;
  }
  const DWORD info_size = ::GetFileVersionInfoSizeW(exe_path, nullptr);
  if (info_size == 0) {
    return std::nullopt;
  }
  std::vector<unsigned char> info(info_size);
  if (!::GetFileVersionInfoW(exe_path, 0, info_size, info.data())) {
    return std::nullopt;
  }
  VS_FIXEDFILEINFO* fixed = nullptr;
  UINT fixed_len = 0;
  if (!::VerQueryValueW(info.data(), L"\\",
                        reinterpret_cast<void**>(&fixed), &fixed_len) ||
      fixed == nullptr || fixed_len < sizeof(VS_FIXEDFILEINFO)) {
    return std::nullopt;
  }
  AppVersion version;
  version.major = static_cast<int>(HIWORD(fixed->dwFileVersionMS));
  version.minor = static_cast<int>(LOWORD(fixed->dwFileVersionMS));
  version.patch = static_cast<int>(HIWORD(fixed->dwFileVersionLS));
  version.build = static_cast<std::int64_t>(LOWORD(fixed->dwFileVersionLS));
  return version;
}

void SetUpdateFetcherForTesting(Fetcher fetcher) {
  auto& holder = Holder();
  std::lock_guard<std::mutex> lock(holder.mutex);
  holder.fetcher_override = std::move(fetcher);
}

void SetCurrentVersionForTesting(std::optional<AppVersion> version) {
  auto& holder = Holder();
  std::lock_guard<std::mutex> lock(holder.mutex);
  holder.version_override = version;
}

void ClearCurrentVersionOverrideForTesting() {
  auto& holder = Holder();
  std::lock_guard<std::mutex> lock(holder.mutex);
  holder.version_override.reset();
}

void JoinUpdateCheckForTesting() {
  auto& holder = Holder();
  // Move the thread out under the lock, join OUTSIDE it: the worker takes
  // holder.mutex for its fetcher/version snapshots, so joining while
  // holding the mutex would deadlock against a mid-flight check.
  std::thread worker;
  {
    std::lock_guard<std::mutex> lock(holder.mutex);
    worker = std::move(holder.worker);
  }
  if (worker.joinable()) {
    worker.join();
  }
}

}  // namespace clingfy::updater
