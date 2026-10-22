package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import org.junit.Test;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import static org.junit.Assert.*;

/** Independent deterministic tests of the orchestration, with no Android UI or OS input. */
public class RemoteSessionTest {
    private static final class Timer implements RemoteSession.Scheduler {
        private record Scheduled(long at, int order, Runnable action) { }
        private final List<Scheduled> entries = new ArrayList<>();
        long now; int sequence;
        @Override public void later(Runnable action, long delay) { entries.add(new Scheduled(now + delay, sequence++, action)); }
        void advance(long duration) {
            long end = now + duration;
            for (;;) {
                Scheduled next = entries.stream().filter(entry -> entry.at <= end)
                    .min(Comparator.comparingLong(Scheduled::at).thenComparingInt(Scheduled::order)).orElse(null);
                if (next == null) break;
                entries.remove(next); now = next.at; next.action.run();
            }
            now = end;
        }
    }
    private static final class Socket implements RemoteSession.Channel {
        final Pairing pairing; final PinnedSocket.Listener listener;
        final List<JSONObject> sent = new ArrayList<>();
        int connects, closes; boolean sendWorks = true;
        Socket(Pairing pairing, PinnedSocket.Listener listener) { this.pairing = pairing; this.listener = listener; }
        @Override public void connect() { connects++; listener.onOpen(); }
        @Override public boolean send(JSONObject value) {
            if (!sendWorks) return false;
            try { sent.add(new JSONObject(value.toString())); } catch (Exception failure) { throw new AssertionError(failure); }
            return true;
        }
        @Override public void close() { closes++; listener.onClosed(); }
        void message(JSONObject value) { listener.onMessage(value); }
        void ack(int index) throws Exception { ack(index, true, null); }
        void ack(int index, boolean ok, String error) throws Exception {
            JSONObject value = new JSONObject().put("type", "ack").put("id", sent.get(index).getString("id")).put("ok", ok);
            if (error != null) value.put("error", error);
            message(value);
        }
    }
    private static final class Rig {
        final Timer timer = new Timer(); final List<Socket> sockets = new ArrayList<>(); final List<Pairing> saved = new ArrayList<>();
        boolean failSave; int changes;
        final RemoteSession session = new RemoteSession((pairing, listener) -> {
            Socket socket = new Socket(pairing, listener); sockets.add(socket); return socket;
        }, timer, pairing -> { if (failSave) throw new IllegalStateException("test save failure"); saved.add(pairing); }, () -> changes++, () -> timer.now);
        Socket socket() { return sockets.get(sockets.size() - 1); }
        void select(boolean tv, boolean bootstrap) { session.resume(); session.select(PairingTest.pairing(tv), bootstrap); }
        void connectDesktop() throws Exception { select(false, false); socket().message(ReceiverStatusTest.desktop()); }
        void connectTv() throws Exception { select(true, false); socket().message(ReceiverStatusTest.tv(true, "ready", "ready")); }
    }

    @Test public void helloMustValidateAndPersistBeforeAnyInput() throws Exception {
        Rig rig = new Rig(); rig.select(false, false);
        assertEquals(RemoteSession.State.CONNECTING, rig.session.state);
        assertFalse(rig.session.send(WireActions.click(rig.session.pairing, false), null));
        assertTrue(rig.saved.isEmpty()); assertTrue(rig.socket().sent.isEmpty());
        rig.socket().message(ReceiverStatusTest.desktop());
        assertEquals(RemoteSession.State.CONNECTED, rig.session.state); assertEquals(1, rig.saved.size());
        assertTrue(rig.session.send(WireActions.click(rig.session.pairing, false), null));
        assertEquals(1, rig.socket().sent.size());
    }

    @Test public void malformedHelloAndStorageFailureBlockWithoutRetry() throws Exception {
        Rig malformed = new Rig(); malformed.select(false, false);
        malformed.socket().message(ReceiverStatusTest.desktop().put("version", 2));
        assertEquals(RemoteSession.State.BLOCKED, malformed.session.state); assertTrue(malformed.saved.isEmpty());
        malformed.timer.advance(60000); assertEquals(1, malformed.sockets.size());
        Rig unavailableStore = new Rig(); unavailableStore.failSave = true; unavailableStore.select(false, false);
        unavailableStore.socket().message(ReceiverStatusTest.desktop());
        assertEquals(RemoteSession.State.BLOCKED, unavailableStore.session.state);
        assertFalse(unavailableStore.session.connected()); assertEquals(1, unavailableStore.socket().closes);
        assertFalse(unavailableStore.session.send(WireActions.ping(), null));
    }

