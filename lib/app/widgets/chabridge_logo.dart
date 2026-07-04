import 'package:flutter/material.dart';

class ChaBridgeLogo extends StatelessWidget {
  const ChaBridgeLogo({super.key, this.size = 42});

  final double size;

  @override
  Widget build(BuildContext context) {
    const brandMint = Color(0xFF0E9F8A);
    const brandMintSoft = Color(0xFF1DB39D);
    const lightMint = Color(0xFFF4FAF8);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [brandMint, brandMintSoft],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      child: CustomPaint(
        painter: _ChaBridgeFacePainter(
          bg: const Color(0xFF0A6A5C),
          fg: lightMint,
        ),
      ),
    );
  }
}

class _ChaBridgeFacePainter extends CustomPainter {
  _ChaBridgeFacePainter({required this.bg, required this.fg});

  final Color bg;
  final Color fg;

  @override
  void paint(Canvas canvas, Size size) {
    final bubblePaint = Paint()..color = fg;
    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.width * 0.14,
        size.height * 0.16,
        size.width * 0.72,
        size.height * 0.56,
      ),
      Radius.circular(size.width * 0.16),
    );
    canvas.drawRRect(bubble, bubblePaint);

    final tail = Path()
      ..moveTo(size.width * 0.44, size.height * 0.7)
      ..lineTo(size.width * 0.37, size.height * 0.84)
      ..lineTo(size.width * 0.54, size.height * 0.71)
      ..close();
    canvas.drawPath(tail, bubblePaint);

    final eyeStyle = TextStyle(
      color: bg,
      fontSize: size.width * 0.16,
      fontWeight: FontWeight.w900,
      height: 1,
    );
    final cPainter = TextPainter(
      text: TextSpan(text: 'C', style: eyeStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final bPainter = TextPainter(
      text: TextSpan(text: 'B', style: eyeStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    cPainter.paint(canvas, Offset(size.width * 0.33, size.height * 0.33));
    bPainter.paint(canvas, Offset(size.width * 0.54, size.height * 0.33));

    final smilePaint = Paint()
      ..color = bg
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.045
      ..strokeCap = StrokeCap.round;
    final smileBridge = Path()
      ..moveTo(size.width * 0.33, size.height * 0.56)
      ..quadraticBezierTo(
        size.width * 0.5,
        size.height * 0.68,
        size.width * 0.67,
        size.height * 0.56,
      );
    canvas.drawPath(smileBridge, smilePaint);

  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
