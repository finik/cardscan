import 'dart:io';
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

/// File-in / file-out variant, used by the long-lived warp worker isolate.
///
/// Reads the still from [srcPath] and writes the warped JPEG to [outPath], so
/// the multi-megabyte camera still never crosses an isolate boundary.
/// Returns `[String outPath, bool warped]`.
List<dynamic> cropFileToFrame(Map<Object?, Object?> args) {
  final srcPath = args['srcPath'] as String;
  final outPath = args['outPath'] as String;
  final bytes = File(srcPath).readAsBytesSync();
  final sw = Stopwatch()..start();
  final res = cropToFrameIsolate({...args, 'jpeg': bytes});
  File(outPath).writeAsBytesSync(res[0] as Uint8List);
  // ignore: avoid_print
  print('cscan WARP total=${sw.elapsedMilliseconds}ms warped=${res[1]}');
  return [outPath, res[1] as bool];
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
  final sw = Stopwatch()..start();
  final decoded = im.decodeJpg(jpeg);
  if (decoded == null) return [jpeg, false];
  final src = decoded;
  final decodeMs = sw.elapsedMilliseconds;
  final viewW = (args['viewW'] as num).toDouble();
  final viewH = (args['viewH'] as num).toDouble();
  final left = (args['left'] as num).toDouble();
  final top = (args['top'] as num).toDouble();
  final right = (args['right'] as num).toDouble();
  final bottom = (args['bottom'] as num).toDouble();

  final overlay = _viewRectToQuad(
    src, viewW, viewH, left, top, right, bottom,
    previewW: (args['previewW'] as num?)?.toDouble() ?? 0,
    previewH: (args['previewH'] as num?)?.toDouble() ?? 0,
  );
  final found = findCardRect(src, overlay);
  final rect = found;
  final quad = _insetQuad(rect ?? overlay, cardMargin);
  final detectMs = sw.elapsedMilliseconds - decodeMs;
  final outImg = warpPerspective(src, quad, warpWidth, warpHeight);
  final out = Uint8List.fromList(im.encodeJpg(outImg, quality: 95));
  final quadW = (_dist(quad.tl, quad.tr) + _dist(quad.bl, quad.br)) / 2;
  final quadH = (_dist(quad.tl, quad.bl) + _dist(quad.tr, quad.br)) / 2;
  final tilt = math.atan2(
          quad.tr.y.toDouble() - quad.tl.y.toDouble(),
          quad.tr.x.toDouble() - quad.tl.x.toDouble()) *
      180 /
      math.pi;
  // ignore: avoid_print
  print('cscan warp ${src.width}x${src.height} card=${quadW.round()}x${quadH.round()} '
      'found=${rect != null} tilt=${tilt.toStringAsFixed(2)} '
      'decode=${decodeMs}ms detect=${detectMs}ms '
      'rest=${sw.elapsedMilliseconds - decodeMs - detectMs}ms');
  return [out, true];
}

/// A playing card is 5:7. The edge search does not know that, and returns
/// quads whose aspect wanders (0.66-0.71 measured across consecutive shots of
/// the same deck), which the warp then stretches into a 5:7 output by a
/// different amount every time — cards come out inconsistently distorted.
///
/// Keep the detected centre and rotation, which are reliable, and fix the
/// proportions: whichever side is short for a card is expanded to match. It
/// expands rather than shrinks because including a sliver of background is
/// recoverable and clipping the card is not.
///
/// A quad more than [_aspectTolerance] away from 5:7 is not a card at all;
/// callers get it back untouched so the overlay fallback still applies.
const cardAspect = warpWidth / warpHeight; // 1000/1400 = 5:7

/// 0 = warp the fitted sides of the card. Negative would pull in table;
/// positive clips the rounded corners.
const cardMargin = 0.0;

/// The guide and the detected card quad, for drawing on a debug still.
(Quad, Quad?) debugCardRect(im.Image src, Map<String, dynamic> args) {
  final overlay = _viewRectToQuad(
    src,
    (args['viewW'] as num).toDouble(),
    (args['viewH'] as num).toDouble(),
    (args['left'] as num).toDouble(),
    (args['top'] as num).toDouble(),
    (args['right'] as num).toDouble(),
    (args['bottom'] as num).toDouble(),
    previewW: (args['previewW'] as num?)?.toDouble() ?? 0,
    previewH: (args['previewH'] as num?)?.toDouble() ?? 0,
  );
  final found = findCardRect(src, overlay);
  return (overlay, found);
}


/// Locate the card inside the guide as pixels unlike the table, then fit a quad.
///
/// This replaces a stack of per-edge heuristics. A card is a bright convex
/// shape on a darker surface, so the whole problem is: separate it from the
/// surface, take the biggest piece, and find the rectangle that encloses it.
/// Position, size and rotation all fall out of that rectangle, and there is
/// nothing to tune per edge or per direction.

/// Canvas used to look for the card's edges. The guide is warped to this, so
/// the card sits roughly axis-aligned and each side can be scanned by rows.
const _scanW = 900;
const _scanH = 1260;

/// Find the card by its edges rather than by its tone.
///
/// Thresholding the guide into "card" and "surface" only works when the two
/// differ in brightness. A cream card on a pale table, or a black card on a
/// dark one, splits somewhere inside the card instead and the detected shape
/// collapses onto the artwork. The card's *boundary*, though, is a step in
/// intensity whatever the two tones are and whichever way round they run.
///
/// So: flatten the guide, scan inwards from each side for that step, take the
/// outermost consistent one per scanline, and fit a line to each side. The
/// direction of the step is decided by majority vote across the scanlines, so
/// nothing here assumes the card is lighter or darker than what it sits on.
/// Why the last findCardByEdges call gave up, for diagnostics.
String? lastEdgeFailure;

