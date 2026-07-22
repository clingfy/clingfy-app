#include "Bridge/Devices/device_probe_log.h"

#include "Bridge/native_log_publisher.h"

namespace clingfy::bridge::devices {

void LogDeviceProbe(const char* msg) {
  if (msg == nullptr) {
    return;
  }
  NativeLogPublisher::Instance().Debug("DeviceProbe", msg);
}

}  // namespace clingfy::bridge::devices
