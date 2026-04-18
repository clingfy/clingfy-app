import FlutterMacOS

func flutterError(_ code: String, _ msg: String, details: Any? = nil) -> FlutterError {
  FlutterError(code: code, message: msg, details: details)
}
