package com.chekusu.sofatap.tv.ui;

import android.animation.ValueAnimator;
import android.app.ActivityManager;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PathMeasure;
import android.graphics.RectF;
import android.graphics.Region;
import android.os.SystemClock;
import android.view.View;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;

/**
 * The "Nebula" particle field behind the TV receiver screens (design A).
 *
 * Works in a fixed 1600 × 900 design space; the parent scales it to the screen. Each scene gives
 * every particle a target (a rotating 3D cloud, a device outline, a stream, scattered stars) and
 * particles spring toward it, so changing scenes morphs the cloud. Low-RAM TVs get fewer particles
 * and, with system animations off, the field is drawn still.
 */
public final class NebulaView extends View {
    public static final float W = 1600, H = 900;
    public enum Scene { CLOUD, COLLAPSE, PHONE, PERMISSION, STARS, SCREENS, IDLE }

    private static final int[] PALETTE = { Color.rgb(152, 233, 196), Color.rgb(127, 211, 240), Color.rgb(196, 181, 255), Color.rgb(240, 245, 243) };
    private final int n;
    private final float[] x, y, vx, vy, s, a, k;
    private final int[] c;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Map<String, float[]> shapes = new HashMap<>();
    private final boolean still;
    private Scene scene = Scene.CLOUD;
    private float cloudX = 800, cloudY = 330;
    private float dim = 1f;
    private long start = SystemClock.uptimeMillis(), sceneAt = start, last = start;
    private float cursorX = -1, cursorY = -1; private long cursorAt;
    private boolean running;

    public NebulaView(Context context) {
        super(context);
        ActivityManager am = context.getSystemService(ActivityManager.class);
        n = am != null && am.isLowRamDevice() ? 700 : 1400;
        still = !ValueAnimator.areAnimatorsEnabled();
        x = new float[n]; y = new float[n]; vx = new float[n]; vy = new float[n]; s = new float[n]; a = new float[n]; k = new float[n]; c = new int[n];
        Random r = new Random(7);
        for (int i = 0; i < n; i++) { x[i] = r.nextFloat() * W; y[i] = r.nextFloat() * H; k[i] = 0.03f + rnd(i, 51) * 0.04f; }
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        setFocusable(false);
        if (still) for (int i = 0; i < 90; i++) step(1f / 60);
    }

    /** Switches the scene; particles morph from wherever they are. */
    public void setScene(Scene next) { if (next != scene) { scene = next; sceneAt = SystemClock.uptimeMillis(); settleIfStill(); } }
    public Scene scene() { return scene; }
    public void setCloudCenter(float cx, float cy) { cloudX = cx; cloudY = cy; }
    public void setDim(float value) { dim = value; invalidate(); }

    /** Sends particles flying out from a square (the QR island) as the pairing animation starts. */
    public void burstFrom(float cx, float cy, float size) {
        Random r = new Random();
        int m = Math.min(n, 600);
        for (int i = 0; i < m; i++) {
            x[i] = cx + (r.nextFloat() - .5f) * size; y[i] = cy + (r.nextFloat() - .5f) * size;
            double an = r.nextDouble() * Math.PI * 2; float sp = 1 + r.nextFloat() * 7;
            vx[i] = (float) Math.cos(an) * sp; vy[i] = (float) Math.sin(an) * sp; a[i] = 1; s[i] = 3.4f;
        }
    }

    /** Pushes particles away from a point, as a tap does. */
    public void pulse(float px, float py) {
        for (int i = 0; i < n; i++) {
            float dx = x[i] - px, dy = y[i] - py, d = (float) Math.hypot(dx, dy);
            if (d > 0 && d < 200) { float f = (1 - d / 200) * 8; vx[i] += dx / d * f; vy[i] += dy / d * f; }
        }
    }

    /** The real pointer position in design coordinates; particles part around it for a moment. */
    public void setCursor(float cx, float cy) { cursorX = cx; cursorY = cy; cursorAt = SystemClock.uptimeMillis(); }

