package com.chekusu.sofatap.controller;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;

import java.util.ArrayList;
import java.util.Iterator;

/** Native dot field, effects and gesture input. Controls are overlaid by the activity. */
public final class TouchSurfaceView extends View {
    public interface Listener extends GestureEngine.Listener { }

    private static final int MINT = Color.rgb(178, 245, 209);
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF surface = new RectF();
    private final Path clip = new Path();
    private final float density;
    private final GestureEngine engine;
    private Listener listener;
    private final ArrayList<Ripple> ripples = new ArrayList<>();
    private boolean tvMode, touching, running, reducedMotion;
    private float fingerX, fingerY, touchStrength;
    private final long bornAt = SystemClock.uptimeMillis();

    private static final class Ripple {
        final float x, y;
        final long startedAt;
        final boolean strong;
        Ripple(float x, float y, long startedAt, boolean strong) {
            this.x = x; this.y = y; this.startedAt = startedAt; this.strong = strong;
        }
    }

    private final Runnable frame = new Runnable() {
        @Override public void run() {
            if (!running) return;
            engine.tick(SystemClock.uptimeMillis());
            touchStrength += ((touching ? 1 : 0) - touchStrength) * .16f;
            invalidate();
            postDelayed(this, touching || !ripples.isEmpty() || touchStrength > .01f ? 16 : 50);
        }
    };

    public TouchSurfaceView(Context context) {
        super(context);
        density = getResources().getDisplayMetrics().density;
        setClickable(true);
        setFocusable(true);
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
        engine = new GestureEngine(new GestureEngine.Listener() {
            @Override public void move(double dx, double dy) { if (listener != null) listener.move(dx, dy); }
            @Override public void scroll(double dx, double dy) { if (listener != null) listener.scroll(dx, dy); }
            @Override public void click(boolean right, int count) {
                feedback(right || count > 1);
                if (listener != null) listener.click(right, count);
            }
            @Override public void drag(boolean down) {
                if (down) feedback(true);
                if (listener != null) listener.drag(down);
            }
            @Override public void navigate(String direction) {
                feedback(false);
                if (listener != null) listener.navigate(direction);
            }
            @Override public void back() {
                feedback(true);
                if (listener != null) listener.back();
            }
        });
    }

    public void setListener(Listener next) { cancelGesture(); listener = next; }
    public void setTvMode(boolean enabled) {
        if (tvMode != enabled) cancelGesture();
        tvMode = enabled;
        engine.setTvMode(enabled);
        invalidate();
    }

    public void cancelGesture() {
        if (engine != null) engine.cancel();
        touching = false;
    }

    @Override public void setEnabled(boolean enabled) {
        if (!enabled) cancelGesture();
        super.setEnabled(enabled);
        invalidate();
    }

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        reducedMotion = Settings.Global.getFloat(getContext().getContentResolver(),
                Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0;
        updateFrameClock();
    }

    @Override protected void onDetachedFromWindow() {
        running = false;
        removeCallbacks(frame);
        cancelGesture();
        super.onDetachedFromWindow();
    }