    @Test public void bootstrapPersistsRotatedCredentialAndReconnectUsesOnlyIt() throws Exception {
        Rig rig = new Rig(); rig.select(true, true);
        String original = rig.session.pairing.token, replacement = "B".repeat(43);
        rig.socket().message(ReceiverStatusTest.tv(true, "ready", "ready").put("pairingToken", replacement));
        assertEquals(replacement, rig.saved.get(0).token); assertNotEquals(original, rig.session.pairing.token);
        rig.socket().listener.onFailure(true); rig.timer.advance(1000);
        assertEquals(2, rig.sockets.size()); assertEquals(replacement, rig.socket().pairing.token);
        assertTrue(rig.socket().sent.isEmpty());
    }

    @Test public void failedBootstrapNeverRetriesAnExpiredQrCredential() throws Exception {
        Rig failed = new Rig(); failed.select(true, true); failed.socket().listener.onFailure(true);
        assertEquals(RemoteSession.State.BLOCKED, failed.session.state);
        failed.timer.advance(120000); assertEquals(1, failed.sockets.size()); assertTrue(failed.saved.isEmpty());
        Rig missingRotation = new Rig(); missingRotation.select(true, true);
        missingRotation.socket().message(ReceiverStatusTest.tv(true, "ready", "ready"));
        assertEquals(RemoteSession.State.BLOCKED, missingRotation.session.state); assertTrue(missingRotation.saved.isEmpty());
    }

    @Test public void savedRetryUsesBoundedExponentialBackoffAndManualDisconnectCancelsIt() {
        Rig rig = new Rig(); rig.select(false, false);
        long[] delays = {1000, 2000, 4000, 8000, 16000, 30000, 30000};
        for (long delay : delays) {
            int previous = rig.sockets.size();
            rig.socket().listener.onFailure(true);
            assertEquals(RemoteSession.State.RETRYING, rig.session.state);
            rig.timer.advance(delay - 1); assertEquals(previous, rig.sockets.size());
            rig.timer.advance(1); assertEquals(previous + 1, rig.sockets.size());
        }
        rig.socket().listener.onFailure(true); int count = rig.sockets.size();
        rig.session.disconnect(); rig.timer.advance(60000); assertEquals(count, rig.sockets.size());
        rig.session.resume(); assertEquals(count, rig.sockets.size());
    }

