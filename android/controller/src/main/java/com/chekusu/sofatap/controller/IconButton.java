package com.chekusu.sofatap.controller;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.ShapeDrawable;
import android.graphics.drawable.shapes.OvalShape;
import android.content.res.ColorStateList;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;

/** Small native vector control. The caller supplies a localized content description. */
public final class IconButton extends View {
    private static final int MINT = Color.rgb(178, 245, 209);
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final RectF rect = new RectF();
    private String icon;
    private boolean active, primary;

    public IconButton(Context context, String icon) {
        super(context);
        this.icon = icon;
        setClickable(true);
        setFocusable(true);
        setMinimumWidth(dp(44));
        setMinimumHeight(dp(44));
        ShapeDrawable mask = new ShapeDrawable(new OvalShape());
        mask.getPaint().setColor(Color.WHITE);
        setBackground(new RippleDrawable(ColorStateList.valueOf(0x40B2F5D1), null, mask));
        setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    public IconButton(Context context) { this(context, "more"); }
    public void setIcon(String value) { icon = value; invalidate(); }
    public void setPrimary(boolean value) { primary = value; invalidate(); }
    public void setActive(boolean value) {
        active = value;
        setActivated(value);
        invalidate();
    }
    public boolean isActive() { return active; }

    @Override public void setPressed(boolean pressed) {
        super.setPressed(pressed);
        animate().scaleX(pressed ? .90f : 1f).scaleY(pressed ? .90f : 1f)
                .setDuration(pressed ? 80 : 150).start();
    }

    @Override public boolean performClick() {
        if (!isEnabled()) return false;
        performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);
        return super.performClick();
    }

