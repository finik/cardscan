import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as im;

const warpWidth = 1000;
const warpHeight = 1400;

class Quad {
  Quad(this.tl, this.tr, this.br, this.bl);
  final im.Point tl, tr, br, bl;

  List<im.Point> get points => [tl, tr, br, bl];
}

class WarpResult {
  WarpResult({
    required this.jpeg,
    required this.warped,
    this.raw,
    this.overlayJson,
  });
  final Uint8List jpeg;
  final bool warped;
  final Uint8List? raw;
  final String? overlayJson;
}

/// Isolate entry — returns `[Uint8List jpeg, bool warped]` (sendable).
List<dynamic> warpJpegIsolate(Uint8List bytes) {
  final r = warpJpeg(bytes);
  return [r.jpeg, r.warped];
}

/// Find the card inside the on-screen guide and warp it to 1000×1400.
List<dynamic> cropToFrameIsolate(Map<Object?, Object?> args) {
  try {
    return _cropToFrame(args);
  } catch (_) {
    final jpeg = args['jpeg'] as Uint8List;
    return [jpeg, false];
  }
}

List<dynamic> _cropToFrame(Map<Object?, Object?> args) {
  final jpeg = args['jpeg'] as Uint8List;
  final decoded = im.decodeJpg(jpeg);
  if (decoded == null) return [jpeg, false];
  var src = decoded;
  final viewW = (args['viewW'] as num).toDouble();
  final viewH = (args['viewH'] as num).toDouble();
  final left = (args['left'] as num).toDouble();
  final top = (args['top'] as num).toDouble();
  final right = (args['right'] as num).toDouble();
  final bottom = (args['bottom'] as num).toDouble();

  final overlay = _viewRectToQuad(
    src, viewW, viewH, left, top, right, bottom,
  );
  var quad = _findCardInGuide(src, overlay) ?? overlay;
  // grayscale() mutates in place; clone so the color still is unchanged.
  quad = _tightenToWhite(im.grayscale(src.clone()), quad);
  quad = _insetQuad(quad, -0.05);
  final outImg = warpPerspective(src, quad, warpWidth, warpHeight);
  final out = Uint8List.fromList(im.encodeJpg(outImg, quality: 95));
  return [out, true];
}

double _overlapFrac(Quad a, Quad b) {
  final ax0 = a.points.map((p) => p.x.toDouble()).reduce(math.min);
  final ax1 = a.points.map((p) => p.x.toDouble()).reduce(math.max);
  final ay0 = a.points.map((p) => p.y.toDouble()).reduce(math.min);
  final ay1 = a.points.map((p) => p.y.toDouble()).reduce(math.max);
  final bx0 = b.points.map((p) => p.x.toDouble()).reduce(math.min);
  final bx1 = b.points.map((p) => p.x.toDouble()).reduce(math.max);
  final by0 = b.points.map((p) => p.y.toDouble()).reduce(math.min);
  final by1 = b.points.map((p) => p.y.toDouble()).reduce(math.max);
  final ix0 = math.max(ax0, bx0);
  final iy0 = math.max(ay0, by0);
  final ix1 = math.min(ax1, bx1);
  final iy1 = math.min(ay1, by1);
  if (ix1 <= ix0 || iy1 <= iy0) return 0;
  final inter = (ix1 - ix0) * (iy1 - iy0);
  final areaA = math.max(1.0, (ax1 - ax0) * (ay1 - ay0));
  return inter / areaA;
}

