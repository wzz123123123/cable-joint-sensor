/// 电缆接头温度滤波：中值去尖峰 + 超限需连续确认。
/// 接头热容量大，一两秒内跳几度几乎都是串口毛刺或公式放大，不是真实温升。
class TempChannelFilter {
  TempChannelFilter({
    this.maxStep = 1.5,
    this.confirmCount = 6,
    this.medianLen = 5,
    this.pendingTolerance = 1.0,
  });

  final double maxStep;
  final int confirmCount;
  final int medianLen;
  final double pendingTolerance;

  final List<double> _window = <double>[];
  final List<double> _boot = <double>[];
  double? lastGood;
  double? _pending;
  int _pendingHits = 0;

  static bool isPlausible(double v) =>
      v != -999.0 && v >= -40.0 && v <= 180.0;

  double filter(double raw) {
    if (!isPlausible(raw)) {
      return lastGood ?? -999.0;
    }
    if (lastGood != null && lastGood! > 5.0 && raw.abs() < 0.15) {
      return lastGood!;
    }
    if (lastGood == null) {
      return _lockInitial(raw);
    }
    final good = lastGood!;
    if ((raw - good).abs() <= maxStep) {
      _pending = null;
      _pendingHits = 0;
      _window.add(raw);
      if (_window.length > medianLen) {
        _window.removeAt(0);
      }
      final sorted = [..._window]..sort();
      lastGood = sorted[sorted.length ~/ 2];
      return lastGood!;
    }
    if (_pending != null && (raw - _pending!).abs() <= pendingTolerance) {
      _pendingHits++;
      if (_pendingHits >= confirmCount) {
        lastGood = raw;
        _window
          ..clear()
          ..add(raw);
        _pending = null;
        _pendingHits = 0;
        return lastGood!;
      }
    } else {
      _pending = raw;
      _pendingHits = 1;
    }
    return good;
  }

  double _lockInitial(double raw) {
    _boot.add(raw);
    if (_boot.length > 3) {
      _boot.removeAt(0);
    }
    if (_boot.length < 3) {
      return -999.0;
    }
    final sorted = [..._boot]..sort();
    if (sorted.last - sorted.first > 2.0) {
      return -999.0;
    }
    lastGood = sorted[1];
    _window
      ..clear()
      ..addAll(_boot);
    _boot.clear();
    return lastGood!;
  }
}