    @Override protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        if (visibility != VISIBLE) cancelGesture();
        updateFrameClock();
    }

    @Override protected void onVisibilityChanged(View changedView, int visibility) {
        super.onVisibilityChanged(changedView, visibility);
        if (engine == null) return;
        if (!isShown()) cancelGesture();
        updateFrameClock();
    }

    @Override public void onWindowFocusChanged(boolean hasWindowFocus) {
        super.onWindowFocusChanged(hasWindowFocus);
        if (!hasWindowFocus) cancelGesture();
    }

    private void updateFrameClock() {
        boolean shouldRun = isAttachedToWindow() && getWindowVisibility() == VISIBLE && isShown();
        if (shouldRun == running) return;
        running = shouldRun;
        removeCallbacks(frame);
        if (running) post(frame);
    }

    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        cancelGesture();
        surface.set(density, density, w - density, h - density);
        clip.reset();
        clip.addRoundRect(surface, 32 * density, 32 * density, Path.Direction.CW);
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        long now = SystemClock.uptimeMillis();
        float seconds = reducedMotion ? 0 : (now - bornAt) / 1000f;
        canvas.save();
        canvas.clipPath(clip);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(Color.rgb(14, 23, 25));
        canvas.drawRect(surface, paint);
        float step = 20 * density;
        float radius = 100 * density;
        for (float row = step; row < getHeight(); row += step) {
            for (float col = step; col < getWidth(); col += step) {
                float x = col + (float) Math.sin(seconds * .28 + row / (130 * density)) * 2.5f * density;
                float y = row + (float) Math.cos(seconds * .22 + col / (150 * density)) * 2.5f * density;
                float influence = 0;
                if (!reducedMotion && touchStrength > .01f) {
                    float dx = x - fingerX, dy = y - fingerY;
                    float distance = (float) Math.sqrt(dx * dx + dy * dy);
                    influence = Math.max(0, 1 - distance / radius) * touchStrength;
                    float displacement = influence * influence * 16 * density;
                    if (distance > .1f) { x += dx / distance * displacement; y += dy / distance * displacement; }
                }
                paint.setColor(MINT);
                paint.setAlpha((int) ((isEnabled() ? 45 : 23) + influence * 100
                        + 9 * Math.sin(seconds * .5 + col / step * .32 + row / step * .27)));
                canvas.drawCircle(x, y, (.85f + influence * .6f) * density, paint);
            }
        }
        Iterator<Ripple> iterator = ripples.iterator();
        while (iterator.hasNext()) {
            Ripple ripple = iterator.next();
            float progress = (now - ripple.startedAt) / (reducedMotion ? 180f : 620f);
            if (progress >= 1) { iterator.remove(); continue; }
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(MINT);
            paint.setAlpha((int) ((1 - progress) * (ripple.strong ? 180 : 120)));
            paint.setStrokeWidth((ripple.strong ? 1.7f : 1.1f) * density);
            float r = (reducedMotion ? 16 : 8 + 62 * (1 - (1 - progress) * (1 - progress))) * density;
            canvas.drawCircle(ripple.x, ripple.y, r, paint);
            if (ripple.strong && !reducedMotion) canvas.drawCircle(ripple.x, ripple.y, r * .64f, paint);
        }
        if (engine.isDragging()) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(1.3f * density);
            paint.setColor(MINT);
            paint.setAlpha(140);
            canvas.drawCircle(fingerX, fingerY, 18 * density, paint);
        }
        if (!tvMode) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(MINT);
            paint.setAlpha(engine.isEdgeScrolling() ? 150 : 35);
            float trackX = getWidth() - 13 * density;
            canvas.drawRoundRect(trackX - density, getHeight() * .25f, trackX + density,
                    getHeight() * .69f, density, density, paint);
        }
        canvas.restore();
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(density);
        paint.setColor(MINT);
        paint.setAlpha(isFocused() ? 80 : 24);
        canvas.drawRoundRect(surface, 32 * density, 32 * density, paint);
    }

    // Raw taps are delayed by GestureEngine to distinguish double taps. performClick below
    // remains the immediate accessibility action and must not fire a second raw-tap command.
    @SuppressLint("ClickableViewAccessibility")
    @Override public boolean onTouchEvent(MotionEvent event) {
        if (!isEnabled()) return false;
        int action = event.getActionMasked();
        int index = event.getActionIndex();
        long now = event.getEventTime();
        fingerX = event.getX(index);
        fingerY = event.getY(index);
        if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_POINTER_DOWN) {
            if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(true);
            touching = true;
            engine.down(event.getPointerId(index), fingerX / density, fingerY / density,
                    getWidth() / density, now);
        } else if (action == MotionEvent.ACTION_MOVE) {
            int count = event.getPointerCount();
            int[] ids = new int[count];
            double[] xs = new double[count], ys = new double[count];
            for (int i = 0; i < count; i++) {
                ids[i] = event.getPointerId(i);
                xs[i] = event.getX(i) / density;
                ys[i] = event.getY(i) / density;
            }
            engine.move(ids, xs, ys, now);
        } else if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_POINTER_UP) {
            engine.up(event.getPointerId(index), fingerX / density, fingerY / density, now);
            touching = action != MotionEvent.ACTION_UP;
            if (!touching && getParent() != null) getParent().requestDisallowInterceptTouchEvent(false);
        } else if (action == MotionEvent.ACTION_CANCEL) {
            cancelGesture();
            if (getParent() != null) getParent().requestDisallowInterceptTouchEvent(false);
        }
        invalidate();
        return true;
    }

    private void feedback(boolean strong) {
        performHapticFeedback(strong ? HapticFeedbackConstants.LONG_PRESS : HapticFeedbackConstants.CLOCK_TICK);
        if (ripples.size() >= 8) ripples.remove(0);
        ripples.add(new Ripple(fingerX, fingerY, SystemClock.uptimeMillis(), strong));
        invalidate();
    }

    /** TalkBack and keyboard accessibility activate the selected target without needing a raw tap. */
    @Override public boolean performClick() {
        super.performClick();
        if (!isEnabled()) return false;
        fingerX = getWidth() / 2f; fingerY = getHeight() / 2f;
        feedback(false);
        if (listener != null) {
            if (tvMode) listener.navigate("confirm"); else listener.click(false, 1);
        }
        return true;
    }

    @Override public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
        super.onInitializeAccessibilityNodeInfo(info);
        info.setClassName("android.widget.Button");
    }
}