/// Pixels on the guide border are treated as background. The card is the
/// interior region that differs from that background.
Quad? _findCardInGuide(im.Image src, Quad overlay) {
  final xs = overlay.points.map((p) => p.x.toDouble()).toList();
  final ys = overlay.points.map((p) => p.y.toDouble()).toList();
  var x0 = xs.reduce(math.min).floor().clamp(0, src.width - 2);
  var y0 = ys.reduce(math.min).floor().clamp(0, src.height - 2);
  var x1 = xs.reduce(math.max).ceil().clamp(x0 + 8, src.width);
  var y1 = ys.reduce(math.max).ceil().clamp(y0 + 8, src.height);
  final rw = x1 - x0;
  final rh = y1 - y0;
  final roi = im.copyCrop(src, x: x0, y: y0, width: rw, height: rh);
  final found = detectCardQuad(roi, minFrac: 0.08, maxFrac: 0.92);
  if (found != null) {
    im.Point lift(im.Point p) => im.Point(p.x + x0, p.y + y0);
    return Quad(lift(found.tl), lift(found.tr), lift(found.br), lift(found.bl));
  }
  final gray = im.gaussianBlur(im.grayscale(roi), radius: 1);
  final w = gray.width, h = gray.height;

  final border = <int>[];
  for (var x = 0; x < w; x++) {
    border.add(gray.getPixel(x, 0).luminance.toInt());
    border.add(gray.getPixel(x, h - 1).luminance.toInt());
  }
  for (var y = 0; y < h; y++) {
    border.add(gray.getPixel(0, y).luminance.toInt());
    border.add(gray.getPixel(w - 1, y).luminance.toInt());
  }
  border.sort();
  final desk = border[border.length ~/ 2];

  Quad? fromPolarity(bool brighter) {
    final mask = Uint8List(w * h);
    var hits = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final lum = gray.getPixel(x, y).luminance.toInt();
        final on = brighter ? lum > desk + 24 : lum < desk - 24;
        if (on) {
          mask[y * w + x] = 1;
          hits++;
        }
      }
    }
    if (hits < w * h * 0.08) return null;
    final quad = _quadFromMask(mask, w, h);
    if (quad == null || !_convex(quad)) return null;
    final frac = _quadArea(quad).abs() / (w * h);
    if (frac < 0.10 || frac > 0.92) return null;
    return quad;
  }

  final bright = fromPolarity(true);
  final dark = fromPolarity(false);
  final quad = () {
    double score(Quad? q) {
      if (q == null) return -1;
      final frac = _quadArea(q).abs() / (w * h);
      if (!_aspectOk(_orderAndOrient(q))) return frac * 0.2;
      return 1.0 - (frac - 0.45).abs();
    }
    return score(bright) >= score(dark) ? bright : dark;
  }();
  if (quad == null) return null;

  im.Point lift(im.Point p) => im.Point(p.x + x0, p.y + y0);
  return Quad(lift(quad.tl), lift(quad.tr), lift(quad.br), lift(quad.bl));
}

Quad _viewRectToQuad(
  im.Image src,
  double viewW,
  double viewH,
  double left,
  double top,
  double right,
  double bottom,
) {
  final imgW = src.width.toDouble();
  final imgH = src.height.toDouble();
  final imageAspect = imgW / imgH;
  final viewAspect = viewW / viewH;
  late double scale, originX, originY;
  if (imageAspect > viewAspect) {
    scale = imgH / viewH;
    originX = (imgW - viewW * scale) / 2;
    originY = 0;
  } else {
    scale = imgW / viewW;
    originX = 0;
    originY = (imgH - viewH * scale) / 2;
  }
  im.Point map(double nx, double ny) =>
      im.Point(originX + nx * viewW * scale, originY + ny * viewH * scale);
  return Quad(map(left, top), map(right, top), map(right, bottom), map(left, bottom));
}

Quad _refineQuad(Quad overlay, Quad? snapped, Quad? nearby) {
  bool ok(Quad q, {double minFrac = 0.12, double maxFrac = 0.85}) {
    final o = _quadArea(overlay).abs();
    final a = _quadArea(q).abs();
    if (o <= 0 || a < o * minFrac || a > o * maxFrac) return false;
    if (_dist(_centroid(overlay), _centroid(q)) > math.sqrt(o) * 0.5) return false;
    return _convex(q);
  }

  // Ignore a quad that fills the entire guide.
  if (nearby != null && ok(nearby)) return nearby;
  if (snapped != null && ok(snapped)) return snapped;
  return overlay;
}

bool _convex(Quad q) {
  final pts = q.points;
  num? sign;
  for (var i = 0; i < 4; i++) {
    final a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4];
    final z = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (z.abs() < 1e-6) continue;
    if (sign == null) {
      sign = z;
    } else if (z.sign != sign.sign) {
      return false;
    }
  }
  return true;
}

Quad? _detectNearOverlay(im.Image src, Quad overlay) {
  final xs = overlay.points.map((p) => p.x.toDouble()).toList();
  final ys = overlay.points.map((p) => p.y.toDouble()).toList();
  var x0 = xs.reduce(math.min);
  var x1 = xs.reduce(math.max);
  var y0 = ys.reduce(math.min);
  var y1 = ys.reduce(math.max);
  final padX = (x1 - x0) * 0.3;
  final padY = (y1 - y0) * 0.3;
  x0 = (x0 - padX).clamp(0, src.width - 1);
  y0 = (y0 - padY).clamp(0, src.height - 1);
  x1 = (x1 + padX).clamp(1, src.width.toDouble());
  y1 = (y1 + padY).clamp(1, src.height.toDouble());
  final rw = (x1 - x0).floor().clamp(8, src.width);
  final rh = (y1 - y0).floor().clamp(8, src.height);
  final roi = im.copyCrop(
    src,
    x: x0.floor(),
    y: y0.floor(),
    width: rw,
    height: rh,
  );
  final found = detectCardQuad(roi);
  if (found == null) return null;
  im.Point lift(im.Point p) => im.Point(p.x + x0, p.y + y0);
  final q = Quad(lift(found.tl), lift(found.tr), lift(found.br), lift(found.bl));
  return _alignToOverlay(overlay, q);
}