Quad? findCardByEdges(im.Image src, Quad guide) {
  lastEdgeFailure = null;
  Quad? give(String why) {
    lastEdgeFailure = why;
    return null;
  }

  final canvas = im.grayscale(warpPerspective(src, guide, _scanW, _scanH));
  final lum = Uint8List(_scanW * _scanH);
  for (var y = 0; y < _scanH; y++) {
    for (var x = 0; x < _scanW; x++) {
      lum[y * _scanW + x] = canvas.getPixel(x, y).r.toInt();
    }
  }
  double at(int x, int y) => lum[y * _scanW + x].toDouble();

  /// Gradient across the boundary at [d] along a scanline, positive when the
  /// inward side is brighter.
  double gradient(int d, int fixed, bool horizontal, bool fromEnd) {
    double mean(int from, int to, int dir) {
      var sum = 0.0;
      var n = 0;
      for (var k = from; k <= to; k++) {
        final p = fromEnd ? d - dir * k : d + dir * k;
        final q = p.clamp(0, (horizontal ? _scanW : _scanH) - 1);
        sum += horizontal ? at(q, fixed) : at(fixed, q);
        n++;
      }
      return sum / n;
    }

    return mean(2, 6, 1) - mean(2, 6, -1); // inward minus outward
  }

  /// Candidate crossings for one side, then the line they agree on.
  ///
  /// One threshold cannot separate the card's edge from what is printed on it:
  /// set it high and a cream card on a pale table is missed in favour of its
  /// artwork, set it low and shading on the table triggers instead. So collect
  /// every plausible crossing on every scanline and let consensus decide —
  /// only the card's edge is a straight line that nearly all scanlines see.
  List<List<im.Point>>? side(bool horizontal, bool fromEnd) {
    final alongMax = horizontal ? _scanH : _scanW;
    final depthMax = horizontal ? _scanW : _scanH;
    final limit = (depthMax * 0.46).round();
    final lines = [
      for (var i = 0; i < 46; i++) (alongMax * (0.10 + 0.80 * i / 45)).round()
    ];

    // Which way the step runs is decided by majority, so neither a light card
    // on a dark table nor the reverse is assumed.
    final peaks = <double>[];
    var positive = 0, negative = 0;
    for (final l in lines) {
      var best = 0.0, bestG = 0.0;
      for (var d = 8; d < limit; d++) {
        final p = fromEnd ? depthMax - 1 - d : d;
        final g = gradient(p, l, horizontal, fromEnd);
        if (g.abs() > best) {
          best = g.abs();
          bestG = g;
        }
      }
      peaks.add(best);
      if (bestG > 0) {
        positive++;
      } else {
        negative++;
      }
    }
    if (peaks.isEmpty) return null;
    final sortedPeaks = [...peaks]..sort();
    final strong = sortedPeaks[(sortedPeaks.length * 0.6).floor()];
    final floor = math.max(2.5, strong * 0.08);
    final sign = positive >= negative ? 1.0 : -1.0;

    // Local maxima above the floor, on every scanline, with how sharp each is.
    final cands = <im.Point>[];
    final strength = <double>[];
    for (final l in lines) {
      final here = <(double, double)>[];
      var prev = 0.0, prevPrev = 0.0;
      for (var d = 8; d < limit; d++) {
        final p = fromEnd ? depthMax - 1 - d : d;
        final g = gradient(p, l, horizontal, fromEnd) * sign;
        if (d > 9 && prev >= floor && prev >= g && prev >= prevPrev) {
          final pk = fromEnd ? depthMax - 1 - (d - 1) : d - 1;
          here.add((pk.toDouble(), prev));
        }
        prevPrev = prev;
        prev = g;
      }
      // Cap how far in to look. Everything printed on the card lies inside
      // its edge, so the boundary is among the outermost crossings — but a
      // shaded table can contribute several of its own before it, and keeping
      // too few dropped the real edge entirely on cards that sit on grey.
      for (final (d, g) in here.take(8)) {
        cands.add(horizontal
            ? im.Point(d, l.toDouble())
            : im.Point(l.toDouble(), d));
        strength.add(g);
      }
    }
    if (cands.length < 8) return null;

    // Consensus. Deterministic pseudo-random pairs, so runs are repeatable.
    var seed = 12345;
    int rnd(int n) {
      seed = (seed * 1103515245 + 12345) & 0x3FFFFFFF;
      return seed % n;
    }

    // Keep several distinct candidate lines per side. Choosing each side on
    // its own picks whatever looks most line-like, which on a low-contrast
    // card can be a band of shading on the table; the four sides are only
    // decided together, once it is known which combination forms a card.
    final models = <(List<im.Point>, double, double)>[]; // inliers, sharp, depth
    for (var iter = 0; iter < 2200; iter++) {
      final a = cands[rnd(cands.length)], b = cands[rnd(cands.length)];
      final dx = b.x.toDouble() - a.x.toDouble();
      final dy = b.y.toDouble() - a.y.toDouble();
      final len = math.sqrt(dx * dx + dy * dy);
      if (len < alongMax * 0.3) continue; // need a long baseline to be a side
      final ux = dx / len, uy = dy / len;
      // The card is laid in the guide, so its edges run within a few degrees
      // of the guide's own axes. Without this, a long diagonal in the artwork
      // can gather more support than the card's edge and the quad comes out
      // as a lozenge across the face.
      final offAxis = horizontal ? ux.abs() : uy.abs();
      if (offAxis > 0.15) continue; // ~8.5 degrees
      final inliers = <im.Point>[];
      var sharp = 0.0;
      for (var k = 0; k < cands.length; k++) {
        final c = cands[k];
        final ex = c.x.toDouble() - a.x.toDouble();
        final ey = c.y.toDouble() - a.y.toDouble();
        if ((ex * uy - ey * ux).abs() <= 3.5) {
          inliers.add(c);
          sharp += strength[k];
        }
      }
      if (inliers.length < lines.length * 0.30) continue;
      final meanSharp = sharp / inliers.length;
      final meanDepth = inliers
              .map((c) => horizontal ? c.x.toDouble() : c.y.toDouble())
              .reduce((x, y) => x + y) /
          inliers.length;
      // Keep it if it is a new position, or better than what is held there.
      var merged = false;
      for (var k = 0; k < models.length; k++) {
        if ((models[k].$3 - meanDepth).abs() < 12) {
          if (inliers.length > models[k].$1.length) {
            models[k] = (inliers, meanSharp, meanDepth);
          }
          merged = true;
          break;
        }
      }
      if (!merged) models.add((inliers, meanSharp, meanDepth));
    }
    if (models.isEmpty) return null;
    models.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    return [for (final m in models.take(4)) m.$1];
  }

  final left = side(true, false);
  final right = side(true, true);
  final top = side(false, false);
  final bottom = side(false, true);
  if (left == null || right == null || top == null || bottom == null) {
    return give('no consensus on '
        '${[if (top == null) 'top', if (right == null) 'right', if (bottom == null) 'bottom', if (left == null) 'left'].join('/')}');
  }

  im.Point? meet((double, double, double, double) p, (double, double, double, double) q) {
    final (px, py, dx, dy) = p;
    final (qx, qy, ex, ey) = q;
    final den = dx * ey - dy * ex;
    if (den.abs() < 1e-9) return null;
    final t = ((qx - px) * ey - (qy - py) * ex) / den;
    return im.Point(px + dx * t, py + dy * t);
  }

  // Try every combination and keep the one that actually looks like a card:
  // 5:7, filling a sensible part of the guide, with the most scanline support.
  const cardShape = warpWidth / warpHeight;
  Quad? bestQuad;
  var bestScore = double.negativeInfinity;
  for (final t in top) {
    for (final r in right) {
      for (final b in bottom) {
        for (final l in left) {
          final ft = _fitTls(t), fr = _fitTls(r);
          final fb = _fitTls(b), fl = _fitTls(l);
          if (ft == null || fr == null || fb == null || fl == null) continue;
          final tl = meet(fl, ft), tr = meet(ft, fr);
          final br = meet(fr, fb), bl = meet(fb, fl);
          if (tl == null || tr == null || br == null || bl == null) continue;
          final w = (_dist(tl, tr) + _dist(bl, br)) / 2;
          final h = (_dist(tl, bl) + _dist(tr, br)) / 2;
          if (w < _scanW * 0.45 || h < _scanH * 0.45) continue;
          if (w > _scanW * 1.02 || h > _scanH * 1.02) continue;
          final aspect = w / h;
          if (aspect < 0.60 || aspect > 0.85) continue;
          final support = (t.length + r.length + b.length + l.length).toDouble();

          // Does this quad behave like a card? Just inside every edge should
          // look like the same surface as just inside every other edge — the
          // card — and each edge should separate that from something else.
          // Tuning how many crossings to consider only ever traded one failure
          // for another; this asks the question directly.
          final quadPts = [tl, tr, br, bl];
          final qcx = quadPts.map((p) => p.x.toDouble()).reduce((x, y) => x + y) / 4;
          final qcy = quadPts.map((p) => p.y.toDouble()).reduce((x, y) => x + y) / 4;
          final insides = <double>[];
          var contrast = 0.0;
          var ok = true;
          for (var e = 0; e < 4 && ok; e++) {
            final a = quadPts[e], bb = quadPts[(e + 1) % 4];
            final ex = bb.x.toDouble() - a.x.toDouble();
            final ey = bb.y.toDouble() - a.y.toDouble();
            final el = math.sqrt(ex * ex + ey * ey);
            if (el < 1) {
              ok = false;
              break;
            }
            var nx = -ey / el, ny = ex / el;
            if ((a.x.toDouble() + nx - qcx) * nx + (a.y.toDouble() + ny - qcy) * ny < 0) {
              nx = -nx;
              ny = -ny;
            }
            var inSum = 0.0, outSum = 0.0;
            var n = 0;
            for (var i = 0; i < 21; i++) {
              final f = 0.2 + 0.6 * i / 20;
              final px = a.x.toDouble() + ex * f, py = a.y.toDouble() + ey * f;
              double sample(double off) {
                final sx = (px + nx * off).round().clamp(0, _scanW - 1);
                final sy = (py + ny * off).round().clamp(0, _scanH - 1);
                return lum[sy * _scanW + sx].toDouble();
              }

              inSum += sample(-9);
              outSum += sample(9);
              n++;
            }
            final inMean = inSum / n, outMean = outSum / n;
            insides.add(inMean);
            contrast += (inMean - outMean).abs();
          }
          if (!ok) continue;
          final inAvg = insides.reduce((x, y) => x + y) / insides.length;
          final inSpread = insides
              .map((v) => (v - inAvg).abs())
              .reduce((x, y) => x > y ? x : y);

          // An edge that has strayed onto the table makes its "inside" band
          // table-coloured, unlike the other three, so a large spread is the
          // strongest signal that a combination is wrong.
          final score = support -
              (aspect - cardShape).abs() * 900 +
              contrast * 0.35 -
              inSpread * 2.0;
          if (score > bestScore) {
            bestScore = score;
            bestQuad = Quad(tl, tr, br, bl);
          }
        }
      }
    }
  }
  if (bestQuad == null) return give('no card-shaped combination');
  final tl = bestQuad.tl, tr = bestQuad.tr, br = bestQuad.br, bl = bestQuad.bl;

  // Canvas coordinates back to the source, through the same homography.
  final hm = _homography(
    [
      im.Point(0, 0),
      im.Point(_scanW - 1, 0),
      im.Point(_scanW - 1, _scanH - 1),
      im.Point(0, _scanH - 1),
    ],
    guide.points,
  );
  im.Point toSrc(im.Point p) {
    final x = p.x.toDouble(), y = p.y.toDouble();
    final den = hm[6] * x + hm[7] * y + 1.0;
    return im.Point(
      (hm[0] * x + hm[1] * y + hm[2]) / den,
      (hm[3] * x + hm[4] * y + hm[5]) / den,
    );
  }

  return Quad(toSrc(tl), toSrc(tr), toSrc(br), toSrc(bl));
}

