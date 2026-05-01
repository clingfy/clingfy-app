import 'package:flutter/material.dart';

class GridPainter extends CustomPainter {
  final Color color;
  final double step;

  GridPainter({required this.color, this.step = 40});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final s = step <= 0 ? 40.0 : step;
    for (double x = 0; x < size.width; x += s) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += s) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! GridPainter ||
        oldDelegate.color != color ||
        oldDelegate.step != step;
  }
}
