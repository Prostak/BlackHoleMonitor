#!/usr/bin/env python3
"""
Quick Autobattle template probe (same idea as MacAuto/Two_Helmets.py).

Template can be a tight crop around the gold "Autobattle" letters —
unlike OCR, we don't need button chrome padding in the pattern itself.
Search haystack is the bottom-center strip (same relative ROI as the app).
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import cv2
import numpy as np

# Same fractional strip the Swift detector uses for search.
ROI_X0, ROI_X1 = 0.40, 0.60
ROI_Y0, ROI_Y1 = 0.84, 0.93


def load_bgr(path: Path) -> np.ndarray:
    img = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if img is None:
        raise SystemExit(f"Could not read image: {path}")
    return img


def bottom_strip(img: np.ndarray) -> tuple[np.ndarray, tuple[int, int]]:
    h, w = img.shape[:2]
    x0 = int(w * ROI_X0)
    x1 = int(w * ROI_X1)
    y0 = int(h * ROI_Y0)
    y1 = int(h * ROI_Y1)
    return img[y0:y1, x0:x1].copy(), (x0, y0)


def tight_text_template(roi: np.ndarray) -> np.ndarray:
    """
    Shrink a button ROI toward the gold/yellow text glyphs.
    Keeps a thin margin; drops most maroon chrome (OCR needed that; TM does not).
    """
    h, w = roi.shape[:2]
    b, g, r = cv2.split(roi)
    # Gold Autobattle letters (approx): high R/G, low B.
    gold = (r > 160) & (g > 120) & (b < 110) & ((r.astype(np.int16) - b) > 70)
    ys, xs = np.where(gold)
    if len(xs) < 20:
        # Fallback: central band of the ROI (letters sit mid-button).
        y0, y1 = int(h * 0.20), int(h * 0.80)
        x0, x1 = int(w * 0.08), int(w * 0.92)
        return roi[y0:y1, x0:x1].copy()

    pad_x, pad_y = 2, 1
    x0 = max(0, int(xs.min()) - pad_x)
    x1 = min(w, int(xs.max()) + pad_x + 1)
    y0 = max(0, int(ys.min()) - pad_y)
    y1 = min(h, int(ys.max()) + pad_y + 1)
    # Guard against a 1px-tall crop.
    if y1 - y0 < 6:
        mid = (y0 + y1) // 2
        y0, y1 = max(0, mid - 3), min(h, mid + 3)
    if x1 - x0 < 20:
        mid = (x0 + x1) // 2
        x0, x1 = max(0, mid - 10), min(w, mid + 10)
    return roi[y0:y1, x0:x1].copy()


def match_once(haystack: np.ndarray, template: np.ndarray) -> tuple[float, tuple[int, int], float]:
    t0 = time.perf_counter()
    result = cv2.matchTemplate(haystack, template, cv2.TM_CCOEFF_NORMED)
    _, max_val, _, max_loc = cv2.minMaxLoc(result)
    ms = (time.perf_counter() - t0) * 1000.0
    return float(max_val), (int(max_loc[0]), int(max_loc[1])), ms


def multi_scale(
    haystack: np.ndarray, template: np.ndarray, scales: list[float]
) -> tuple[float, tuple[int, int], float, float]:
    best = (-1.0, (0, 0), 1.0)
    t0 = time.perf_counter()
    for scale in scales:
        if abs(scale - 1.0) < 1e-6:
            tmpl = template
        else:
            nw = max(8, int(round(template.shape[1] * scale)))
            nh = max(4, int(round(template.shape[0] * scale)))
            if nh >= haystack.shape[0] or nw >= haystack.shape[1]:
                continue
            tmpl = cv2.resize(template, (nw, nh), interpolation=cv2.INTER_AREA)
        score, loc, _ = match_once(haystack, tmpl)
        if score > best[0]:
            best = (score, loc, scale)
    ms = (time.perf_counter() - t0) * 1000.0
    return best[0], best[1], best[2], ms


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--debug-dir",
        type=Path,
        default=Path.home() / "Documents" / "BlackHoleMonitor-Debug",
    )
    parser.add_argument("--out", type=Path, default=Path("scripts/cv_probe_out"))
    parser.add_argument("--confidence", type=float, default=0.85)
    args = parser.parse_args()

    debug = args.debug_dir
    out = args.out
    out.mkdir(parents=True, exist_ok=True)

    roi_path = debug / "last-trigger-roi.png"
    marked_path = debug / "last-trigger-marked.png"
    # Prefer full window if present and large enough; marked is full SS capture.
    full_candidates = [
        debug / "last-trigger-marked.png",
        debug / "debug-full.png",
    ]

    roi = load_bgr(roi_path)
    template = tight_text_template(roi)
    cv2.imwrite(str(out / "template_tight.png"), template)

    print(f"ROI button crop: {roi.shape[1]}x{roi.shape[0]}")
    print(f"Tight text tmpl: {template.shape[1]}x{template.shape[0]}")

    # Self-match on the ROI (sanity).
    score, loc, ms = match_once(roi, template)
    print(f"Self-match on ROI: score={score:.3f} loc={loc} time={ms:.2f}ms")

    haystack_img = None
    haystack_name = None
    for cand in full_candidates:
        if not cand.exists():
            continue
        img = load_bgr(cand)
        if img.shape[0] < 200 or img.shape[1] < 200:
            print(f"Skip {cand.name}: too small {img.shape[1]}x{img.shape[0]} (locked crop?)")
            continue
        haystack_img = img
        haystack_name = cand.name
        break

    if haystack_img is None:
        print("No full-window haystack available — only self-match ran.")
        print("Take a Debug snapshot while Autobattle is visible, then re-run.")
        return

    strip, (ox, oy) = bottom_strip(haystack_img)
    cv2.imwrite(str(out / "search_strip.png"), strip)
    print(f"Haystack: {haystack_name} {haystack_img.shape[1]}x{haystack_img.shape[0]}")
    print(f"Search strip: {strip.shape[1]}x{strip.shape[0]} at window offset ({ox},{oy})")

    # Warm-up + timed passes.
    for _ in range(3):
        match_once(strip, template)

    times = []
    score = loc = None
    for _ in range(20):
        score, loc, ms = match_once(strip, template)
        times.append(ms)
    assert score is not None and loc is not None
    print(
        f"Strip match x20: score={score:.3f} loc_in_strip={loc} "
        f"avg={sum(times)/len(times):.2f}ms min={min(times):.2f} max={max(times):.2f}"
    )

    scales = [0.85, 0.90, 0.95, 1.0, 1.05, 1.10, 1.15]
    mscore, mloc, mscale, mms = multi_scale(strip, template, scales)
    print(f"Multi-scale ({len(scales)}): best={mscore:.3f} scale={mscale:.2f} loc={mloc} time={mms:.2f}ms")

    # Full-window match cost (what NOT to do every poll — for comparison).
    fscore, floc, fms = match_once(haystack_img, template)
    print(f"Full-window match: score={fscore:.3f} loc={floc} time={fms:.2f}ms")

    # Annotate strip.
    th, tw = template.shape[:2]
    marked = strip.copy()
    color = (0, 255, 0) if score >= args.confidence else (0, 0, 255)
    cv2.rectangle(marked, loc, (loc[0] + tw, loc[1] + th), color, 1)
    cv2.putText(
        marked,
        f"{score:.3f}",
        (loc[0], max(12, loc[1] - 2)),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.4,
        color,
        1,
        cv2.LINE_AA,
    )
    cv2.imwrite(str(out / "strip_marked.png"), marked)

    ok = score >= args.confidence
    print(f"Verdict @ {args.confidence}: {'HIT' if ok else 'MISS'} (tight template on strip)")
    print(f"Wrote: {out}/template_tight.png, search_strip.png, strip_marked.png")


if __name__ == "__main__":
    main()