/// Keep overlay corner identity (screen top stays JPEG top). Never 90°-spin the card.
Quad _alignToOverlay(Quad overlay, Quad found) {
  final pts = [...found.points];
  im.Point take(im.Point target) {
    var best = pts.first;
    var bestD = 1e18;
    for (final p in pts) {
      final d = _dist(p, target);
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    pts.remove(best);
    return best;
  }

  if (found.points.length != 4) return overlay;
  return Quad(take(overlay.tl), take(overlay.tr), take(overlay.br), take(overlay.bl));
}

im.Point _centroid(Quad q) => im.Point(
      (q.tl.x + q.tr.x + q.br.x + q.bl.x) / 4.0,
      (q.tl.y + q.tr.y + q.br.y + q.bl.y) / 4.0,
    );

Quad? _snapQuadToEdges(im.Image src, Quad overlay) {
  final maxSide = 420.0;
  final scale = math.max(src.width, src.height) / maxSide;
  final w = math.max(1, (src.width / scale).round());
  final h = math.max(1, (src.height / scale).round());
  final small = im.copyResize(src, width: w, height: h, interpolation: im.Interpolation.linear);
  final gray = im.gaussianBlur(im.grayscale(small), radius: 1);
  im.Point down(im.Point p) => im.Point(p.x / scale, p.y / scale);
  final q = Quad(down(overlay.tl), down(overlay.tr), down(overlay.br), down(overlay.bl));
  final mag = _sobelMag(gray);
  final center = _centroid(q);

  _Line? line(im.Point a, im.Point b) {
    final pts = _sampleEdge(gray, w, h, a, b, center);
    return _fitLine(pts);
  }

  final top = line(q.tl, q.tr);
  final right = line(q.tr, q.br);
  final bottom = line(q.br, q.bl);
  final left = line(q.bl, q.tl);
  if (top == null || right == null || bottom == null || left == null) return null;
  final tr = _intersect(top, right);
  final br = _intersect(right, bottom);
  final bl = _intersect(bottom, left);
  final tl = _intersect(left, top);
  if (tr == null || br == null || bl == null || tl == null) return null;
  im.Point up(im.Point p) => im.Point(p.x * scale, p.y * scale);
  return Quad(up(tl), up(tr), up(br), up(bl));
}

List<im.Point> _sampleEdge(
  im.Image gray,
  int w,
  int h,
  im.Point a,
  im.Point b,
  im.Point center,
) {
  final ex = (b.x - a.x).toDouble();
  final ey = (b.y - a.y).toDouble();
  final elen = math.sqrt(ex * ex + ey * ey);
  if (elen < 2) return const [];
  var nx = ey / elen;
  var ny = -ex / elen;
  final mx = (a.x + b.x) / 2;
  final my = (a.y + b.y) / 2;
  if ((mx - center.x) * nx + (my - center.y) * ny < 0) {
    nx = -nx;
    ny = -ny;
  }
  final search = (elen * 0.55).clamp(22.0, 130.0);
  final steps = search.round();
  const n = 32;
  double lumAt(double x, double y) {
    final xi = x.round().clamp(0, w - 1);
    final yi = y.round().clamp(0, h - 1);
    return gray.getPixel(xi, yi).luminance.toDouble();
  }

  // Walk from outside toward the card; first luminance that matches the
  // interior is the outer border (not a pip).
  final offsets = <int>[];
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    if (t < 0.12 || t > 0.88) continue;
    final px = a.x + t * ex;
    final py = a.y + t * ey;
    final cardLum = lumAt(px - (steps / 3) * nx, py - (steps / 3) * ny);
    var bestS = 0;
    var found = false;
    for (var s = steps; s >= -steps; s--) {
      final lum = lumAt(px + s * nx, py + s * ny);
      if ((lum - cardLum).abs() < 28) {
        bestS = s;
        found = true;
        break;
      }
    }
    if (found) offsets.add(bestS);
  }
  if (offsets.length < 5) return const [];
  offsets.sort();
  final median = offsets[offsets.length ~/ 2];
  final pts = <im.Point>[];
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    if (t < 0.12 || t > 0.88) continue;
    pts.add(im.Point(a.x + t * ex + median * nx, a.y + t * ey + median * ny));
  }
  return pts;
}

class _Line {
  _Line(this.px, this.py, this.dx, this.dy);
  final double px, py, dx, dy;
}

