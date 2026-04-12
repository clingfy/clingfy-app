enum HomeGuideStep {
  sidebar,
  captureSource,
  camera,
  output,
  startRecording,
  help,
}

extension HomeGuideStepX on HomeGuideStep {
  int get index => HomeGuideStep.values.indexOf(this);

  int get displayIndex => index + 1;

  bool get isFirst => this == HomeGuideStep.values.first;

  bool get isLast => this == HomeGuideStep.values.last;
}