    @Override protected void onAttachedToWindow() { super.onAttachedToWindow(); running = true; last = SystemClock.uptimeMillis(); postInvalidateOnAnimation(); }
    @Override protected void onDetachedFromWindow() { running = false; super.onDetachedFromWindow(); }
    @Override protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        running = visibility == VISIBLE && isAttachedToWindow();
        if (running) { last = SystemClock.uptimeMillis(); postInvalidateOnAnimation(); }
    }

    @Override protected void onMeasure(int w, int h) { setMeasuredDimension((int) W, (int) H); }

    @Override protected void onDraw(Canvas canvas) {
        long now = SystemClock.uptimeMillis();
        if (!still) step(Math.min(0.05f, (now - last) / 1000f));
        last = now;
        for (int col = 0; col < PALETTE.length; col++) {
            paint.setColor(PALETTE[col]);
            for (int i = 0; i < n; i++) {
                if (c[i] != col) continue;
                float alpha = Math.min(1, a[i]) * dim;
                if (alpha < 0.02f || s[i] <= 0) continue;
                paint.setAlpha((int) (alpha * 255));
                canvas.drawCircle(x[i], y[i], s[i], paint);
            }
        }
        if (running && !still) postInvalidateOnAnimation();
    }

    private void settleIfStill() { if (still) { for (int i = 0; i < 120; i++) step(1f / 60); invalidate(); } }

    // ---- simulation ----
    private final float[] out = new float[4];
    private int outColor;
    private boolean outSnap;

    private void step(float dt) {
        float t = (SystemClock.uptimeMillis() - start) / 1000f, st = (SystemClock.uptimeMillis() - sceneAt) / 1000f;
        boolean repel = scene == Scene.STARS && cursorX >= 0 && SystemClock.uptimeMillis() - cursorAt < 2500;
        for (int i = 0; i < n; i++) {
            outSnap = false; layout(i, t, st);
            float tx = out[0], ty = out[1];
            if (outSnap) { x[i] = tx; y[i] = ty; vx[i] = 0; vy[i] = 0; }
            float vxi = (vx[i] + (tx - x[i]) * k[i]) * 0.84f, vyi = (vy[i] + (ty - y[i]) * k[i]) * 0.84f;
            if (repel) {
                float dx = x[i] - cursorX, dy = y[i] - cursorY, d2 = dx * dx + dy * dy;
                if (d2 < 29000 && d2 > 1) { float d = (float) Math.sqrt(d2), f = (1 - d / 170) * 3.4f; vxi += dx / d * f; vyi += dy / d * f; }
            }
            vx[i] = vxi; vy[i] = vyi; x[i] += vxi; y[i] += vyi;
            s[i] += (out[2] - s[i]) * 0.12f; a[i] += (out[3] - a[i]) * 0.1f; c[i] = outColor;
        }
    }

    /** Scene layouts: split the particles into groups, each with its own target function. */
    private void layout(int i, float t, float st) {
        switch (scene) {
            case CLOUD: sphere(i, n, t, cloudX, cloudY, 290, 0.22f, 2.5f, 0.95f); return;
            case COLLAPSE: {
                float r = st < 0.7f ? 30 + 260 * (1 - st / 0.7f) * (1 - st / 0.7f) : 30 + (float) Math.sin(st * 12) * 6;
                sphere(i, n, t, cloudX, cloudY, r, 3f, 2.2f, 0.95f); return;
            }
            case PHONE: {
                int g = (int) (n * 0.62f);
                if (i < g) shape(i, t, phone(800, 330, 330), j -> j % 5 == 0 ? 3 : 0, 2.2f, 0.9f);
                else sphere(i - g, n - g, t, 800, 330, 430, 0.07f, 1.6f, 0.35f);
                return;
            }
            case PERMISSION: {
                int g1 = (int) (n * 0.2f), g2 = g1 + (int) (n * 0.4f), g3 = g2 + (int) (n * 0.12f);
                if (i < g1) shape(i, t, phone(430, 320, 240), j -> 3, 2.2f, 0.8f);
                else if (i < g2) shape(i - g1, t, tv(1110, 310, 440), j -> 0, 2.2f, 0.9f);
                else if (i < g3) stream(i - g2, t, new float[][]{{520, 300, 780, 150, 880, 300}}, 0.45f);
                else stars(i - g3, t, 0.35f, 1.7f);
                return;
            }
            case STARS: stars(i, t, 0.75f, 2.1f); return;
            case SCREENS: {
                int g1 = (int) (n * 0.5f), g2 = g1 + (int) (n * 0.08f), g3 = g2 + (int) (n * 0.2f);
                if (i < g1) shape(i, t, devices(), j -> 0, 2.2f, 0.9f);
                else if (i < g2) shape(i - g1, t, phone(800, 520, 140), j -> 3, 2.2f, 0.9f);
                else if (i < g3) stream(i - g2, t, new float[][]{{800, 450, 560, 380, 380, 400}, {800, 450, 800, 400, 800, 370}, {800, 450, 1040, 380, 1230, 380}}, 0.42f);
                else stars(i - g3, t, 0.3f, 1.7f);
                return;
            }
            case IDLE: default: sphere(i, n, t, cloudX, cloudY, 130 + 10 * (float) Math.sin(t * 1.1), 0.12f, 2.1f, 0.85f);
        }
    }

    private void sphere(int j, int count, float t, float cx, float cy, float r, float spin, float size, float alpha) {
        float kk = j + 0.5f;
        double phi = Math.acos(1 - 2 * kk / count), th = 2.39996 * kk;
        double px = Math.cos(th) * Math.sin(phi), py = Math.cos(phi), pz = Math.sin(th) * Math.sin(phi);
        double an = t * spin, ca = Math.cos(an), sa = Math.sin(an);
        double x2 = px * ca + pz * sa, z2 = -px * sa + pz * ca;
        double tilt = 0.5, y2 = py * Math.cos(tilt) - z2 * Math.sin(tilt), z3 = py * Math.sin(tilt) + z2 * Math.cos(tilt);
        float rr = r * (0.85f + 0.3f * rnd(j, 5)) * (1 + 0.04f * (float) Math.sin(t * 1.3 + j * 0.37));
        float d = (float) (z3 + 1) / 2;
        out[0] = cx + (float) x2 * rr; out[1] = cy + (float) y2 * rr; out[2] = size * (0.4f + 0.9f * d); out[3] = alpha * (0.12f + 0.88f * d);
        outColor = j % 4;
    }

    private interface ColorOf { int of(int j); }

    private void shape(int j, float t, float[] pts, ColorOf color, float size, float alpha) {
        int count = pts.length / 2, p = (j % count) * 2;
        out[0] = pts[p] + (float) Math.sin(t * 1.7 + j) * 1.6f; out[1] = pts[p + 1] + (float) Math.cos(t * 1.3 + j * 1.7) * 1.6f;
        out[2] = size * (0.75f + 0.5f * rnd(j, 3)); out[3] = alpha * (0.72f + 0.28f * (float) Math.sin(t * 2 + j));
        outColor = color.of(j);
    }

    private void stars(int j, float t, float alpha, float size) {
        out[0] = rnd(j, 11) * W + (float) Math.sin(t * 0.2 + j) * 5; out[1] = rnd(j, 13) * H + (float) Math.cos(t * 0.17 + j) * 5;
        float b = rnd(j, 17);
        out[2] = size * (0.5f + b * 1.3f);
        out[3] = alpha * (0.3f + 0.7f * (0.5f + 0.5f * (float) Math.sin(t * (0.5 + rnd(j, 19) * 2) + j))) * (0.35f + b * 0.65f);
        outColor = j % 4;
    }

    private void stream(int j, float t, float[][] paths, float speed) {
        float[] p = paths[j % paths.length];
        float u = (rnd(j, 23) + t * speed * (0.7f + 0.6f * rnd(j, 29))) % 1f, iu = 1 - u;
        float tx = iu * iu * p[0] + 2 * iu * u * p[2] + u * u * p[4] + (rnd(j, 31) - 0.5f) * 10;
        float ty = iu * iu * p[1] + 2 * iu * u * p[3] + u * u * p[5] + (rnd(j, 37) - 0.5f) * 10;
        out[0] = tx; out[1] = ty; out[2] = 2.3f * (0.6f + 0.6f * rnd(j, 39)); out[3] = 0.95f * (float) Math.sin(u * Math.PI);
        outColor = 1 + j % 2; outSnap = u < 0.025f;
    }

    // ---- shapes, sampled once from paths ----
    private float[] phone(float cx, float cy, float h) {
        return shapes.computeIfAbsent("phone" + cx + "," + cy + "," + h, key -> {
            float w = h * 0.49f, r = h * 0.14f;
            Path body = new Path(); body.addRoundRect(new RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), r, r, Path.Direction.CW);
            Path notch = new Path(); notch.addRoundRect(new RectF(cx - w * 0.16f, cy - h / 2 + h * 0.045f, cx + w * 0.16f, cy - h / 2 + h * 0.09f), h * 0.025f, h * 0.025f, Path.Direction.CW);
            List<float[]> pts = new ArrayList<>(); outline(body, 4, pts); outline(notch, 4, pts); fill(body, 13, pts); return pack(pts);
        });
    }

    private float[] tv(float cx, float cy, float w) {
        return shapes.computeIfAbsent("tv" + cx + "," + cy + "," + w, key -> { List<float[]> pts = new ArrayList<>(); tvInto(cx, cy, w, pts); return pack(pts); });
    }

    private void tvInto(float cx, float cy, float w, List<float[]> pts) {
        float h = w * 0.56f;
        Path screen = new Path(); screen.addRoundRect(new RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), w * 0.02f, w * 0.02f, Path.Direction.CW);
        Path stand = new Path(); stand.moveTo(cx, cy + h / 2); stand.lineTo(cx, cy + h / 2 + w * 0.06f); stand.moveTo(cx - w * 0.16f, cy + h / 2 + w * 0.06f); stand.lineTo(cx + w * 0.16f, cy + h / 2 + w * 0.06f);
        outline(screen, 4, pts); outline(stand, 4, pts); fill(screen, 18, pts);
    }

    private float[] devices() {
        return shapes.computeIfAbsent("devices", key -> {
            List<float[]> pts = new ArrayList<>();
            // Laptop at (360, 290), TV at (800, 250), desktop monitor at (1240, 270).
            float lw = 320, sw = lw * 0.78f, sh = sw * 0.62f, lx = 360, ly = 290;
            Path lap = new Path(); lap.addRoundRect(new RectF(lx - sw / 2, ly - sh / 2 - lw * 0.04f, lx + sw / 2, ly + sh / 2 - lw * 0.04f), lw * 0.025f, lw * 0.025f, Path.Direction.CW);
            Path base = new Path(); base.moveTo(lx - sw / 2, ly + sh / 2 - lw * 0.03f); base.lineTo(lx - lw / 2, ly + sh / 2 + lw * 0.05f); base.lineTo(lx + lw / 2, ly + sh / 2 + lw * 0.05f); base.lineTo(lx + sw / 2, ly + sh / 2 - lw * 0.03f);
            outline(lap, 4, pts); outline(base, 4, pts); fill(lap, 15, pts);
            tvInto(800, 250, 380, pts);
            float mw = 300, mh = mw * 0.58f, mx = 1240, my = 270;
            Path mon = new Path(); mon.addRoundRect(new RectF(mx - mw / 2, my - mh / 2, mx + mw / 2, my + mh / 2), mw * 0.02f, mw * 0.02f, Path.Direction.CW);
            Path neck = new Path(); neck.moveTo(mx, my + mh / 2); neck.lineTo(mx, my + mh / 2 + mw * 0.12f); neck.moveTo(mx - mw * 0.15f, my + mh / 2 + mw * 0.12f); neck.lineTo(mx + mw * 0.15f, my + mh / 2 + mw * 0.12f);
            outline(mon, 4, pts); outline(neck, 4, pts); fill(mon, 15, pts);
            return pack(pts);
        });
    }

    private static void outline(Path path, float spacing, List<float[]> pts) {
        PathMeasure m = new PathMeasure(path, false);
        float[] pos = new float[2];
        do {
            float len = m.getLength();
            for (float d = 0; d < len; d += spacing) { m.getPosTan(d, pos, null); pts.add(new float[]{pos[0], pos[1]}); }
        } while (m.nextContour());
    }

    private static void fill(Path path, float spacing, List<float[]> pts) {
        RectF b = new RectF(); path.computeBounds(b, true);
        Region clip = new Region((int) b.left - 1, (int) b.top - 1, (int) b.right + 1, (int) b.bottom + 1), region = new Region();
        region.setPath(path, clip);
        Random r = new Random(11);
        for (float yy = b.top; yy < b.bottom; yy += spacing) for (float xx = b.left; xx < b.right; xx += spacing) {
            float jx = xx + (r.nextFloat() - 0.5f) * spacing * 0.5f, jy = yy + (r.nextFloat() - 0.5f) * spacing * 0.5f;
            if (region.contains((int) jx, (int) jy)) pts.add(new float[]{jx, jy});
        }
    }

    /** Shuffles so that any prefix of the list covers the whole shape evenly. */
    private static float[] pack(List<float[]> pts) {
        java.util.Collections.shuffle(pts, new Random(3));
        float[] packed = new float[pts.size() * 2];
        for (int i = 0; i < pts.size(); i++) { packed[i * 2] = pts.get(i)[0]; packed[i * 2 + 1] = pts.get(i)[1]; }
        return packed;
    }

    static float rnd(int i, int k) { double v = Math.sin(i * 127.1 + k * 311.7) * 43758.5453; return (float) (v - Math.floor(v)); }
}