_Line? _fitLine(List<im.Point> pts) {
  if (pts.length < 5) return null;
  var mx = 0.0, my = 0.0;
  for (final p in pts) {
    mx += p.x;
    my += p.y;
  }
  mx /= pts.length;
  my /= pts.length;
  var xx = 0.0, xy = 0.0, yy = 0.0;
  for (final p in pts) {
    final dx = p.x - mx;
    final dy = p.y - my;
    xx += dx * dx;
    xy += dx * dy;
    yy += dy * dy;
  }
  final trace = xx + yy;
  final det = xx * yy - xy * xy;
  final disc = math.max(0.0, trace * trace / 4 - det);
  final l1 = trace / 2 + math.sqrt(disc);
  late double dx, dy;
  if (xy.abs() > 1e-6) {
    dx = xy;
    dy = l1 - xx;
  } else if (xx >= yy) {
    dx = 1;
    dy = 0;
  } else {
    dx = 0;
    dy = 1;
  }
  final n = math.sqrt(dx * dx + dy * dy);
  if (n < 1e-8) return null;
  return _Line(mx, my, dx / n, dy / n);
}

im.Point? _intersect(_Line a, _Line b) {
  final det = a.dx * b.dy - a.dy * b.dx;
  if (det.abs() < 1e-8) return null;
  final t = ((b.px - a.px) * b.dy - (b.py - a.py) * b.dx) / det;
  return im.Point(a.px + t * a.dx, a.py + t * a.dy);
}

WarpResult warpJpeg(Uint8List bytes) {
  final decoded = im.decodeJpg(bytes);
  if (decoded == null) {
    return WarpResult(jpeg: bytes, warped: false);
  }
  im.Image src = im.bakeOrientation(decoded);
  final quad = detectCardQuad(src);
  if (quad == null) {
    final out = Uint8List.fromList(im.encodeJpg(src, quality: 92));
    return WarpResult(jpeg: out, warped: false);
  }
  final warped = warpPerspective(src, quad, warpWidth, warpHeight);
  final out = Uint8List.fromList(im.encodeJpg(warped, quality: 92));
  return WarpResult(jpeg: out, warped: true);
}

Quad? detectCardQuad(
  im.Image src, {
  double minFrac = 0.14,
  double maxFrac = 0.48,
}) {
  final maxSide = 640;
  final scale = math.max(src.width, src.height) / maxSide;
  final w = math.max(1, (src.width / scale).round());
  final h = math.max(1, (src.height / scale).round());
  final small = im.copyResize(src, width: w, height: h, interpolation: im.Interpolation.linear);
  final gray = im.grayscale(small);
  final blurred = im.gaussianBlur(gray, radius: 1);

  Quad? fromBright = _quadFromBrightBlob(blurred, minFrac, maxFrac);
  Quad? fromBlob = _quadFromAdaptiveBlob(blurred, minFrac, maxFrac);
  Quad? fromEdges = _quadFromEdges(blurred);
  Quad? chosen = _pickQuad(
    fromBright,
    _pickQuad(fromBlob, fromEdges, w, h, minFrac, maxFrac),
    w,
    h,
    minFrac,
    maxFrac,
  );
  if (chosen == null) return null;

  im.Point up(im.Point p) =>
      im.Point((p.x * scale).round(), (p.y * scale).round());
  var full = Quad(up(chosen.tl), up(chosen.tr), up(chosen.br), up(chosen.bl));
  full = _orderAndOrient(full);
  if (!_aspectOk(full)) return null;
  return full;
}

Quad? _pickQuad(
  Quad? a,
  Quad? b,
  int w,
  int h, [
  double minFrac = 0.14,
  double maxFrac = 0.48,
]) {
  double score(Quad q) {
    final area = _quadArea(q).abs();
    final imgArea = w * h.toDouble();
    final frac = area / imgArea;
    if (frac < minFrac || frac > maxFrac) return 0;
    if (!_aspectOk(_orderAndOrient(q))) return 0;
    // Inside the guide, the whole card beats a corner/pip crop.
    return frac;
  }

  final sa = a == null ? 0.0 : score(a);
  final sb = b == null ? 0.0 : score(b);
  if (sa <= 0 && sb <= 0) return null;
  return sa >= sb ? a : b;
}

Quad? _quadFromBrightBlob(im.Image gray, [double minFrac = 0.14, double maxFrac = 0.48]) {
  final w = gray.width, h = gray.height;
  var sum = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      sum += gray.getPixel(x, y).luminance.toInt();
    }
  }
  final mean = sum / (w * h);
  Quad? fromThresh(bool bright) {
    final mask = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final lum = gray.getPixel(x, y).luminance.toInt();
        mask[y * w + x] = bright
            ? (lum >= math.max(165, mean + 40) ? 1 : 0)
            : (lum <= math.min(70, mean - 40) ? 1 : 0);
      }
    }
    return _quadFromMask(mask, w, h);
  }

  return _pickQuad(fromThresh(true), fromThresh(false), w, h, minFrac, maxFrac);
}

