package com.chekusu.sofatap.controller;

import java.util.LinkedHashMap;
import java.util.Map;

/** Touch recognition in dp and monotonic milliseconds, without Android dependencies. */
public final class GestureEngine {
    public interface Listener {
        void move(double dx, double dy);
        void scroll(double dx, double dy);
        void click(boolean right, int count);
        void drag(boolean down);
        void navigate(String direction);
        void back();
    }

    public static final long LONG_PRESS_MS = 300;
    public static final long DOUBLE_TAP_MS = 280;
    public static final long TV_REPEAT_MS = 150;
    public static final double EDGE_WIDTH = 26;
    private static final double SLOP = 7;
    private static final double DOUBLE_TAP_DISTANCE = 32;
    private static final double TV_STEP = 32;
    private static final long MOTION_INTERVAL_MS = 16;

    private static final class Contact {
        final double startX, startY;
        double x, y;
        Contact(double x, double y) { startX = this.x = x; startY = this.y = y; }
    }

    private final Listener listener;
    private final Map<Integer, Contact> contacts = new LinkedHashMap<>();
    private boolean tvMode, edge, moved, dragging, suppressed, secondTap, multiMoved;
    private int peakContacts;
    private double width, startX, startY, previousX, previousY, tvAnchorX, tvAnchorY;
    private long startedAt, lastNavigationAt = Long.MIN_VALUE, lastMotionAt;
    private double queuedMoveX, queuedMoveY, queuedScrollX, queuedScrollY;
    private boolean pendingTap;
    private double pendingX, pendingY;
    private long pendingAt;
    private boolean pendingRightHalf;

    public GestureEngine(Listener listener) { this.listener = listener; }

    public void setTvMode(boolean enabled) {
        if (tvMode == enabled) return;
        cancel();
        tvMode = enabled;
    }

    public boolean isDragging() { return dragging; }
    public boolean isEdgeScrolling() { return !contacts.isEmpty() && edge && moved && !suppressed; }

    public void down(int pointerId, double x, double y, double surfaceWidth, long now) {
        if (!valid(x, y) || !Double.isFinite(surfaceWidth) || surfaceWidth <= 0) {
            cancel();
            return;
        }
        if (contacts.containsKey(pointerId)) { cancel(); return; }
        if (contacts.isEmpty()) {
            tick(now);
            width = surfaceWidth;
            secondTap = !tvMode && pendingTap && now - pendingAt <= DOUBLE_TAP_MS
                    && Math.hypot(x - pendingX, y - pendingY) <= DOUBLE_TAP_DISTANCE
                    && (x >= width / 2) == pendingRightHalf;
            if (!secondTap) flushTap();
            startX = previousX = tvAnchorX = x;
            startY = previousY = tvAnchorY = y;
            startedAt = now;
            lastMotionAt = now;
            lastNavigationAt = Long.MIN_VALUE;
            edge = !tvMode && x >= width - EDGE_WIDTH;
            moved = suppressed = multiMoved = false;
            peakContacts = 1;
        } else {
            flushMotion();
            flushTap();
            secondTap = false;
            releaseDrag();
            if (edge || contacts.size() >= 2) suppressed = true;
            multiMoved |= moved;
            peakContacts = Math.max(peakContacts, contacts.size() + 1);
        }
        contacts.put(pointerId, new Contact(x, y));
        previousX = centroidX();
        previousY = centroidY();
    }

    /** One call per complete MotionEvent sample; coordinates must include all active IDs. */
    public void move(int[] ids, double[] xs, double[] ys, long now) {
        if (contacts.isEmpty()) return;
        if (ids.length != contacts.size() || ids.length != xs.length || ids.length != ys.length) {
            cancel();
            return;
        }
        java.util.HashSet<Integer> seen = new java.util.HashSet<>();
        for (int i = 0; i < ids.length; i++) {
            Contact contact = contacts.get(ids[i]);
            if (contact == null || !seen.add(ids[i]) || !valid(xs[i], ys[i])) {
                cancel();
                return;
            }
            contact.x = xs[i];
            contact.y = ys[i];
            if (Math.hypot(contact.x - contact.startX, contact.y - contact.startY) > SLOP) {
                multiMoved = true;
            }
        }
        double x = centroidX(), y = centroidY();
        if (suppressed) { previousX = x; previousY = y; return; }
        if (peakContacts > 1) {
            if (contacts.size() == 2 && !tvMode) {
                if (multiMoved) {
                    moved = true;
                    queueScroll(x - previousX, y - previousY, now);
                }
            }
            previousX = x;
            previousY = y;
            return;
        }
        double distance = Math.hypot(x - startX, y - startY);
        if (!moved && !dragging && distance <= (edge ? 3 : SLOP)) {
            tick(now);
            return;
        }
        moved = true;
        flushTap();
        secondTap = false;
        if (tvMode) {
            double dx = x - tvAnchorX, dy = y - tvAnchorY;
            if (Math.max(Math.abs(dx), Math.abs(dy)) >= TV_STEP) {
                if (lastNavigationAt == Long.MIN_VALUE || now - lastNavigationAt >= TV_REPEAT_MS) {
                    listener.navigate(Math.abs(dx) > Math.abs(dy)
                            ? (dx > 0 ? "right" : "left") : (dy > 0 ? "down" : "up"));
                    lastNavigationAt = now;
                    tvAnchorX = x;
                    tvAnchorY = y;
                }
            }
        } else if (edge) {
            // A scrollbar drag moves the document in the finger direction, unlike natural scrolling.
            queueScroll(0, -(y - previousY), now);
        } else {
            queuedMoveX = bounded(queuedMoveX + x - previousX, 240);
            queuedMoveY = bounded(queuedMoveY + y - previousY, 240);
            flushIfDue(now);
        }
        previousX = x;
        previousY = y;
    }