(double, double, double) _rgbHsv(double r, double g, double b) {
  final rd = r / 255, gd = g / 255, bd = b / 255;
  final max = math.max(rd, math.max(gd, bd));
  final min = math.min(rd, math.min(gd, bd));
  final d = max - min;
  var h = 0.0;
  if (d > 1e-6) {
    if (max == rd) {
      h = 60 * (((gd - bd) / d) % 6);
    } else if (max == gd) {
      h = 60 * ((bd - rd) / d + 2);
    } else {
      h = 60 * ((rd - gd) / d + 4);
    }
  }
  if (h < 0) h += 360;
  final s = max == 0 ? 0.0 : d / max;
  return (h, s, max);
}

bool _hueIsGreen(double h) => h >= 50 && h <= 170;
bool _hueIsOrange(double h) => h <= 50 || h >= 345;

/// Why the last findCardRect call gave up, for diagnostics.
String? lastCardRectFailure;

Quad? findCardRect(im.Image src, Quad guide) {
  lastCardRectFailure = null;
  Quad? fail(String why) {
    lastCardRectFailure = why;
    return null;
  }

  final xs = guide.points.map((p) => p.x.toDouble()).toList();
  final ys = guide.points.map((p) => p.y.toDouble()).toList();
  final x0 = xs.reduce(math.min).floor().clamp(0, src.width - 1);
  final x1 = xs.reduce(math.max).ceil().clamp(0, src.width - 1);
  final y0 = ys.reduce(math.min).floor().clamp(0, src.height - 1);
  final y1 = ys.reduce(math.max).ceil().clamp(0, src.height - 1);
  final cropW = x1 - x0, cropH = y1 - y0;
  if (cropW < 40 || cropH < 40) return fail('guide too small');

  // Work small: detection needs shape, not detail.
  const target = 700.0;
  final scale = math.min(1.0, target / math.max(cropW, cropH));
  final w = math.max(8, (cropW * scale).round());
  final h = math.max(8, (cropH * scale).round());
  final small = im.copyResize(
    im.copyCrop(src, x: x0, y: y0, width: cropW, height: cropH),
    width: w,
    height: h,
    interpolation: im.Interpolation.average,
  );

  // Backdrop is green or orange cloth, sampled on the guide border.
  // Card = not that colour. Green cards: shoot on orange.
  final nPix = w * h;
  final cb = Float64List(nPix);
  final cr = Float64List(nPix);
  final hue = Float64List(nPix);
  final sat = Float64List(nPix);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      final i = y * w + x;
      final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
      cb[i] = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
      cr[i] = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
      final hsv = _rgbHsv(r, g, b);
      hue[i] = hsv.$1;
      sat[i] = hsv.$2;
    }
  }
  final t = math.max(4, (w * 0.06).round());
  final borderIdx = <int>[];
  void addBorder(int i) => borderIdx.add(i);
  for (var x = t; x < w - t; x++) {
    for (var y = 0; y < t; y++) {
      addBorder(y * w + x);
      addBorder((h - 1 - y) * w + x);
    }
  }
  for (var y = t; y < h - t; y++) {
    for (var x = 0; x < t; x++) {
      addBorder(y * w + x);
      addBorder(y * w + (w - 1 - x));
    }
  }
  if (borderIdx.length < 16) return fail('no backdrop border');
  final bCb = borderIdx.map((i) => cb[i]).toList()..sort();
  final bCr = borderIdx.map((i) => cr[i]).toList()..sort();
  final bHue = borderIdx.map((i) => hue[i]).toList()..sort();
  final medCb = bCb[bCb.length ~/ 2];
  final medCr = bCr[bCr.length ~/ 2];
  final medHue = bHue[bHue.length ~/ 2];
  final bSat = borderIdx.map((i) => sat[i]).toList()..sort();
  final medSat = bSat[bSat.length ~/ 2];
  final green = medSat >= 0.22 && _hueIsGreen(medHue);
  final orange = medSat >= 0.22 && _hueIsOrange(medHue);
  if (!green && !orange) {
    return fail(
      'backdrop not green or orange '
      '(hue=${medHue.toStringAsFixed(0)} sat=${medSat.toStringAsFixed(2)})',
    );
  }
  final dist = Float64List(nPix);
  final borderDist = <double>[];
  for (var i = 0; i < nPix; i++) {
    final dCb = cb[i] - medCb, dCr = cr[i] - medCr;
    dist[i] = math.sqrt(dCb * dCb + dCr * dCr);
  }
  for (final i in borderIdx) {
    borderDist.add(dist[i]);
  }
  borderDist.sort();
  final medD = borderDist[borderDist.length ~/ 2];
  final absDev = borderDist.map((d) => (d - medD).abs()).toList()..sort();
  final mad = absDev[absDev.length ~/ 2];
  final keyThr = math.max(14.0, medD + 3.5 * math.max(mad, 2.0));
  // ignore: avoid_print
  print('cscan key ${green ? "green" : "orange"} hue=${medHue.toStringAsFixed(0)} '
      'thr=${keyThr.toStringAsFixed(1)}');

  // A line is (px, py, dx, dy). Fit through two 10% strips just inside the
  // round corners (15–25% and 75–85% along the side).
  (double, double, double, double)? fitSide(
    List<(double, double)> pts, {
    required bool horizontal,
  }) {
    if (pts.length < 16) return null;
    pts = List.of(pts)
      ..sort((a, b) => horizontal ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final n = pts.length;
    final a0 = n * 15 ~/ 100, a1 = n * 25 ~/ 100;
    final b0 = n * 75 ~/ 100, b1 = n * 85 ~/ 100;
    if (a1 - a0 < 4 || b1 - b0 < 4) return null;
    final use = <(double, double)>[...pts.sublist(a0, a1), ...pts.sublist(b0, b1)];
    var sumX = 0.0, sumY = 0.0, sumA = 0.0, sumAB = 0.0, sumAA = 0.0;
    for (final p in use) {
      final a = horizontal ? p.$1 : p.$2;
      final b = horizontal ? p.$2 : p.$1;
      sumX += p.$1;
      sumY += p.$2;
      sumA += a;
      sumAA += a * a;
      sumAB += a * b;
    }
    final k = use.length.toDouble();
    final den = k * sumAA - sumA * sumA;
    if (den.abs() < 1e-9) {
      return horizontal
          ? (sumX / k, sumY / k, 1.0, 0.0)
          : (sumX / k, sumY / k, 0.0, 1.0);
    }
    final m = (k * sumAB - sumA * (horizontal ? sumY : sumX)) / den;
    if (horizontal) {
      final x0 = sumX / k;
      final c = (sumY - m * sumX) / k;
      return (x0, m * x0 + c, 1.0, m);
    }
    final y0 = sumY / k;
    final c = (sumX - m * sumY) / k;
    return (m * y0 + c, y0, m, 1.0);
  }

  im.Point? meet(
    (double, double, double, double) a,
    (double, double, double, double) b,
  ) {
    final (px, py, dx, dy) = a;
    final (qx, qy, ex, ey) = b;
    final den = dx * ey - dy * ex;
    if (den.abs() < 1e-9) return null;
    final t = ((qx - px) * ey - (qy - py) * ex) / den;
    return im.Point(px + dx * t, py + dy * t);
  }

  (double, double, double, double) insetLine(
    (double, double, double, double) line,
    double cx,
    double cy,
    double amount,
  ) {
    var (px, py, dx, dy) = line;
    final len = math.sqrt(dx * dx + dy * dy);
    dx /= len;
    dy /= len;
    var nx = -dy, ny = dx;
    if ((cx - px) * nx + (cy - py) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    return (px + nx * amount, py + ny * amount, dx, dy);
  }

  Quad? tryCore(Uint8List seedMask) {
    var core = Uint8List.fromList(seedMask);
    final outside = Uint8List(w * h);
    final queue = <int>[];
    void seed(int i) {
      if (core[i] == 0 && outside[i] == 0) {
        outside[i] = 1;
        queue.add(i);
      }
    }

    for (var x = 0; x < w; x++) {
      seed(x);
      seed((h - 1) * w + x);
    }
    for (var y = 0; y < h; y++) {
      seed(y * w);
      seed(y * w + w - 1);
    }
    while (queue.isNotEmpty) {
      final i = queue.removeLast();
      final x = i % w, y = i ~/ w;
      if (x > 0) seed(i - 1);
      if (x < w - 1) seed(i + 1);
      if (y > 0) seed(i - w);
      if (y < h - 1) seed(i + w);
    }
    for (var i = 0; i < core.length; i++) {
      if (core[i] == 0 && outside[i] == 0) core[i] = 1;
    }

    var n = 0;
    const margin = 3;
    for (var y = margin; y < h - margin; y++) {
      for (var x = margin; x < w - margin; x++) {
        if (core[y * w + x] != 0) n++;
      }
    }
    final frac = n / (w * h);
    if (frac < 0.12 || frac > 0.90) return null;

    final top = <(double, double)>[];
    final bot = <(double, double)>[];
    final left = <(double, double)>[];
    final right = <(double, double)>[];
    for (var x = margin; x < w - margin; x++) {
      var yTop = -1, yBot = -1;
      for (var y = margin; y < h - margin; y++) {
        if (core[y * w + x] == 0) continue;
        if (yTop < 0) yTop = y;
        yBot = y;
      }
      if (yTop < 0 || yBot - yTop < 4) continue;
      top.add((x.toDouble(), yTop.toDouble()));
      bot.add((x.toDouble(), yBot.toDouble()));
    }
    for (var y = margin; y < h - margin; y++) {
      var xLeft = -1, xRight = -1;
      for (var x = margin; x < w - margin; x++) {
        if (core[y * w + x] == 0) continue;
        if (xLeft < 0) xLeft = x;
        xRight = x;
      }
      if (xLeft < 0 || xRight - xLeft < 4) continue;
      left.add((xLeft.toDouble(), y.toDouble()));
      right.add((xRight.toDouble(), y.toDouble()));
    }
    final topL = fitSide(top, horizontal: true);
    final botL = fitSide(bot, horizontal: true);
    final leftL = fitSide(left, horizontal: false);
    final rightL = fitSide(right, horizontal: false);
    if (topL == null || botL == null || leftL == null || rightL == null) {
      return null;
    }
    var tl = meet(topL, leftL);
    var tr = meet(topL, rightL);
    var br = meet(botL, rightL);
    var bl = meet(botL, leftL);
    if (tl == null || tr == null || br == null || bl == null) return null;

    double distp(im.Point a, im.Point b) => math.sqrt(
          math.pow(a.x.toDouble() - b.x.toDouble(), 2) +
              math.pow(a.y.toDouble() - b.y.toDouble(), 2),
        );
    final width = 0.5 * (distp(tr, tl) + distp(br, bl));
    final height = 0.5 * (distp(bl, tl) + distp(br, tr));
    if (width < 40 || height < 40) return null;
    final cx =
        (tl.x.toDouble() + tr.x.toDouble() + br.x.toDouble() + bl.x.toDouble()) /
            4;
    final cy =
        (tl.y.toDouble() + tr.y.toDouble() + br.y.toDouble() + bl.y.toDouble()) /
            4;
    const inset = 0.0125;
    final topI = insetLine(topL, cx, cy, inset * height);
    final botI = insetLine(botL, cx, cy, inset * height);
    final leftI = insetLine(leftL, cx, cy, inset * width);
    final rightI = insetLine(rightL, cx, cy, inset * width);
    tl = meet(topI, leftI);
    tr = meet(topI, rightI);
    br = meet(botI, rightI);
    bl = meet(botI, leftI);
    if (tl == null || tr == null || br == null || bl == null) return null;

    im.Point up(im.Point p) => im.Point(
          x0 + p.x.toDouble() / scale,
          y0 + p.y.toDouble() / scale,
        );
    // ignore: avoid_print
    print('cscan hole frac=${frac.toStringAsFixed(3)} '
        'quad=${width.round()}x${height.round()} inset=1.25%');
    return _orderLikeGuide([up(tl), up(tr), up(br), up(bl)], guide);
  }

  final core = Uint8List(w * h);
  for (var i = 0; i < core.length; i++) {
    core[i] = dist[i] > keyThr ? 1 : 0;
  }
  return tryCore(core) ?? fail('no card on green/orange backdrop');
}

/// Degrees of non-parallelism / tilt. Null if this cannot be a card: phone
/// is almost level, so opposite sides stay nearly parallel, the shape is
/// ~5:7, and the top edge tracks the guide within a few degrees.
double? _quadScore(Quad q, Quad guide) {
  double parallelDeg(im.Point a, im.Point b, im.Point c, im.Point d) {
    final dx1 = b.x.toDouble() - a.x.toDouble();
    final dy1 = b.y.toDouble() - a.y.toDouble();
    final dx2 = d.x.toDouble() - c.x.toDouble();
    final dy2 = d.y.toDouble() - c.y.toDouble();
    final l1 = math.sqrt(dx1 * dx1 + dy1 * dy1);
    final l2 = math.sqrt(dx2 * dx2 + dy2 * dy2);
    if (l1 < 1 || l2 < 1) return 90;
    final dot = ((dx1 * dx2 + dy1 * dy2) / (l1 * l2)).clamp(-1.0, 1.0);
    final ang = math.acos(dot);
    return math.min(ang, math.pi - ang) * 180 / math.pi;
  }

  final p1 = parallelDeg(q.tl, q.tr, q.bl, q.br);
  final p2 = parallelDeg(q.tl, q.bl, q.tr, q.br);
  final tilt = parallelDeg(q.tl, q.tr, guide.tl, guide.tr);
  if (p1 > 12 || p2 > 12 || tilt > 8) return null;

  final ww = (_dist(q.tl, q.tr) + _dist(q.bl, q.br)) / 2;
  final hh = (_dist(q.tl, q.bl) + _dist(q.tr, q.br)) / 2;
  if (hh < 1) return null;
  final asp = ww / hh;
  if (asp < 0.60 || asp > 0.82) return null;
  return math.max(p1, math.max(p2, tilt));
}

void _push(List<int> stack, Uint8List seen, Uint8List core, int i) {
  if (seen[i] == 0 && core[i] != 0) {
    seen[i] = 1;
    stack.add(i);
  }
}

/// Otsu's threshold: the level that best splits the histogram into two classes.
int _otsu(List<int> hist, int total) {
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumB = 0.0, wB = 0, best = 0.0, threshold = 0;
  for (var i = 0; i < 256; i++) {
    wB += hist[i];
    if (wB == 0) continue;
    final wF = total - wB;
    if (wF == 0) break;
    sumB += i * hist[i];
    final mB = sumB / wB, mF = (sum - sumB) / wF;
    final between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      threshold = i;
    }
  }
  return threshold;
}

