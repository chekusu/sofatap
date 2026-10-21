package com.chekusu.sofatap.controller;

import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.util.ArrayDeque;

/** Foreground-only, acknowledged transport. Input is never replayed across connections. */
public final class RemoteSession {
    public enum State { DISCONNECTED, CONNECTING, CONNECTED, RETRYING, BLOCKED }
    public enum Result { ACCEPTED, REJECTED, UNCERTAIN, SUPERSEDED }
    public interface Completion { void finish(Result result); }
    public interface Listener { void changed(); }
    interface Channel { void connect(); boolean send(JSONObject value); void close(); }
    interface Factory { Channel create(Pairing pairing, PinnedSocket.Listener listener); }
    interface Scheduler { void later(Runnable action, long delay); }
    interface Persistence { void save(Pairing pairing) throws Exception; }
    public State state = State.DISCONNECTED;
    public Pairing pairing;
    public ReceiverStatus status;
    public String failure = "";
    private Listener listener;
    private final Factory factory;
    private final Scheduler scheduler;
    private final Persistence persistence;
    private final java.util.function.LongSupplier clock;
    private Channel channel;
    private int generation, attempt;
    private boolean foreground, paused, bootstrap, blocked;
    private final ArrayDeque<Pending> queue = new ArrayDeque<>();
    private Pending pending;
    private static final int MAX_QUEUE = 24;
    private static final class Pending {
        final JSONObject value; final Completion completion; final long createdAt;
        Pending(JSONObject value, Completion completion,long createdAt) { this.value = value; this.completion = completion; this.createdAt=createdAt; }
        String type() { return value.optString("type"); }
        boolean transientMotion() { return type().equals("move") || type().equals("scroll"); }
        boolean navigationRepeat() { return (type().equals("remote_key") || type().equals("key")) && java.util.Set.of("up","down","left","right").contains(value.optString("key")); }
    }
    public RemoteSession(DeviceStore store, Listener listener) {
        this((p,l) -> {
            PinnedSocket socket = new PinnedSocket(p,l);
            return new Channel() {
                public void connect() { socket.connect(); }
                public boolean send(JSONObject v) { return socket.send(v); }
                public void close() { socket.close(); }
            };
        }, (r,d) -> new Handler(Looper.getMainLooper()).postDelayed(r,d), store::save, listener);
    }
    RemoteSession(Factory factory, Scheduler scheduler, Persistence persistence, Listener listener) {
        this(factory,scheduler,persistence,listener,()->System.nanoTime()/1_000_000);
    }
    RemoteSession(Factory factory, Scheduler scheduler, Persistence persistence, Listener listener, java.util.function.LongSupplier clock) {
        this.factory=factory; this.scheduler=scheduler; this.persistence=persistence; this.listener=listener;this.clock=clock;
    }
    private void changed() { if (listener != null) listener.changed(); }
    public boolean connected() { return state == State.CONNECTED && status != null; }
    public void select(Pairing target, boolean newPairing) {
        stop(); pairing=target; bootstrap=newPairing && target.isTv(); paused=false; blocked=false; attempt=0;
        failure=""; if (foreground) open(); else changed();
    }
    public void resume() { foreground=true; if (pairing!=null && !paused && !blocked && channel==null) open(); }
    public void suspend() { foreground=false; stop(); changed(); }
    public void disconnect() { paused=true; stop(); changed(); }
    public void reconnect() { paused=false; blocked=false; attempt=0; if (foreground && pairing!=null) { stop(); open(); } }
    public void forget() { stop(); pairing=null; paused=true; changed(); }
    private void stop() {
        ++generation;
        Channel old=channel; channel=null;
        if(old!=null) old.close();
        Pending sent=pending; pending=null;
        var abandoned=new ArrayDeque<>(queue); queue.clear();
        status=null; state=State.DISCONNECTED;
        if(sent!=null && sent.completion!=null) sent.completion.finish(Result.UNCERTAIN);
        for(Pending p:abandoned) if(p.completion!=null) p.completion.finish(Result.REJECTED);
    }
    private void open() {
        if(pairing==null || !foreground || paused || blocked) return;
        int current=++generation;
        state=State.CONNECTING; status=null; changed();
        channel=factory.create(pairing,new PinnedSocket.Listener() {
            public void onOpen() { /* Wait for validated hello before allowing actions. */ }
            public void onMessage(JSONObject value) { if(current==generation) receive(value,current); }
            public void onFailure(boolean retryable) { if(current==generation) failed(retryable); }
            public void onClosed() { if(current==generation) failed(true); }
        });
        channel.connect();
        scheduler.later(() -> { if(current==generation && state==State.CONNECTING) failed(true); }, 10000);
    }
    private void failed(boolean retryable) {
        boolean retry=retryable && !bootstrap && !paused && foreground && pairing!=null;
        stop(); failure=retryable ? "connection_lost" : "authentication";
        blocked=!retryable || bootstrap;
        if(retry) {
            state=State.RETRYING; int current=generation;
            long delay=Math.min(30000,1000L << Math.min(attempt++,5));
            scheduler.later(() -> { if(current==generation && foreground && !paused && !blocked) open(); }, delay);
        } else if(blocked) state=State.BLOCKED;
        changed();
    }
    private void receive(JSONObject value,int current) {
        try {
            String type=value.getString("type");
            if(type.equals("hello")) {
                if(state!=State.CONNECTING) throw new IllegalArgumentException();
                ReceiverStatus received=ReceiverStatus.fromHello(value,pairing.isTv());
                Pairing authenticated=pairing;
                if(bootstrap) {
                    String token=value.getString("pairingToken");
                    authenticated=pairing.withToken(token);
                } else if(value.has("pairingToken")) throw new IllegalArgumentException();
                persistence.save(authenticated); // No input before credentials are durable.
                pairing=authenticated; bootstrap=false; status=received; state=State.CONNECTED; failure=""; attempt=0;
                changed(); heartbeat(current); drain(); return;
            }
            if(!connected() || !type.equals("ack") || !(value.get("ok") instanceof Boolean)) throw new IllegalArgumentException();
            String id=value.getString("id");
            if(pending==null || !id.equals(pending.value.getString("id"))) return;
            Pending done=pending;
            if(value.has("inputAvailable") || value.has("tvControls")) status=status.withUpdate(value);
            pending=null;
            boolean ok=value.getBoolean("ok");
            String error=value.optString("error","");
            Result result=ok?Result.ACCEPTED:Result.REJECTED;
            if(!ok && (done.type().equals("text") || done.type().equals("text_commit"))) {
                boolean known=error.startsWith("input_failed:") || error.startsWith("input_busy:") ||
                    error.equals("stale_editor") || error.equals("no_editor") || error.equals("sensitive_editor") ||
                    error.equals("input_unavailable") || error.equals("unsupported_action") || error.equals("invalid_text");
                if(!known) result=Result.UNCERTAIN;
            }
            if(done.completion!=null) done.completion.finish(result);
            changed(); drain();
        } catch(Exception ignored) { failed(false); }
    }
    private void heartbeat(int current) {
        scheduler.later(() -> {
            if(current!=generation || !connected()) return;
            if(pending==null && queue.isEmpty()) send(WireActions.ping(),null);
            heartbeat(current);
        }, pairing.isTv()?1000:1500);
    }
    public boolean send(JSONObject value,Completion completion) {
        if(!connected() || !foreground || !allowed(value)) return false;
        Pending added=new Pending(value,completion,clock.getAsLong());
        if(pairing.isTv() && (added.type().equals("remote_key") || added.type().equals("key"))) {
            // Focus navigation is an intent, not a backlog. A new direction/Back/Home/OK
            // supersedes all unsent directional repeats while retaining in-flight order.
            var it=queue.iterator();
            while(it.hasNext()) { Pending old=it.next();if(old.navigationRepeat()){it.remove();if(old.completion!=null)old.completion.finish(Result.SUPERSEDED);} }
        }
        // Bound backpressure and coalesce only consecutive unsent motion, never across clicks/keys.
        Pending tail=queue.peekLast();
        if(added.transientMotion() && tail!=null && tail.type().equals(added.type())) {
            try {
                double limit=added.type().equals("move")||pairing.isTv()?500:1200;
                value.put("dx",Math.max(-limit,Math.min(limit,value.getDouble("dx")+tail.value.getDouble("dx"))));
                value.put("dy",Math.max(-limit,Math.min(limit,value.getDouble("dy")+tail.value.getDouble("dy"))));
                queue.removeLast();
                if(tail.completion!=null) tail.completion.finish(Result.SUPERSEDED);
            } catch(Exception ignored) { return false; }
        }
        if(queue.size()>=MAX_QUEUE) {
            // Closing releases the remote button if a drag-up cannot be queued.
            if(added.type().equals("button") && !value.optBoolean("down",true)) failed(true);
            return false;
        }
        queue.add(added); drain(); return true;
    }
    private boolean allowed(JSONObject action) {
        if(status==null || pairing==null) return false;
        String type=action.optString("type");
        if(type.equals("ping")) return true;
        if(!pairing.isTv()) {
            if(!status.ready) return false;
            return switch(type) {
                case "move" -> status.canMove;
                case "click" -> action.optString("button").equals("right") ? status.canRightClick : status.canClick;
                case "scroll" -> status.canScroll;
                case "button" -> status.canDrag;
                case "text" -> status.canText;
                case "key" -> true;
                default -> false;
            };
        }
        return switch(type) {
            case "move" -> status.canMove;
            case "click" -> status.canClick;
            case "scroll" -> status.canScroll;
            case "remote_key" -> status.canNavigate;
            case "key" -> action.optString("key").equals("back") ? status.canBack : action.optString("key").equals("home") && status.canHome;
            case "remote_pair_start" -> !"screen_locked".equals(status.inputStatus) && status.navigationStatus!=null && !status.navigationStatus.equals("unsupported");
            case "remote_pair_code" -> "pairing".equals(status.navigationStatus);
            case "text_commit", "text_backspace", "text_action" -> status.canText && action.optString("editorEpoch").equals(status.editorEpoch);
            default -> false;
        };
    }
    private void drain() {
        if(!connected() || pending!=null || queue.isEmpty()) return;
        Pending next=queue.removeFirst();
        boolean stale=(next.transientMotion() || pairing.isTv() && next.navigationRepeat()) && clock.getAsLong()-next.createdAt>350;
        if(!allowed(next.value) || stale) {
            if(next.completion!=null) next.completion.finish(stale?Result.SUPERSEDED:Result.REJECTED);
            drain(); return;
        }
        pending=next;
        if(channel==null || !channel.send(next.value)) { failed(true); return; }
        int current=generation;
        scheduler.later(() -> {
            if(current==generation && pending==next) failed(true);
        }, next.type().startsWith("remote_pair")?15000:4000);
    }
}