Quad? _quadFromAdaptiveBlob(im.Image gray, [double minFrac = 0.14, double maxFrac = 0.48]) {
  final w = gray.width, h = gray.height;
  final mask = _adaptiveThreshold(gray, 15, 6);
  Quad? from(Uint8List m) => _quadFromMask(m, w, h);

  final a = from(mask);
  final inv = Uint8List.fromList(mask);
  for (var i = 0; i < inv.length; i++) {
    inv[i] = inv[i] == 0 ? 1 : 0;
  }
  final b = from(inv);
  return _pickQuad(a, b, w, h, minFrac, maxFrac);
}

Quad? _quadFromEdges(im.Image gray) {
  final w = gray.width, h = gray.height;
  final mag = _sobelMag(gray);
  var thresh = _percentile(mag, 0.88);
  if (thresh < 20) thresh = 20;
  final mask = Uint8List(w * h);
  for (var i = 0; i < mag.length; i++) {
    mask[i] = mag[i] >= thresh ? 1 : 0;
  }
  _dilate(mask, w, h);
  final component = _largestComponent(mask, w, h);
  if (component == null) return null;
  final hull = _convexHull(component);
  return _approxQuad(hull);
}

Uint8List _adaptiveThreshold(im.Image gray, int radius, int c) {
  final w = gray.width, h = gray.height;
  final integral = List<int>.filled((w + 1) * (h + 1), 0);
  int at(int x, int y) => integral[y * (w + 1) + x];
  for (var y = 1; y <= h; y++) {
    var row = 0;
    for (var x = 1; x <= w; x++) {
      row += gray.getPixel(x - 1, y - 1).luminance.toInt();
      integral[y * (w + 1) + x] = at(x, y - 1) + row;
    }
  }
  final mask = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - radius);
      final y0 = math.max(0, y - radius);
      final x1 = math.min(w - 1, x + radius);
      final y1 = math.min(h - 1, y + radius);
      final area = (x1 - x0 + 1) * (y1 - y0 + 1);
      final sum = at(x1 + 1, y1 + 1) - at(x0, y1 + 1) - at(x1 + 1, y0) + at(x0, y0);
      final mean = sum / area;
      final lum = gray.getPixel(x, y).luminance.toInt();
      mask[y * w + x] = lum < mean - c ? 1 : 0;
    }
  }
  return mask;
}

void _invertIfNeeded(Uint8List mask, int w, int h) {
  var white = 0;
  final n = mask.length;
  for (final v in mask) {
    white += v;
  }
  // Card should be the interior blob. If most pixels are "foreground", invert.
  if (white > n * 0.5) {
    for (var i = 0; i < n; i++) {
      mask[i] = mask[i] == 0 ? 1 : 0;
    }
  }
}

Int16List _sobelMag(im.Image gray) {
  final w = gray.width, h = gray.height;
  final mag = Int16List(w * h);
  int l(int x, int y) =>
      gray.getPixel(x.clamp(0, w - 1), y.clamp(0, h - 1)).luminance.toInt();
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final gx = -l(x - 1, y - 1) + l(x + 1, y - 1) +
          -2 * l(x - 1, y) + 2 * l(x + 1, y) +
          -l(x - 1, y + 1) + l(x + 1, y + 1);
      final gy = -l(x - 1, y - 1) - 2 * l(x, y - 1) - l(x + 1, y - 1) +
          l(x - 1, y + 1) + 2 * l(x, y + 1) + l(x + 1, y + 1);
      mag[y * w + x] = math.sqrt(gx * gx + gy * gy).round();
    }
  }
  return mag;
}

int _percentile(Int16List mag, double p) {
  final copy = mag.where((v) => v > 0).toList()..sort();
  if (copy.isEmpty) return 0;
  final i = (copy.length * p).floor().clamp(0, copy.length - 1);
  return copy[i];
}

void _dilate(Uint8List mask, int w, int h) {
  final out = Uint8List.fromList(mask);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      if (mask[y * w + x] == 1) continue;
      var hit = false;
      for (var dy = -1; dy <= 1 && !hit; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (mask[(y + dy) * w + (x + dx)] == 1) {
            hit = true;
            break;
          }
        }
      }
      if (hit) out[y * w + x] = 1;
    }
  }
  mask.setAll(0, out);
}

List<im.Point>? _largestComponent(Uint8List mask, int w, int h) {
  final seen = Uint8List(w * h);
  var best = <im.Point>[];
  final stackX = <int>[];
  final stackY = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (mask[i] == 0 || seen[i] == 1) continue;
      stackX
        ..clear()
        ..add(x);
      stackY
        ..clear()
        ..add(y);
      seen[i] = 1;
      final pts = <im.Point>[];
      while (stackX.isNotEmpty) {
        final cx = stackX.removeLast();
        final cy = stackY.removeLast();
        pts.add(im.Point(cx, cy));
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx, ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final ni = ny * w + nx;
            if (mask[ni] == 0 || seen[ni] == 1) continue;
            seen[ni] = 1;
            stackX.add(nx);
            stackY.add(ny);
          }
        }
      }
      if (pts.length > best.length) best = pts;
    }
  }
  if (best.length < 50) return null;
  return best;
}