double _cross(im.Point o, im.Point a, im.Point b) =>
    (a.x.toDouble() - o.x.toDouble()) * (b.y.toDouble() - o.y.toDouble()) -
    (a.y.toDouble() - o.y.toDouble()) * (b.x.toDouble() - o.x.toDouble());

/// Andrew's monotone chain.
List<im.Point> _hullOf(List<im.Point> pts) {
  if (pts.length < 3) return pts;
  final p = [...pts]..sort((a, b) => a.x != b.x
      ? a.x.compareTo(b.x)
      : a.y.compareTo(b.y));
  final lower = <im.Point>[];
  for (final q in p) {
    while (lower.length >= 2 &&
        _cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  final upper = <im.Point>[];
  for (final q in p.reversed) {
    while (upper.length >= 2 &&
        _cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// Smallest-area enclosing rectangle, by rotating calipers: the minimum always
/// has a side flush with a hull edge, so try each edge's direction.
List<im.Point>? _minAreaRect(List<im.Point> hull) {
  var bestArea = double.infinity;
  List<im.Point>? best;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    final dx = b.x.toDouble() - a.x.toDouble();
    final dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) continue;
    final ux = dx / len, uy = dy / len;
    var minU = double.infinity, maxU = -double.infinity;
    var minV = double.infinity, maxV = -double.infinity;
    for (final p in hull) {
      final px = p.x.toDouble(), py = p.y.toDouble();
      final u = px * ux + py * uy;
      final v = -px * uy + py * ux;
      minU = math.min(minU, u);
      maxU = math.max(maxU, u);
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
    final area = (maxU - minU) * (maxV - minV);
    if (area < bestArea) {
      bestArea = area;
      im.Point at(double u, double v) =>
          im.Point(u * ux - v * uy, u * uy + v * ux);
      best = [
        at(minU, minV),
        at(maxU, minV),
        at(maxU, maxV),
        at(minU, maxV),
      ];
    }
  }
  return best;
}

/// Rectangle of a card blob: rotation from the *long* hull edges (the flat
/// sides), then the axis-aligned box in that frame. Short rounded-corner
/// chords are ignored so they cannot tilt the crop.
List<im.Point>? _cardRect(List<im.Point> hull) {
  if (hull.length < 4) return null;
  var maxLen = 0.0;
  final edges = <(double, double)>[]; // len, folded angle
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    final dx = b.x.toDouble() - a.x.toDouble();
    final dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) continue;
    var rot = math.atan2(dy, dx);
    while (rot > math.pi / 4) {
      rot -= math.pi / 2;
    }
    while (rot < -math.pi / 4) {
      rot += math.pi / 2;
    }
    edges.add((len, rot));
    if (len > maxLen) maxLen = len;
  }
  if (maxLen < 1) return null;
  var tsum = 0.0, wsum = 0.0;
  for (final (len, rot) in edges) {
    if (len < 0.25 * maxLen) continue;
    tsum += rot * len;
    wsum += len;
  }
  final theta = wsum == 0 ? 0.0 : tsum / wsum;
  final ux = math.cos(theta), uy = math.sin(theta);
  var minU = double.infinity, maxU = -double.infinity;
  var minV = double.infinity, maxV = -double.infinity;
  for (final p in hull) {
    final px = p.x.toDouble(), py = p.y.toDouble();
    final u = px * ux + py * uy;
    final v = -px * uy + py * ux;
    minU = math.min(minU, u);
    maxU = math.max(maxU, u);
    minV = math.min(minV, v);
    maxV = math.max(maxV, v);
  }
  im.Point at(double u, double v) =>
      im.Point(u * ux - v * uy, u * uy + v * ux);
  return [
    at(minU, minV),
    at(maxU, minV),
    at(maxU, maxV),
    at(minU, maxV),
  ];
}

/// Full-resolution version of the small-image side snap: same rectangle,
/// same normals, search a few tens of source pixels for the table→card step.
Quad? _snapRectSrc(im.Image src, Quad q) {
  final pts = [q.tl, q.tr, q.br, q.bl];
  final cx =
      pts.map((p) => p.x.toDouble()).reduce((a, b) => a + b) / 4;
  final cy =
      pts.map((p) => p.y.toDouble()).reduce((a, b) => a + b) / 4;

  (int, int, int) pix(double x, double y) {
    final p = src.getPixel(
      x.round().clamp(0, src.width - 1),
      y.round().clamp(0, src.height - 1),
    );
    return (p.r.toInt(), p.g.toInt(), p.b.toInt());
  }

  final samples = <(int, int, int)>[];
  for (var i = 0; i < 4; i++) {
    final a = pts[i], b = pts[(i + 1) % 4];
    var dx = b.x.toDouble() - a.x.toDouble();
    var dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) continue;
    dx /= len;
    dy /= len;
    var nx = -dy, ny = dx;
    final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    if ((mx + nx - cx) * nx + (my + ny - cy) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    for (final t in [0.2, 0.4, 0.6, 0.8]) {
      samples.add(pix(
        a.x.toDouble() + dx * len * t + nx * 18,
        a.y.toDouble() + dy * len * t + ny * 18,
      ));
    }
  }
  if (samples.length < 8) return null;
  final rs = [for (final s in samples) s.$1.toDouble()]..sort();
  final gs = [for (final s in samples) s.$2.toDouble()]..sort();
  final bs = [for (final s in samples) s.$3.toDouble()]..sort();
  final tr = rs[rs.length ~/ 2];
  final tg = gs[gs.length ~/ 2];
  final tb = bs[bs.length ~/ 2];
  final tableLum = 0.299 * tr + 0.587 * tg + 0.114 * tb;

  double cardness(double x, double y) {
    final (r, g, b) = pix(x, y);
    final lum = 0.299 * r + 0.587 * g + 0.114 * b;
    final tlum = tableLum;
    final d0 = 0.12 * (lum - tlum);
    final d1 = 1.4 * ((r - b) - (tr - tb));
    final d2 = 1.4 * ((g - b) - (tg - tb));
    final fd = math.sqrt(d0 * d0 + d1 * d1 + d2 * d2);
    if (tableLum >= 140) return fd;
    return math.max(fd, 0.35 * math.max(0.0, lum - tableLum));
  }

  final lines = <(double, double, double, double)>[];
  for (var i = 0; i < 4; i++) {
    final a = pts[i], b = pts[(i + 1) % 4];
    var dx = b.x.toDouble() - a.x.toDouble();
    var dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1) return null;
    dx /= len;
    dy /= len;
    var nx = -dy, ny = dx;
    final mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    if ((mx + nx - cx) * nx + (my + ny - cy) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    var bestK = 0;
    var bestS = -1e9;
    for (var k = -18; k <= 8; k++) {
      var s = 0.0;
      for (final t in [0.22, 0.38, 0.5, 0.62, 0.78]) {
        final ox = a.x.toDouble() + nx * k + dx * len * t;
        final oy = a.y.toDouble() + ny * k + dy * len * t;
        s += cardness(ox - nx * 8, oy - ny * 8) -
            cardness(ox + nx * 8, oy + ny * 8);
      }
      if (s > bestS) {
        bestS = s;
        bestK = k;
      }
    }
    lines.add((a.x.toDouble() + nx * bestK, a.y.toDouble() + ny * bestK, dx, dy));
  }
  im.Point? meet(int i, int j) {
    final (px, py, dx, dy) = lines[i];
    final (qx, qy, ex, ey) = lines[j];
    final den = dx * ey - dy * ex;
    if (den.abs() < 1e-9) return null;
    final t = ((qx - px) * ey - (qy - py) * ex) / den;
    return im.Point(px + dx * t, py + dy * t);
  }

  final pTl = meet(3, 0);
  final pTr = meet(0, 1);
  final pBr = meet(1, 2);
  final pBl = meet(2, 3);
  if (pTl == null || pTr == null || pBr == null || pBl == null) return null;
  return Quad(pTl, pTr, pBr, pBl);
}

/// Snap a roughly-correct quad onto the card's real edges in the full
/// resolution still.
///
/// The blob pass works on a downscaled, eroded mask, so its boundary lands
/// outside the card by a fairly constant margin. Walk the normal of each edge
/// in the original pixels and find where the intensity actually steps between
/// surface and card.
///
/// Two things this must not assume. It must not assume the card is lighter
/// than the surface — a black card on a pale table is just as ordinary — so
/// the direction of the step is measured from the image, not fixed. And it
/// must take the *outermost* crossing rather than the strongest one: on a dark
/// card the white pips have harder edges than the card's own boundary, and
/// picking the strongest put one edge diagonally across the face.
Quad? refineOnSource(im.Image src, Quad quad) {
  double lum(double ox, double oy) {
    final xi = ox.round().clamp(0, src.width - 1);
    final yi = oy.round().clamp(0, src.height - 1);
    final p = src.getPixel(xi, yi);
    return 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
  }

  final cx = quad.points.map((p) => p.x.toDouble()).reduce((a, b) => a + b) / 4;
  final cy = quad.points.map((p) => p.y.toDouble()).reduce((a, b) => a + b) / 4;

  // Sample a ring well inside the quad and another well outside it, so both
  // the polarity and the available contrast come from this photograph.
  double ring(double scale) {
    final vals = <double>[];
    for (var i = 0; i < 4; i++) {
      final a = quad.points[i], b = quad.points[(i + 1) % 4];
      for (var t = 0.1; t < 1.0; t += 0.1) {
        final x = a.x.toDouble() + (b.x.toDouble() - a.x.toDouble()) * t;
        final y = a.y.toDouble() + (b.y.toDouble() - a.y.toDouble()) * t;
        vals.add(lum(cx + (x - cx) * scale, cy + (y - cy) * scale));
      }
    }
    vals.sort();
    return vals[vals.length ~/ 2];
  }

  final insideLevel = ring(0.55);
  final outsideLevel = ring(1.30);
  final contrast = (insideLevel - outsideLevel).abs();
  if (contrast < 12) return null; // card and surface too alike to place an edge
  final cardIsBright = insideLevel >= outsideLevel;
  final minStep = math.max(10.0, contrast * 0.30);

  final lines = <(double, double, double, double)?>[];
  final sides = [
    (quad.tl, quad.tr),
    (quad.tr, quad.br),
    (quad.br, quad.bl),
    (quad.bl, quad.tl),
  ];

  for (final (a, b) in sides) {
    final dx = b.x.toDouble() - a.x.toDouble();
    final dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 10) return null;
    final ux = dx / len, uy = dy / len;
    var nx = -uy, ny = ux;
    if ((a.x.toDouble() + nx - cx) * nx + (a.y.toDouble() + ny - cy) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }

    final reach = math.max(14.0, math.min(70.0, len * 0.07));
    final pts = <im.Point>[];
    const samples = 33;
    for (var i = 0; i < samples; i++) {
      // Skip the ends; a card's corners are rounded and not on the edge line.
      final t = 0.16 + 0.68 * i / (samples - 1);
      final px = a.x.toDouble() + dx * t, py = a.y.toDouble() + dy * t;

      double sideMean(double d, int dir, int from, int to) {
        var sum = 0.0;
        var n = 0;
        for (var k = from; k <= to; k++) {
          sum += lum(px + nx * (d + dir * k), py + ny * (d + dir * k));
          n++;
        }
        return sum / n;
      }

      double? crossing;
      for (var d = -reach; d <= reach - 4; d += 1) {
        final outer = sideMean(d, 1, 2, 5);
        final inner = sideMean(d, -1, 2, 5);
        final step = cardIsBright ? inner - outer : outer - inner;
        if (step < minStep) continue;
        // Confirm it really is the card beyond this point, not a speck of
        // surface texture or a printed mark.
        final beyond = sideMean(d, -1, 6, 20);
        final looksLikeCard = cardIsBright
            ? beyond >= insideLevel - contrast * 0.5
            : beyond <= insideLevel + contrast * 0.5;
        if (!looksLikeCard) continue;
        crossing = d;
        break; // outermost, not strongest
      }
      if (crossing == null) continue;
      pts.add(im.Point(px + nx * crossing, py + ny * crossing));
    }
    if (pts.length < samples * 0.5) return null;
    lines.add(_fitTls(pts));
  }
  if (lines.any((l) => l == null)) return null;

  im.Point? meet((double, double, double, double) p, (double, double, double, double) q) {
    final (px, py, dx, dy) = p;
    final (qx, qy, ex, ey) = q;
    final den = dx * ey - dy * ex;
    if (den.abs() < 1e-9) return null;
    final t = ((qx - px) * ey - (qy - py) * ex) / den;
    return im.Point(px + dx * t, py + dy * t);
  }

  final tl = meet(lines[3]!, lines[0]!);
  final tr = meet(lines[0]!, lines[1]!);
  final br = meet(lines[1]!, lines[2]!);
  final bl = meet(lines[2]!, lines[3]!);
  if (tl == null || tr == null || br == null || bl == null) return null;
  return Quad(tl, tr, br, bl);
}

/// Total-least-squares line through points, with one outlier-rejection pass.
/// Returns (pointX, pointY, dirX, dirY).
(double, double, double, double)? _fitTls(List<im.Point> pts) {
  (double, double, double, double)? once(List<im.Point> ps) {
    if (ps.length < 4) return null;
    var mx = 0.0, my = 0.0;
    for (final p in ps) {
      mx += p.x.toDouble();
      my += p.y.toDouble();
    }
    mx /= ps.length;
    my /= ps.length;
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (final p in ps) {
      final dx = p.x.toDouble() - mx, dy = p.y.toDouble() - my;
      sxx += dx * dx;
      syy += dy * dy;
      sxy += dx * dy;
    }
    final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    return (mx, my, math.cos(theta), math.sin(theta));
  }

  final first = once(pts);
  if (first == null) return null;
  final (mx, my, dx, dy) = first;
  final res = <double>[
    for (final p in pts)
      ((p.x.toDouble() - mx) * -dy + (p.y.toDouble() - my) * dx).abs()
  ];
  final sorted = [...res]..sort();
  final mad = sorted[sorted.length ~/ 2];
  final limit = math.max(2.0, mad * 3);
  final keep = [
    for (var i = 0; i < pts.length; i++)
      if (res[i] <= limit) pts[i]
  ];
  return once(keep) ?? first;
}

/// The card's four corners, from the convex hull of its blob.
///
/// A minimum-area *rectangle* only encloses the card: under perspective the
/// card is a trapezoid, so the rectangle touches it at the extremes and the
/// warp leaves wedges of surface down one side (measured 4 px at one end of an
/// edge and 57 px at the other). Fitting a line to each of the four sides and
/// intersecting them gives the true quadrilateral, which the homography then
/// rectifies properly.
List<im.Point>? _hullQuad(List<im.Point> hull, List<im.Point> rect) {
  // Orientation from the enclosing rectangle: u along its width, v its height.
  var ux = rect[1].x.toDouble() - rect[0].x.toDouble();
  var uy = rect[1].y.toDouble() - rect[0].y.toDouble();
  final ul = math.sqrt(ux * ux + uy * uy);
  if (ul < 1e-6) return null;
  ux /= ul;
  uy /= ul;
  final vx = -uy, vy = ux;

  // Assign each hull edge to the side its outward normal points at.
  final groups = List.generate(4, (_) => <(im.Point, double)>[]);
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    final dx = b.x.toDouble() - a.x.toDouble();
    final dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) continue;
    // Outward normal of a counter-clockwise hull edge.
    final nx = dy / len, ny = -dx / len;
    final du = nx * ux + ny * uy;
    final dv = nx * vx + ny * vy;
    final int side;
    if (du.abs() > dv.abs()) {
      side = du > 0 ? 1 : 3; // right : left
    } else {
      side = dv > 0 ? 2 : 0; // bottom : top
    }
    groups[side].add((a, len));
    groups[side].add((b, len));
  }

  // Total-least-squares line per side: a point on it and a direction.
  (im.Point, double, double)? fit(List<(im.Point, double)> pts) {
    if (pts.length < 4) return null;
    var wsum = 0.0, mx = 0.0, my = 0.0;
    for (final (p, w) in pts) {
      wsum += w;
      mx += p.x.toDouble() * w;
      my += p.y.toDouble() * w;
    }
    if (wsum < 1e-6) return null;
    mx /= wsum;
    my /= wsum;
    var sxx = 0.0, syy = 0.0, sxy = 0.0;
    for (final (p, w) in pts) {
      final dx = p.x.toDouble() - mx, dy = p.y.toDouble() - my;
      sxx += w * dx * dx;
      syy += w * dy * dy;
      sxy += w * dx * dy;
    }
    final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
    return (im.Point(mx, my), math.cos(theta), math.sin(theta));
  }

  final lines = [for (final g in groups) fit(g)];
  if (lines.any((l) => l == null)) return null;

  im.Point? meet((im.Point, double, double) a, (im.Point, double, double) b) {
    final (pa, dax, day) = a;
    final (pb, dbx, dby) = b;
    final den = dax * dby - day * dbx;
    if (den.abs() < 1e-9) return null;
    final ex = pb.x.toDouble() - pa.x.toDouble();
    final ey = pb.y.toDouble() - pa.y.toDouble();
    final t = (ex * dby - ey * dbx) / den;
    return im.Point(pa.x.toDouble() + dax * t, pa.y.toDouble() + day * t);
  }

  final tl = meet(lines[3]!, lines[0]!); // left  x top
  final tr = meet(lines[0]!, lines[1]!); // top   x right
  final br = meet(lines[1]!, lines[2]!); // right x bottom
  final bl = meet(lines[2]!, lines[3]!); // bottom x left
  if (tl == null || tr == null || br == null || bl == null) return null;
  return [tl, tr, br, bl];
}