    public void up(int pointerId, double x, double y, long now) {
        Contact contact = contacts.get(pointerId);
        if (contact == null || !valid(x, y)) { cancel(); return; }
        if (Math.hypot(x - contact.startX, y - contact.startY) > SLOP) multiMoved = true;
        // The final sample may carry movement even when no MOVE was delivered.
        int[] ids = new int[contacts.size()];
        double[] xs = new double[ids.length], ys = new double[ids.length];
        int i = 0;
        for (Map.Entry<Integer, Contact> item : contacts.entrySet()) {
            ids[i] = item.getKey();
            xs[i] = ids[i] == pointerId ? x : item.getValue().x;
            ys[i] = ids[i] == pointerId ? y : item.getValue().y;
            i++;
        }
        move(ids, xs, ys, now);
        if (!contacts.containsKey(pointerId)) return;
        contacts.remove(pointerId);
        if (!contacts.isEmpty()) {
            // Never turn the surviving finger of a scroll into a cursor move or a tap.
            previousX = centroidX();
            previousY = centroidY();
            return;
        }
        flushMotion();
        boolean wasDragging = dragging;
        releaseDrag();
        if (!suppressed && !wasDragging && !moved && !multiMoved && now - startedAt < LONG_PRESS_MS) {
            if (peakContacts == 2) {
                if (tvMode) listener.back(); else listener.click(true, 1);
            } else if (peakContacts == 1 && !edge) {
                if (tvMode) {
                    listener.navigate("confirm");
                } else if (secondTap && pendingTap) {
                    pendingTap = false;
                    listener.click(pendingRightHalf, pendingRightHalf ? 1 : 2);
                } else {
                    pendingTap = true;
                    pendingX = x;
                    pendingY = y;
                    pendingAt = now;
                    pendingRightHalf = startX >= width / 2;
                }
            }
        }
        secondTap = false;
    }

    /** Called by the view's frame clock so stationary holds and deferred taps resolve. */
    public void tick(long now) {
        if (pendingTap && !secondTap && now - pendingAt > DOUBLE_TAP_MS) flushTap();
        if (!tvMode && contacts.size() == 1 && peakContacts == 1 && !edge && !suppressed
                && !moved && !dragging && now - startedAt >= LONG_PRESS_MS) {
            flushTap();
            secondTap = false;
            dragging = true;
            listener.drag(true);
        }
        flushIfDue(now);
    }

    /** Cancels delayed actions and releases any held mouse button without replaying motion. */
    public void cancel() {
        contacts.clear();
        queuedMoveX = queuedMoveY = queuedScrollX = queuedScrollY = 0;
        pendingTap = secondTap = false;
        suppressed = moved = multiMoved = edge = false;
        peakContacts = 0;
        lastNavigationAt = Long.MIN_VALUE;
        releaseDrag();
    }

    private void releaseDrag() {
        if (dragging) {
            dragging = false;
            listener.drag(false);
        }
    }

    private void queueScroll(double dx, double dy, long now) {
        queuedScrollX = bounded(queuedScrollX + dx, 120);
        queuedScrollY = bounded(queuedScrollY + dy, 120);
        flushIfDue(now);
    }

    private void flushIfDue(long now) {
        if (now - lastMotionAt >= MOTION_INTERVAL_MS) {
            flushMotion();
            lastMotionAt = now;
        }
    }

    private void flushMotion() {
        double mx = queuedMoveX, my = queuedMoveY, sx = queuedScrollX, sy = queuedScrollY;
        queuedMoveX = queuedMoveY = queuedScrollX = queuedScrollY = 0;
        if (mx != 0 || my != 0) listener.move(mx, my);
        if (sx != 0 || sy != 0) listener.scroll(sx, sy);
    }

    private void flushTap() {
        if (pendingTap) {
            pendingTap = false;
            listener.click(false, 1);
        }
    }

    private double centroidX() {
        double total = 0;
        for (Contact contact : contacts.values()) total += contact.x;
        return total / contacts.size();
    }

    private double centroidY() {
        double total = 0;
        for (Contact contact : contacts.values()) total += contact.y;
        return total / contacts.size();
    }

    private static boolean valid(double x, double y) { return Double.isFinite(x) && Double.isFinite(y); }
    private static double bounded(double value, double limit) { return Math.max(-limit, Math.min(limit, value)); }
}