List<im.Point> _convexHull(List<im.Point> pts) {
  final sorted = [...pts]..sort((a, b) {
      if (a.x != b.x) return a.x.compareTo(b.x);
      return a.y.compareTo(b.y);
    });
  // Dedup
  final uniq = <im.Point>[];
  for (final p in sorted) {
    if (uniq.isEmpty || uniq.last.x != p.x || uniq.last.y != p.y) uniq.add(p);
  }
  if (uniq.length <= 3) return uniq;

  num cross(im.Point o, im.Point a, im.Point b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

  final lower = <im.Point>[];
  for (final p in uniq) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <im.Point>[];
  for (final p in uniq.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

void _erode(Uint8List mask, int w, int h) {
  final out = Uint8List(w * h);
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      if (mask[y * w + x] == 0) continue;
      var keep = true;
      for (var dy = -1; dy <= 1 && keep; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (mask[(y + dy) * w + x + dx] == 0) {
            keep = false;
            break;
          }
        }
      }
      if (keep) out[y * w + x] = 1;
    }
  }
  mask.setAll(0, out);
}

Quad? _quadFromMask(Uint8List mask, int w, int h) {
  _erode(mask, w, h);
  final component = _largestComponent(mask, w, h);
  if (component == null) return null;
  final hull = _convexHull(component);
  return _minAreaQuad(hull) ?? _approxQuad(hull);
}

Quad _tightenToWhite(im.Image gray, Quad q) {
  final c = _centroid(q);
  final w = gray.width, h = gray.height;
  int lumAt(double x, double y) {
    final xi = x.round().clamp(0, w - 1);
    final yi = y.round().clamp(0, h - 1);
    return gray.getPixel(xi, yi).luminance.toInt();
  }

  final inLum = lumAt(c.x.toDouble(), c.y.toDouble());
  var outSum = 0, outN = 0;
  void sampleOut(im.Point a, im.Point b) {
    final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    final dx = mx - c.x, dy = my - c.y;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 2) return;
    outSum += lumAt(mx + dx / len * 10, my + dy / len * 10);
    outN++;
  }

  sampleOut(q.tl, q.tr);
  sampleOut(q.tr, q.br);
  sampleOut(q.br, q.bl);
  sampleOut(q.bl, q.tl);
  final outLum = outN == 0 ? 128 : outSum / outN;
  final darkCard = inLum < outLum;
  final thresh = (inLum + outLum) / 2;
  bool onCard(double x, double y) {
    final lum = lumAt(x, y);
    return darkCard ? lum <= thresh : lum >= thresh;
  }

  // Keep the rectangle; only slide edges inward until they sit on card stock.
  Quad cur = q;
  im.Point edgeWalk(im.Point a, im.Point b) {
    final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    final dx = (c.x - mx).toDouble(), dy = (c.y - my).toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 2) return im.Point(0, 0);
    return im.Point(dx / len, dy / len);
  }

  Quad shift(Quad q0, double t) {
    im.Point s(im.Point p, im.Point n) => im.Point(p.x + n.x * t, p.y + n.y * t);
    final nTop = edgeWalk(q0.tl, q0.tr);
    final nRight = edgeWalk(q0.tr, q0.br);
    final nBot = edgeWalk(q0.br, q0.bl);
    final nLeft = edgeWalk(q0.bl, q0.tl);
    return Quad(
      s(s(q0.tl, nTop), nLeft),
      s(s(q0.tr, nTop), nRight),
      s(s(q0.br, nBot), nRight),
      s(s(q0.bl, nBot), nLeft),
    );
  }

  double edgeFrac(im.Point a, im.Point b) {
    var hit = 0, n = 0;
    for (var i = 2; i <= 10; i++) {
      final t = i / 12.0;
      n++;
      if (onCard(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)) hit++;
    }
    return hit / n;
  }

  for (var step = 0; step < 80; step++) {
    final top = edgeFrac(cur.tl, cur.tr);
    final right = edgeFrac(cur.tr, cur.br);
    final bot = edgeFrac(cur.br, cur.bl);
    final left = edgeFrac(cur.bl, cur.tl);
    if (top >= 0.9 && right >= 0.9 && bot >= 0.9 && left >= 0.9) break;
    cur = shift(cur, 1.2);
  }
  return cur;
}

Quad _insetQuad(Quad q, double f) {
  final c = _centroid(q);
  im.Point inn(im.Point p) => im.Point(
        p.x + (c.x - p.x) * f,
        p.y + (c.y - p.y) * f,
      );
  return Quad(inn(q.tl), inn(q.tr), inn(q.br), inn(q.bl));
}