    @Test public void staleCallbacksFromPreviousSelectionCannotChangeCurrentConnection() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Socket previous = rig.socket();
        Pairing next = Pairing.parse(PairingTest.link(false).replace("192.168.1.2", "192.168.1.9"));
        rig.session.select(next, false); Socket current = rig.socket();
        previous.listener.onFailure(false); previous.message(ReceiverStatusTest.desktop()); previous.listener.onClosed();
        assertEquals(RemoteSession.State.CONNECTING, rig.session.state); assertEquals(next, rig.session.pairing);
        current.message(ReceiverStatusTest.desktop().put("name", "Second receiver"));
        assertEquals("Second receiver", rig.session.status.name); assertEquals(2, rig.saved.size());
        previous.message(new JSONObject().put("type", "invalid"));
        assertEquals(RemoteSession.State.CONNECTED, rig.session.state);
    }

    @Test public void queueCoalescesAdjacentMotionButPreservesClickOrdering() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Pairing p = rig.session.pairing;
        assertTrue(rig.session.send(WireActions.move(p, 1, 2), null));
        assertTrue(rig.session.send(WireActions.move(p, 3, 4), null));
        assertTrue(rig.session.send(WireActions.move(p, 5, 6), null));
        assertTrue(rig.session.send(WireActions.click(p, false), null));
        assertTrue(rig.session.send(WireActions.move(p, 7, 8), null));
        assertEquals(1, rig.socket().sent.size());
        rig.socket().ack(0);
        assertEquals(8, rig.socket().sent.get(1).getDouble("dx"), 0);
        assertEquals(10, rig.socket().sent.get(1).getDouble("dy"), 0);
        rig.socket().ack(1); assertEquals("click", rig.socket().sent.get(2).getString("type"));
        rig.socket().ack(2); assertEquals(7, rig.socket().sent.get(3).getDouble("dx"), 0);
        rig.socket().ack(3); assertEquals(4, rig.socket().sent.size());
    }

    @Test public void queueIsBoundedAndRejectedEnqueueDoesNotMasqueradeAsDelivery() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Pairing p = rig.session.pairing;
        assertTrue(rig.session.send(WireActions.click(p, false), null));
        for (int index = 0; index < 24; index++) assertTrue(rig.session.send(WireActions.click(p, false), null));
        List<RemoteSession.Result> overflow = new ArrayList<>();
        assertFalse(rig.session.send(WireActions.click(p, false), overflow::add));
        assertTrue(overflow.isEmpty()); assertEquals(1, rig.socket().sent.size());
        for (int index = 0; index < 25; index++) rig.socket().ack(index);
        assertEquals(25, rig.socket().sent.size()); assertTrue(rig.session.connected());
    }

    @Test public void fullQueueCannotLoseDragReleaseAndLeaveRemoteButtonHeld() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Pairing p = rig.session.pairing; Socket old = rig.socket();
        assertTrue(rig.session.send(WireActions.button(p, true), null)); old.ack(0);
        List<RemoteSession.Result> inFlight = new ArrayList<>(), queued = new ArrayList<>();
        assertTrue(rig.session.send(WireActions.move(p, 10, 10), inFlight::add));
        for (int index = 0; index < 24; index++) assertTrue(rig.session.send(WireActions.click(p, false), queued::add));
        assertFalse(rig.session.send(WireActions.button(p, false), null));
        assertEquals(1, old.closes); assertEquals(RemoteSession.State.RETRYING, rig.session.state);
        assertEquals(List.of(RemoteSession.Result.UNCERTAIN), inFlight);
        assertEquals(24, queued.size()); assertTrue(queued.stream().allMatch(result -> result == RemoteSession.Result.REJECTED));
        rig.timer.advance(1000); rig.socket().message(ReceiverStatusTest.desktop());
        assertTrue(rig.socket().sent.isEmpty());
        // Receiver disconnect cleanup releases the held button; no queued input is replayed.
    }

    @Test public void slowTvAckDropsOldDirectionalRepeatInsteadOfMovingAfterFingerLifts() throws Exception {
        Rig rig = new Rig(); rig.connectTv(); Pairing p = rig.session.pairing;
        List<RemoteSession.Result> repeated = new ArrayList<>();
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "down"), null));
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "down"), repeated::add));
        rig.timer.advance(351); rig.socket().ack(0);
        assertEquals(List.of(RemoteSession.Result.SUPERSEDED), repeated);
        assertEquals(1, rig.socket().sent.size()); assertTrue(rig.session.connected());
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "back"), null));
        assertEquals("back", rig.socket().sent.get(1).getString("key"));
    }

    @Test public void tvBackSupersedesUnsentDirectionsWithoutWaitingForEachRepeat() throws Exception {
        Rig rig = new Rig(); rig.connectTv(); Pairing p = rig.session.pairing;
        List<RemoteSession.Result> repeats = new ArrayList<>();
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "down"), null));
        for (int index = 0; index < 20; index++) {
            assertTrue(rig.session.send(WireActions.key(p, rig.session.status, index % 2 == 0 ? "down" : "right"), repeats::add));
        }
        assertEquals(19, repeats.size());
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "back"), null));
        assertEquals(20, repeats.size()); assertTrue(repeats.stream().allMatch(result -> result == RemoteSession.Result.SUPERSEDED));
        assertEquals(1, rig.socket().sent.size());
        rig.timer.advance(500); rig.socket().ack(0);
        assertEquals(2, rig.socket().sent.size()); assertEquals("back", rig.socket().sent.get(1).getString("key"));
        rig.socket().ack(1); assertEquals(2, rig.socket().sent.size());
    }

    @Test public void coalescedTvScrollStaysWithinReceiverProtocolBounds() throws Exception {
        Rig rig = new Rig(); rig.connectTv(); Pairing p = rig.session.pairing;
        List<RemoteSession.Result> first = new ArrayList<>(), last = new ArrayList<>();
        rig.session.send(WireActions.ping(), null);
        rig.session.send(WireActions.scroll(p, 400, -400), first::add);
        rig.session.send(WireActions.scroll(p, 400, -400), last::add);
        assertEquals(List.of(RemoteSession.Result.SUPERSEDED), first); assertTrue(last.isEmpty());
        rig.socket().ack(0);
        assertEquals(2, rig.socket().sent.size());
        assertEquals(-500, rig.socket().sent.get(1).getDouble("dx"), 0);
        assertEquals(500, rig.socket().sent.get(1).getDouble("dy"), 0);
        rig.socket().ack(1); assertEquals(List.of(RemoteSession.Result.ACCEPTED), last);
    }

    @Test public void slowAckDoesNotDiscardExplicitDesktopArrowKeysAsTvRepeats() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Pairing p = rig.session.pairing;
        List<RemoteSession.Result> results = new ArrayList<>();
        rig.session.send(WireActions.ping(), null);
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "down"), results::add));
        assertTrue(rig.session.send(WireActions.key(p, rig.session.status, "right"), results::add));
        rig.timer.advance(500); rig.socket().ack(0);
        assertEquals("down", rig.socket().sent.get(1).getString("key"));
        rig.socket().ack(1); assertEquals("right", rig.socket().sent.get(2).getString("key"));
        rig.socket().ack(2); assertEquals(List.of(RemoteSession.Result.ACCEPTED, RemoteSession.Result.ACCEPTED), results);
    }

    @Test public void periodicPingCarriesFreshAvailabilityAndUnmatchedAckCannotStealPendingCommand() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); rig.timer.advance(1500);
        assertEquals("ping", rig.socket().sent.get(0).getString("type"));
        String pingId = rig.socket().sent.get(0).getString("id");
        JSONObject unavailable = ReceiverStatusTest.desktop().put("type", "ack").put("id", pingId).put("ok", true)
            .put("inputAvailable", false).put("inputStatus", "desktop_unavailable");
        rig.socket().message(unavailable); assertFalse(rig.session.status.ready); assertTrue(rig.session.connected());
        List<RemoteSession.Result> result = new ArrayList<>();
        assertTrue(rig.session.send(WireActions.ping(), result::add));
        rig.socket().message(new JSONObject().put("type", "ack").put("id", java.util.UUID.randomUUID().toString()).put("ok", true));
        assertTrue(result.isEmpty()); rig.socket().ack(1); assertEquals(List.of(RemoteSession.Result.ACCEPTED), result);
    }

    @Test public void textTimeoutReportsUncertaintyAndReconnectNeverReplaysInput() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Socket old = rig.socket();
        List<RemoteSession.Result> sent = new ArrayList<>(), queued = new ArrayList<>();
        rig.session.send(WireActions.text(rig.session.pairing, rig.session.status, "first sentence"), sent::add);
        rig.session.send(WireActions.text(rig.session.pairing, rig.session.status, "later dictation"), queued::add);
        rig.timer.advance(4000);
        assertEquals(List.of(RemoteSession.Result.UNCERTAIN), sent); assertEquals(List.of(RemoteSession.Result.REJECTED), queued);
        assertEquals(RemoteSession.State.RETRYING, rig.session.state); assertEquals(1, old.sent.size());
        rig.timer.advance(1000); rig.socket().message(ReceiverStatusTest.desktop());
        assertTrue(rig.socket().sent.isEmpty()); assertTrue(rig.session.connected());
        old.ack(0); assertEquals(List.of(RemoteSession.Result.UNCERTAIN), sent);
    }

    @Test public void backgroundClosesControlChannelAndDropsHeldDragAndQueuedInput() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); Socket old = rig.socket();
        rig.session.send(WireActions.button(rig.session.pairing, true), null); old.ack(0);
        List<RemoteSession.Result> sent = new ArrayList<>(), queued = new ArrayList<>();
        rig.session.send(WireActions.move(rig.session.pairing, 10, 10), sent::add);
        rig.session.send(WireActions.click(rig.session.pairing, false), queued::add);
        rig.session.suspend();
        assertEquals(1, old.closes); assertFalse(rig.session.connected());
        assertEquals(List.of(RemoteSession.Result.UNCERTAIN), sent); assertEquals(List.of(RemoteSession.Result.REJECTED), queued);
        rig.timer.advance(60000); assertEquals(1, rig.sockets.size());
        rig.session.resume(); rig.socket().message(ReceiverStatusTest.desktop());
        assertEquals(2, rig.sockets.size()); assertTrue(rig.socket().sent.isEmpty());
        // Closing the authenticated receiver connection owns the OS button-release cleanup.
    }

    @Test public void malformedStatusAckStillResolvesOutstandingTextAsUncertain() throws Exception {
        Rig rig = new Rig(); rig.connectDesktop(); List<RemoteSession.Result> result = new ArrayList<>();
        rig.session.send(WireActions.text(rig.session.pairing, rig.session.status, "do not duplicate"), result::add);
        rig.socket().message(new JSONObject().put("type", "ack").put("id", rig.socket().sent.get(0).getString("id"))
            .put("ok", true).put("inputAvailable", "invalid"));
        assertEquals(RemoteSession.State.BLOCKED, rig.session.state);
        assertEquals(List.of(RemoteSession.Result.UNCERTAIN), result);
    }

    @Test public void editorChangeRejectsQueuedTvTextBeforeItCanReachAnotherField() throws Exception {
        Rig rig = new Rig(); rig.connectTv(); Socket socket = rig.socket();
        rig.session.send(WireActions.ping(), null);
        List<RemoteSession.Result> result = new ArrayList<>();
        rig.session.send(WireActions.text(rig.session.pairing, rig.session.status, "first field only"), result::add);
        JSONObject changed = ReceiverStatusTest.tv(true, "ready", "ready").put("type", "ack")
            .put("id", socket.sent.get(0).getString("id")).put("ok", true);
        changed.getJSONObject("tvControls").put("editorEpoch", "f65ed4bd-4702-4424-9d1a-a6a8284cbf37");
        socket.message(changed);
        assertEquals(List.of(RemoteSession.Result.REJECTED), result);
        assertEquals(1, socket.sent.size());
    }
}