/// Push each side of a quadrilateral outwards by [by] pixels, undoing the
/// erosion. Offsets every edge along its own outward normal and re-intersects,
/// so a trapezoid stays a trapezoid — scaling about the centre would flatten
/// the perspective back out.
List<im.Point>? _growQuadOrNull(List<im.Point> q, double by) {
  final cx = q.map((p) => p.x.toDouble()).reduce((a, b) => a + b) / 4;
  final cy = q.map((p) => p.y.toDouble()).reduce((a, b) => a + b) / 4;
  final lines = <(double, double, double, double)>[]; // px, py, dx, dy
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4];
    var dx = b.x.toDouble() - a.x.toDouble();
    var dy = b.y.toDouble() - a.y.toDouble();
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-6) return null;
    dx /= len;
    dy /= len;
    var nx = -dy, ny = dx;
    // Point the normal away from the centre.
    if ((a.x.toDouble() + nx - cx) * nx + (a.y.toDouble() + ny - cy) * ny < 0) {
      nx = -nx;
      ny = -ny;
    }
    lines.add((a.x.toDouble() + nx * by, a.y.toDouble() + ny * by, dx, dy));
  }
  im.Point? meet(int i, int j) {
    final (px, py, dx, dy) = lines[i];
    final (qx, qy, ex, ey) = lines[j];
    final den = dx * ey - dy * ex;
    if (den.abs() < 1e-9) return null;
    final t = ((qx - px) * ey - (qy - py) * ex) / den;
    return im.Point(px + dx * t, py + dy * t);
  }

  final out = <im.Point>[];
  for (var i = 0; i < 4; i++) {
    final p = meet((i + 3) % 4, i);
    if (p == null) return null;
    out.add(p);
  }
  return out;
}