Quad? _minAreaQuad(List<im.Point> pts) {
  if (pts.length < 4) return null;
  var bestArea = double.infinity;
  Quad? best;
  for (var deg = 0; deg < 180; deg++) {
    final a = deg * math.pi / 180.0;
    final c = math.cos(a);
    final s = math.sin(a);
    var minX = 1e18, maxX = -1e18, minY = 1e18, maxY = -1e18;
    for (final p in pts) {
      final xr = p.x * c + p.y * s;
      final yr = -p.x * s + p.y * c;
      if (xr < minX) minX = xr.toDouble();
      if (xr > maxX) maxX = xr.toDouble();
      if (yr < minY) minY = yr.toDouble();
      if (yr > maxY) maxY = yr.toDouble();
    }
    final area = (maxX - minX) * (maxY - minY);
    if (area <= 0 || area >= bestArea) continue;
    bestArea = area;
    im.Point un(double xr, double yr) =>
        im.Point(xr * c - yr * s, xr * s + yr * c);
    best = _orderQuad([
      un(minX, minY),
      un(maxX, minY),
      un(maxX, maxY),
      un(minX, maxY),
    ]);
  }
  return best;
}

Quad? _approxQuad(List<im.Point> hull) {
  if (hull.length < 4) return null;
  if (hull.length == 4) return _orderQuad(hull);
  var peri = 0.0;
  for (var i = 0; i < hull.length; i++) {
    peri += _dist(hull[i], hull[(i + 1) % hull.length]);
  }
  for (final frac in [0.02, 0.03, 0.04, 0.06, 0.08, 0.1, 0.14, 0.2]) {
    final approx = _rdp(hull, frac * peri);
    if (approx.length == 4) return _orderQuad(approx);
  }
  return _maxAreaQuad(hull);
}

List<im.Point> _rdp(List<im.Point> pts, double eps) {
  if (pts.length < 3) return pts;
  var maxD = 0.0;
  var idx = 0;
  final a = pts.first;
  final b = pts.last;
  for (var i = 1; i < pts.length - 1; i++) {
    final d = _perpDist(pts[i], a, b);
    if (d > maxD) {
      maxD = d;
      idx = i;
    }
  }
  if (maxD > eps) {
    final left = _rdp(pts.sublist(0, idx + 1), eps);
    final right = _rdp(pts.sublist(idx), eps);
    return [...left.sublist(0, left.length - 1), ...right];
  }
  return [a, b];
}

double _perpDist(im.Point p, im.Point a, im.Point b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final mag = math.sqrt(dx * dx + dy * dy);
  if (mag == 0) return _dist(p, a);
  return ((dy * p.x - dx * p.y + b.x * a.y - b.y * a.x).abs()) / mag;
}

Quad? _maxAreaQuad(List<im.Point> hull) {
  final n = hull.length;
  if (n > 24) {
    // subsample hull
    final step = (n / 16).ceil();
    final slim = <im.Point>[];
    for (var i = 0; i < n; i += step) {
      slim.add(hull[i]);
    }
    return _maxAreaQuad(slim);
  }
  double best = 0;
  Quad? q;
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      for (var k = j + 1; k < n; k++) {
        for (var m = k + 1; m < n; m++) {
          final cand = _orderQuad([hull[i], hull[j], hull[k], hull[m]]);
          final a = _quadArea(cand);
          if (a > best) {
            best = a;
            q = cand;
          }
        }
      }
    }
  }
  return q;
}

Quad _orderQuad(List<im.Point> pts) {
  im.Point tl = pts[0], tr = pts[0], br = pts[0], bl = pts[0];
  num minSum = 1 << 30, maxSum = -1 << 30, minDiff = 1 << 30, maxDiff = -1 << 30;
  for (final p in pts) {
    final s = p.x + p.y;
    final d = p.x - p.y;
    if (s < minSum) {
      minSum = s;
      tl = p;
    }
    if (s > maxSum) {
      maxSum = s;
      br = p;
    }
    if (d > maxDiff) {
      maxDiff = d;
      tr = p;
    }
    if (d < minDiff) {
      minDiff = d;
      bl = p;
    }
  }
  return Quad(tl, tr, br, bl);
}

Quad _orderAndOrient(Quad q) {
  var ordered = _orderQuad(q.points);
  final w = (_dist(ordered.tl, ordered.tr) + _dist(ordered.bl, ordered.br)) / 2;
  final h = (_dist(ordered.tl, ordered.bl) + _dist(ordered.tr, ordered.br)) / 2;
  if (w > h) {
    // rotate so height > width (portrait card)
    ordered = Quad(ordered.bl, ordered.tl, ordered.tr, ordered.br);
  }
  return ordered;
}

