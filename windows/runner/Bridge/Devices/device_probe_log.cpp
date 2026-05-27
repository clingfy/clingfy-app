#include "Bridge/Devices/device_probe_log.h"

#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <system_error>

namespace clingfy::bridge::devices {

void LogDeviceProbe(const char* msg) {
  if (msg == nullptr) {
    return;
  }
  std::error_code ec;
  std::filesystem::create_directories(L"build\\windows-poc", ec);
  std::ofstream f(L"build\\windows-poc\\device_probe.log",
                  std::ios::out | std::ios::app | std::ios::binary);
  if (!f.is_open()) {
    return;
  }
  std::time_t now = std::time(nullptr);
  std::tm tm_utc{};
#if defined(_MSC_VER)
  ::gmtime_s(&tm_utc, &now);
#else
  tm_utc = *std::gmtime(&now);
#endif
  char ts[32];
  std::snprintf(ts, sizeof(ts), "%02d:%02d:%02d ",
                tm_utc.tm_hour, tm_utc.tm_min, tm_utc.tm_sec);
  f << ts << msg << "\n";
}

}  // namespace clingfy::bridge::devices