List<im.Point> _growQuad(List<im.Point> q, double by) =>
    _growQuadOrNull(q, by) ?? q;

/// Put the rectangle's corners in the same order as the guide's, so the warp
/// keeps the card upright instead of rotating it by a quarter turn.
Quad _orderLikeGuide(List<im.Point> rect, Quad guide) {
  final want = guide.points;
  var bestScore = double.infinity;
  var bestOrder = rect;
  for (final seq in [rect, rect.reversed.toList()]) {
    for (var shift = 0; shift < 4; shift++) {
      final order = [for (var i = 0; i < 4; i++) seq[(i + shift) % 4]];
      var score = 0.0;
      for (var i = 0; i < 4; i++) {
        score += _dist(order[i], want[i]);
      }
      if (score < bestScore) {
        bestScore = score;
        bestOrder = order;
      }
    }
  }
  return Quad(bestOrder[0], bestOrder[1], bestOrder[2], bestOrder[3]);
}

Quad _viewRectToQuad(
  im.Image src,
  double viewW,
  double viewH,
  double left,
  double top,
  double right,
  double bottom, {
  double previewW = 0,
  double previewH = 0,
}) {
  final imgW = src.width.toDouble();
  final imgH = src.height.toDouble();

  // The guide was measured against the preview widget, which CameraCover fits
  // BoxFit.cover. Map the guide into preview-normalised coordinates first.
  final pw = previewW > 0 ? previewW : imgW;
  final ph = previewH > 0 ? previewH : imgH;
  final coverScale = math.max(viewW / pw, viewH / ph);
  final dispW = pw * coverScale;
  final dispH = ph * coverScale;
  final offsetX = (viewW - dispW) / 2;
  final offsetY = (viewH - dispH) / 2;

  // The still can have a different aspect — and so a different field of view —
  // than the preview. Both come from the same sensor area centre-cropped to
  // their own aspect, so the narrower one sees a centred sub-window of the
  // wider one. Getting this wrong maps the guide onto the wrong part of the
  // frame: a 4:3 still against a 16:9 preview cropped to the card's artwork
  // instead of the card.
  final previewAspect = pw / ph;
  final stillAspect = imgW / imgH;
  final cropX = previewAspect < stillAspect ? previewAspect / stillAspect : 1.0;
  final cropY = previewAspect > stillAspect ? stillAspect / previewAspect : 1.0;

  im.Point map(double fx, double fy) {
    final nx = (fx * viewW - offsetX) / dispW;
    final ny = (fy * viewH - offsetY) / dispH;
    final sx = 0.5 + (nx - 0.5) * cropX;
    final sy = 0.5 + (ny - 0.5) * cropY;
    return im.Point(sx * imgW, sy * imgH);
  }

  return Quad(map(left, top), map(right, top), map(right, bottom), map(left, bottom));
}

im.Point _centroid(Quad q) => im.Point(
      (q.tl.x + q.tr.x + q.br.x + q.bl.x) / 4.0,
      (q.tl.y + q.tr.y + q.br.y + q.bl.y) / 4.0,
    );

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
