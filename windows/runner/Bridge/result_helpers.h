#ifndef RUNNER_BRIDGE_RESULT_HELPERS_H_
#define RUNNER_BRIDGE_RESULT_HELPERS_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <string>

#include "Bridge/native_error_codes.h"

// Small helpers for the most common Phase 1 method-channel responses.
//
// Phase 1 is mostly "return a shape-correct stub" so a handler is usually one
// line. These helpers keep call sites readable instead of repeating the full
// `flutter::EncodableValue(flutter::EncodableMap{})` boilerplate.
namespace clingfy::bridge::reply {

using FlutterResult = flutter::MethodResult<flutter::EncodableValue>;

inline void Null(FlutterResult& result) {
  result.Success();
}

inline void Bool(FlutterResult& result, bool value) {
  result.Success(flutter::EncodableValue(value));
}

inline void Int(FlutterResult& result, int64_t value) {
  result.Success(flutter::EncodableValue(value));
}

inline void String(FlutterResult& result, const std::string& value) {
  result.Success(flutter::EncodableValue(value));
}

inline void EmptyList(FlutterResult& result) {
  result.Success(flutter::EncodableValue(flutter::EncodableList{}));
}

inline void EmptyMap(FlutterResult& result) {
  result.Success(flutter::EncodableValue(flutter::EncodableMap{}));
}

inline void Map(FlutterResult& result, flutter::EncodableMap value) {
  result.Success(flutter::EncodableValue(std::move(value)));
}

inline void List(FlutterResult& result, flutter::EncodableList value) {
  result.Success(flutter::EncodableValue(std::move(value)));
}

// Structured "not implemented on Windows yet" error. Matches the Phase 0
// behavior so the Flutter side can map a single error code to a single
// localized message everywhere.
inline void NotImplemented(FlutterResult& result, const std::string& method) {
  result.Error(error::kWindowsNotImplemented,
               "Method '" + method + "' is not implemented on Windows yet.");
}

// Argument validation failure — symmetric with the macOS `kBadArgs` behavior.
inline void BadArgs(FlutterResult& result, const std::string& message) {
  result.Error(error::kBadArgs, message);
}

}  // namespace clingfy::bridge::reply

#endif  // RUNNER_BRIDGE_RESULT_HELPERS_H_