    @Override protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
        setMeasuredDimension(resolveSize(dp(44), widthMeasureSpec), resolveSize(dp(44), heightMeasureSpec));
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float cx = getWidth() / 2f, cy = getHeight() / 2f;
        float radius = Math.min(cx, cy) - dp(2);
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(primary ? MINT : 0x20B2F5D1);
        paint.setAlpha(isEnabled() ? (primary ? 255 : 32) : 64);
        if (primary || active) canvas.drawCircle(cx, cy, radius, paint);
        if (isFocused() || (primary && active)) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(1));
            paint.setColor(MINT);
            paint.setAlpha(isFocused() ? 190 : 95);
            canvas.drawCircle(cx, cy, radius - dp(2), paint);
        }
        canvas.save();
        float size = Math.min(dp(primary ? 29 : 23), Math.min(getWidth(), getHeight()) * .60f);
        canvas.translate(cx - size / 2, cy - size / 2);
        canvas.scale(size / 24, size / 24);
        paint.setColor(primary ? Color.rgb(11, 17, 20) : MINT);
        paint.setAlpha(isEnabled() ? 255 : 80);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1.8f);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        drawIcon(canvas);
        canvas.restore();
    }

    private void drawIcon(Canvas canvas) {
        switch (icon == null ? "more" : icon) {
            case "keyboard":
                roundRect(canvas, 2, 4, 22, 19, 2);
                for (int row = 0; row < 2; row++) for (int col = 0; col < 5; col++) {
                    line(canvas, 5 + col * 3.5f, 8 + row * 4, 5.1f + col * 3.5f, 8 + row * 4);
                }
                line(canvas, 7, 16, 17, 16);
                break;
            case "mic":
                if (active) {
                    paint.setStyle(Paint.Style.FILL);
                    roundRect(canvas, 6, 6, 18, 18, 3);
                } else {
                    roundRect(canvas, 8, 2, 16, 15, 4);
                    path.reset(); path.moveTo(5, 10); path.lineTo(5, 12);
                    path.cubicTo(5, 21, 19, 21, 19, 12); path.lineTo(19, 10); canvas.drawPath(path, paint);
                    line(canvas, 12, 19, 12, 23);
                }
                break;
            case "up": polyline(canvas, 5, 15, 12, 8, 19, 15); break;
            case "down": polyline(canvas, 5, 9, 12, 16, 19, 9); break;
            case "left": polyline(canvas, 15, 5, 8, 12, 15, 19); break;
            case "right": polyline(canvas, 9, 5, 16, 12, 9, 19); break;
            case "send": polyline(canvas, 5, 11, 12, 4, 19, 11); line(canvas, 12, 4, 12, 21); break;
            case "check": polyline(canvas, 5, 12, 10, 17, 20, 6); break;
            case "refresh": canvas.drawArc(4, 4, 20, 20, 35, 290, false, paint); polyline(canvas, 15, 3, 21, 3, 21, 9); break;
            case "settings":
                canvas.drawCircle(12, 12, 6, paint); canvas.drawCircle(12, 12, 2, paint);
                for (int i=0;i<8;i++) { double a=i*Math.PI/4; canvas.drawLine(12+(float)Math.cos(a)*6,12+(float)Math.sin(a)*6,12+(float)Math.cos(a)*9,12+(float)Math.sin(a)*9,paint); }
                break;
            case "enter": polyline(canvas, 20, 5, 20, 14, 4, 14); polyline(canvas, 10, 8, 4, 14, 10, 20); break;
            case "trash":
                line(canvas, 4, 6, 20, 6); line(canvas, 9, 3, 15, 3);
                polyline(canvas, 6, 6, 7, 21, 17, 21, 18, 6);
                line(canvas, 10, 10, 10, 17); line(canvas, 14, 10, 14, 17);
                break;
            case "backspace":
                polyline(canvas, 8, 5, 22, 5, 22, 19, 8, 19, 1, 12, 8, 5);
                line(canvas, 12, 9, 18, 15); line(canvas, 18, 9, 12, 15); break;
            case "scan":
                polyline(canvas, 3, 8, 3, 3, 8, 3); polyline(canvas, 16, 3, 21, 3, 21, 8);
                polyline(canvas, 3, 16, 3, 21, 8, 21); polyline(canvas, 16, 21, 21, 21, 21, 16);
                roundRect(canvas, 7, 7, 10, 10, .4f); roundRect(canvas, 14, 7, 17, 10, .4f);
                roundRect(canvas, 7, 14, 10, 17, .4f); polyline(canvas, 14, 14, 17, 14, 17, 17);
                break;
            case "help":
                canvas.drawCircle(12, 12, 9, paint);
                path.reset(); path.moveTo(9, 9); path.cubicTo(9, 5, 16, 6, 15, 10);
                path.cubicTo(14.7f, 11.5f, 12, 11.5f, 12, 14); canvas.drawPath(path, paint);
                line(canvas, 12, 17, 12, 17.1f); break;
            case "devices":
                roundRect(canvas, 2, 4, 17, 16, 2); line(canvas, 9, 16, 9, 21);
                line(canvas, 5, 21, 13, 21); roundRect(canvas, 16, 10, 23, 22, 1);
                break;
            case "back": polyline(canvas, 11, 5, 4, 12, 11, 19); line(canvas, 4, 12, 21, 12); break;
            case "home":
                polyline(canvas, 2, 11, 12, 3, 22, 11);
                polyline(canvas, 5, 10, 5, 21, 10, 21, 10, 15, 14, 15, 14, 21, 19, 21, 19, 10);
                break;
            case "disconnect":
                line(canvas, 12, 2, 12, 11);
                rect.set(3, 4, 21, 22); canvas.drawArc(rect, -45, 270, false, paint); break;
            case "more":
            default:
                for (int i = 0; i < 3; i++) canvas.drawCircle(5 + 7 * i, 12, .8f, paint);
                break;
        }
    }

    private void roundRect(Canvas c, float l, float t, float r, float b, float radius) {
        rect.set(l, t, r, b); c.drawRoundRect(rect, radius, radius, paint);
    }
    private void line(Canvas c, float x1, float y1, float x2, float y2) { c.drawLine(x1, y1, x2, y2, paint); }
    private void polyline(Canvas c, float... xy) {
        path.reset(); path.moveTo(xy[0], xy[1]);
        for (int i = 2; i < xy.length; i += 2) path.lineTo(xy[i], xy[i + 1]);
        c.drawPath(path, paint);
    }
    private int dp(float value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    @Override public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
        super.onInitializeAccessibilityNodeInfo(info);
        info.setClassName("android.widget.Button");
        info.setSelected(active);
    }
}