bool _aspectOk(Quad q) {
  final w = (_dist(q.tl, q.tr) + _dist(q.bl, q.br)) / 2;
  final h = (_dist(q.tl, q.bl) + _dist(q.tr, q.br)) / 2;
  if (w < 8 || h < 8) return false;
  final r = h / w;
  return r >= 1.2 && r <= 1.85;
}

double _quadArea(Quad q) {
  // two triangles
  return (_tri(q.tl, q.tr, q.br) + _tri(q.tl, q.br, q.bl)).abs();
}

double _tri(im.Point a, im.Point b, im.Point c) =>
    ((a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y)) / 2.0);

double _dist(im.Point a, im.Point b) {
  final dx = (a.x - b.x).toDouble();
  final dy = (a.y - b.y).toDouble();
  return math.sqrt(dx * dx + dy * dy);
}

im.Image warpPerspective(im.Image src, Quad quad, int dw, int dh) {
  final h = _homography(
    [
      im.Point(0, 0),
      im.Point(dw - 1, 0),
      im.Point(dw - 1, dh - 1),
      im.Point(0, dh - 1),
    ],
    quad.points,
  );
  final out = im.Image(width: dw, height: dh, numChannels: 3);
  final sw = src.width, sh = src.height;
  for (var y = 0; y < dh; y++) {
    for (var x = 0; x < dw; x++) {
      final denom = h[6] * x + h[7] * y + 1.0;
      final sx = (h[0] * x + h[1] * y + h[2]) / denom;
      final sy = (h[3] * x + h[4] * y + h[5]) / denom;
      out.setPixel(x, y, _sampleBilinear(src, sx, sy, sw, sh));
    }
  }
  return out;
}

im.Color _sampleBilinear(im.Image src, double x, double y, int w, int h) {
  if (x < 0 || y < 0 || x >= w - 1 || y >= h - 1) {
    final xi = x.round().clamp(0, w - 1);
    final yi = y.round().clamp(0, h - 1);
    return src.getPixel(xi, yi);
  }
  final x0 = x.floor();
  final y0 = y.floor();
  final x1 = x0 + 1;
  final y1 = y0 + 1;
  final fx = x - x0;
  final fy = y - y0;
  final c00 = src.getPixel(x0, y0);
  final c10 = src.getPixel(x1, y0);
  final c01 = src.getPixel(x0, y1);
  final c11 = src.getPixel(x1, y1);
  int ch(int Function(im.Color c) g) {
    final v = g(c00) * (1 - fx) * (1 - fy) +
        g(c10) * fx * (1 - fy) +
        g(c01) * (1 - fx) * fy +
        g(c11) * fx * fy;
    return v.round().clamp(0, 255);
  }

  return src.getColor(
    ch((c) => c.r.toInt()),
    ch((c) => c.g.toInt()),
    ch((c) => c.b.toInt()),
  );
}

/// Maps dest points → source points. Returns h0..h7 with h8 = 1.
List<double> _homography(List<im.Point> dest, List<im.Point> src) {
  final a = List.generate(8, (_) => List<double>.filled(8, 0));
  final b = List<double>.filled(8, 0);
  for (var i = 0; i < 4; i++) {
    final x = dest[i].x.toDouble();
    final y = dest[i].y.toDouble();
    final u = src[i].x.toDouble();
    final v = src[i].y.toDouble();
    final r = i * 2;
    a[r][0] = x;
    a[r][1] = y;
    a[r][2] = 1;
    a[r][6] = -u * x;
    a[r][7] = -u * y;
    b[r] = u;
    a[r + 1][3] = x;
    a[r + 1][4] = y;
    a[r + 1][5] = 1;
    a[r + 1][6] = -v * x;
    a[r + 1][7] = -v * y;
    b[r + 1] = v;
  }
  return _solve(a, b);
}

List<double> _solve(List<List<double>> a, List<double> b) {
  final n = 8;
  final m = List.generate(n, (i) => [...a[i], b[i]]);
  for (var col = 0; col < n; col++) {
    var pivot = col;
    var best = m[col][col].abs();
    for (var row = col + 1; row < n; row++) {
      final v = m[row][col].abs();
      if (v > best) {
        best = v;
        pivot = row;
      }
    }
    if (best < 1e-12) {
      return List<double>.filled(n, 0);
    }
    if (pivot != col) {
      final tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
    }
    final div = m[col][col];
    for (var j = col; j <= n; j++) {
      m[col][j] /= div;
    }
    for (var row = 0; row < n; row++) {
      if (row == col) continue;
      final f = m[row][col];
      for (var j = col; j <= n; j++) {
        m[row][j] -= f * m[col][j];
      }
    }
  }
  return List<double>.generate(n, (i) => m[i][n]);
}
