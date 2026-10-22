package com.chekusu.sofatap.controller;

import static org.junit.Assert.*;
import org.junit.Test;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Comparator;

/** Actual desktop protocol names, ACK snapshots and UTF-16 selections; no OS input. */
public class LiveTextEditorTest {
    private static final String SESSION = "0582447b-d144-41d3-9dd3-6a6824a4966b";
    private static LiveTextEditor.Snapshot snapshot(String text, int start, int length) { return new LiveTextEditor.Snapshot(text,start,length); }
    private static LiveTextEditor.Snapshot empty() { return snapshot("",0,0); }
    private record Scheduled(long at,Runnable work) { }
    private static final class Rig {
        final List<Scheduled> scheduled = new ArrayList<>();
        final List<Socket> sockets = new ArrayList<>();
        long now;
        final RemoteSession remote = new RemoteSession((p,l)->{Socket s=new Socket(l);sockets.add(s);return s;},
            (r,d)->scheduled.add(new Scheduled(now+d,r)),p->{},()->{},()->now);
        final LiveTextEditor editor = remote.liveText;
        void connect() throws Exception { remote.resume();remote.select(PairingTest.pairing(false),false);socket().listener.onMessage(hello()); }
        Socket socket() { return sockets.get(sockets.size()-1); }
        void advance(long duration) {
            long end=now+duration;
            while(true) { Scheduled next=scheduled.stream().filter(x->x.at<=end).min(Comparator.comparingLong(Scheduled::at)).orElse(null);if(next==null)break;scheduled.remove(next);now=next.at;next.work.run(); }
            now=end;
        }
        void open(LiveTextEditor.Snapshot initial) throws Exception {
            assertTrue(editor.open(empty(),false));assertEquals("textBegin",socket().last().getString("type"));
            socket().ackLive(0,SESSION,0,initial);
            assertEquals(LiveTextEditor.State.ACTIVE,editor.state());assertTrue(editor.imported());
        }
    }
    private static final class Socket implements RemoteSession.Channel {
        final PinnedSocket.Listener listener;final List<JSONObject> sent=new ArrayList<>();
        Socket(PinnedSocket.Listener listener){this.listener=listener;}
        public void connect(){listener.onOpen();} public void close(){listener.onClosed();}
        public boolean send(JSONObject value){sent.add(value);return true;}
        JSONObject last(){return sent.get(sent.size()-1);}
        void ackLive(int index,String session,int revision,LiveTextEditor.Snapshot snapshot)throws Exception{
            JSONObject live=new JSONObject().put("session",session).put("revision",revision).put("text",snapshot.text)
                .put("selectionStart",snapshot.selectionStart).put("selectionLength",snapshot.selectionLength);
            listener.onMessage(ack(index,true).put("liveText",live));
        }
        JSONObject ack(int index,boolean ok)throws Exception{return new JSONObject().put("type","ack").put("id",sent.get(index).getString("id")).put("ok",ok);}
    }
    private static JSONObject hello()throws Exception{
        return ReceiverStatusTest.desktop().put("liveText",new JSONObject().put("version",1))
            .put("textFocus",new JSONObject().put("state","editable").put("revision",1));
    }

    @Test public void capabilitySurvivesHeartbeatButIsNeverInventedForTvOrOldReceiver()throws Exception{
        ReceiverStatus state=ReceiverStatus.fromHello(hello(),false);assertTrue(state.supportsLiveText);
        assertTrue(state.withUpdate(ReceiverStatusTest.desktop()).supportsLiveText);
        assertFalse(state.withUpdate(ReceiverStatusTest.desktop().put("liveText",JSONObject.NULL)).supportsLiveText);
        assertFalse(ReceiverStatus.fromHello(ReceiverStatusTest.desktop(),false).supportsLiveText);
        assertFalse(ReceiverStatus.fromHello(ReceiverStatusTest.tv(true,"ready","ready").put("liveText",new JSONObject().put("version",1)),true).supportsLiveText);
    }
    @Test public void beginImportsCompleteFieldAndSelectionOnlyAfterValidAck()throws Exception{
        Rig rig=new Rig();rig.connect();assertTrue(rig.editor.open(empty(),false));
        assertEquals(LiveTextEditor.State.STARTING,rig.editor.state());assertFalse(rig.editor.imported());assertEquals(0,rig.editor.snapshotVersion());
        LiveTextEditor.Snapshot field=snapshot("你好 🌏 abc",3,2);rig.socket().ackLive(0,SESSION,0,field);
        assertEquals(field,rig.editor.snapshot());assertEquals(1,rig.editor.snapshotVersion());assertTrue(rig.editor.imported());
        assertEquals(2,rig.socket().sent.get(0).length()); // type and fresh id only
    }
    @Test public void explicitDraftAndCompositionCannotBeOverwrittenByBegin()throws Exception{
        Rig rig=new Rig();rig.connect();assertFalse(rig.editor.open(snapshot("unsent draft",12,0),false));
        assertFalse(rig.editor.open(empty(),true));assertTrue(rig.socket().sent.isEmpty());
        assertTrue(rig.editor.restart(snapshot("unsent draft",12,0),false));
        rig.socket().ackLive(0,SESSION,0,snapshot("remote",6,0));assertEquals("remote",rig.editor.snapshot().text);
    }
    @Test public void editsAreAckSerializedAndOnlyLatestDesiredTextIsFlushed()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());
        LiveTextEditor.Snapshot first=snapshot("你",1,0),last=snapshot("你好世界",4,0);
        rig.editor.edit(first,false);rig.editor.edit(snapshot("你好",2,0),false);rig.editor.edit(last,false);
        assertEquals(2,rig.socket().sent.size());assertEquals("textSync",rig.socket().last().getString("type"));assertEquals(1,rig.socket().last().getInt("revision"));
        rig.socket().ackLive(1,SESSION,1,first);
        assertEquals(3,rig.socket().sent.size());assertEquals(last.text,rig.socket().last().getString("text"));assertEquals(2,rig.socket().last().getInt("revision"));
        rig.socket().ackLive(2,SESSION,2,last);assertEquals(LiveTextEditor.State.ACTIVE,rig.editor.state());assertEquals(last,rig.editor.snapshot());
    }
    @Test public void exactAckDoesNotRequestNativeEditorRewrite()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());long importedVersion=rig.editor.snapshotVersion();
        rig.editor.edit(snapshot("first",5,0),false);
        // A newer native edit can be queued by TextWatcher but not published yet.
        // The prior ACK must not request an overwrite of that native editor.
        rig.socket().ackLive(1,SESSION,1,snapshot("first",5,0));
        assertEquals(importedVersion,rig.editor.snapshotVersion());
        rig.editor.edit(snapshot("first second",12,0),false);
        assertEquals("first second",rig.socket().last().getString("text"));
    }
    @Test public void selectionOnlySelectAllAndDeletionUseSameRevisionProtocol()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(snapshot("A😀中文",5,0));
        LiveTextEditor.Snapshot selection=snapshot("A😀中文",0,5);rig.editor.edit(selection,false);
        assertEquals(0,rig.socket().last().getInt("selectionStart"));assertEquals(5,rig.socket().last().getInt("selectionLength"));
        rig.socket().ackLive(1,SESSION,1,selection);rig.editor.edit(empty(),false);
        assertEquals("",rig.socket().last().getString("text"));rig.socket().ackLive(2,SESSION,2,empty());assertEquals(empty(),rig.editor.snapshot());
    }
    @Test public void provisionalImeTextIsNeverSentAndCompositionOnlyFinishFlushes()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());
        rig.editor.edit(snapshot("ni",2,0),true);rig.editor.edit(snapshot("你好",2,0),true);
        assertEquals(1,rig.socket().sent.size());rig.editor.edit(snapshot("你好",2,0),false);
        assertEquals(2,rig.socket().sent.size());assertEquals("你好",rig.socket().last().getString("text"));
        rig.socket().ackLive(1,SESSION,1,snapshot("你好",2,0));assertEquals(LiveTextEditor.State.ACTIVE,rig.editor.state());
    }
    @Test public void ackDuringCompositionCannotReplaceProvisionalTextOrPublishSnapshot()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());long importedVersion=rig.editor.snapshotVersion();
        rig.editor.edit(snapshot("A",1,0),false);rig.editor.edit(snapshot("A ni",4,0),true);
        rig.socket().ackLive(1,SESSION,1,snapshot("A",1,0));
        assertEquals("A ni",rig.editor.snapshot().text);assertEquals(importedVersion,rig.editor.snapshotVersion());assertEquals(2,rig.socket().sent.size());
        rig.editor.edit(snapshot("A 你",3,0),false);assertEquals("A 你",rig.socket().last().getString("text"));assertEquals(2,rig.socket().last().getInt("revision"));
    }
    @Test public void speechPartialCorrectionsReplaceOriginalSelectionAndPreserveSuffix()throws Exception{
        LiveTextEditor.Snapshot base=snapshot("before OLD after",7,3);
        Rig rig=new Rig();rig.connect();rig.open(base);
        LiveTextEditor.Snapshot first=base.replacingSelection("你"),last=base.replacingSelection("你好世界");
        rig.editor.edit(first,false);rig.editor.edit(last,false);rig.socket().ackLive(1,SESSION,1,first);
        assertEquals("before 你好世界 after",rig.socket().last().getString("text"));assertEquals(11,rig.socket().last().getInt("selectionStart"));
    }
    @Test public void unsupportedFieldFallsBackWithoutAppendingAnImportedSnapshot()throws Exception{
        Rig rig=new Rig();rig.connect();assertTrue(rig.editor.open(empty(),false));
        rig.socket().listener.onMessage(rig.socket().ack(0,false).put("error","live_text_unsupported: no stable field"));
        assertEquals(LiveTextEditor.State.UNSUPPORTED,rig.editor.state());assertFalse(rig.editor.imported());
        assertTrue(rig.remote.send(WireActions.text(rig.remote.pairing,rig.remote.status,"manual draft"),null));
        assertEquals("text",rig.socket().last().getString("type"));
    }
    @Test public void protectedOrNonEditableFocusNeverStartsLiveRead()throws Exception{
        for(String focus:new String[]{"protected","other"}){
            Rig rig=new Rig();rig.remote.resume();rig.remote.select(PairingTest.pairing(false),false);
            JSONObject hello=hello();hello.getJSONObject("textFocus").put("state",focus);rig.socket().listener.onMessage(hello);
            assertFalse(rig.editor.open(empty(),false));assertFalse(rig.editor.restart(empty(),false));assertTrue(rig.socket().sent.isEmpty());
        }
    }
    @Test public void focusChangeCancelsQueuedSyncBeforeAnotherFieldCanReceiveIt()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());rig.remote.send(WireActions.ping(),null);
        rig.editor.edit(snapshot("old field",9,0),false);assertEquals(2,rig.socket().sent.size());
        JSONObject update=hello().put("type","ack").put("id",rig.socket().sent.get(1).getString("id")).put("ok",true);
        update.getJSONObject("textFocus").put("revision",2);rig.socket().listener.onMessage(update);
        assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());
        assertTrue(rig.socket().sent.stream().noneMatch(j->"textSync".equals(j.optString("type"))));
        assertFalse(rig.remote.send(WireActions.text(rig.remote.pairing,rig.remote.status,"old field"),null));
    }
    @Test public void disconnectPausesInFlightEditAndNeverReplaysOnReconnect()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());Socket old=rig.socket();
        rig.editor.edit(snapshot("uncertain",9,0),false);old.listener.onFailure(true);
        assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());rig.advance(1000);rig.socket().listener.onMessage(hello());
        assertTrue(rig.socket().sent.isEmpty());old.ackLive(1,SESSION,1,snapshot("uncertain",9,0));
        assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());assertFalse(rig.editor.open(empty(),false));
    }
    @Test public void badRevisionOrCanonicalReplyPausesAndDoesNotReplaceDesiredText()throws Exception{
        for(boolean wrongRevision:new boolean[]{true,false}){
            Rig rig=new Rig();rig.connect();rig.open(empty());rig.editor.edit(snapshot("keep",4,0),false);
            rig.socket().ackLive(1,SESSION,wrongRevision?7:1,snapshot(wrongRevision?"keep":"oops",4,0));
            assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());assertEquals("keep",rig.editor.snapshot().text);
            assertEquals("live_text_uncertain",rig.editor.errorCode());
        }
    }
    @Test public void racedLocalEditDuringBeginIsRetainedAndOldAckIgnored()throws Exception{
        Rig rig=new Rig();rig.connect();rig.editor.open(empty(),false);rig.editor.edit(snapshot("new draft",9,0),false);
        rig.socket().ackLive(0,SESSION,0,snapshot("old remote field",16,0));
        assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());assertEquals("new draft",rig.editor.snapshot().text);assertFalse(rig.editor.imported());
    }
    @Test public void cleanEndClearsEphemeralFieldWhileDirtyEndPauses()throws Exception{
        Rig clean=new Rig();clean.connect();clean.open(snapshot("private remote field",20,0));long version=clean.editor.snapshotVersion();
        assertFalse(clean.remote.send(WireActions.text(clean.remote.pairing,clean.remote.status,"private remote field"),null));
        clean.editor.end();assertNull(clean.editor.snapshot());assertFalse(clean.editor.imported());assertEquals(version+1,clean.editor.snapshotVersion());
        assertEquals("textEnd",clean.socket().last().getString("type"));
        Rig dirty=new Rig();dirty.connect();dirty.open(empty());dirty.editor.edit(snapshot("ni",2,0),true);dirty.editor.end();
        assertEquals(LiveTextEditor.State.PAUSED,dirty.editor.state());assertEquals("ni",dirty.editor.snapshot().text);
    }
    @Test public void switchingDevicesInvalidatesOldSnapshotAndLateAcknowledgements()throws Exception{
        Rig rig=new Rig();rig.connect();rig.editor.open(empty(),false);Socket old=rig.socket();
        rig.remote.select(PairingTest.pairing(false),false);old.ackLive(0,SESSION,0,snapshot("old content",11,0));
        rig.socket().listener.onMessage(hello());assertEquals(LiveTextEditor.State.IDLE,rig.editor.state());assertNull(rig.editor.snapshot());assertFalse(rig.editor.imported());
    }
    @Test public void invalidUnicodeSelectionAndReceiverEscapingBudgetAreRejected()throws Exception{
        assertFalse(snapshot("😀",1,0).valid());assertFalse(snapshot("😀",0,1).valid());assertFalse(snapshot("\ud800",1,0).valid());assertFalse(snapshot("a\0b",3,0).valid());
        assertFalse(snapshot("\ue000".repeat(11000),11000,0).valid());assertTrue(snapshot("你好😀",4,0).valid());
        Rig rig=new Rig();rig.connect();rig.open(empty());rig.editor.edit(snapshot("😀",1,0),false);
        assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());assertTrue(rig.socket().sent.stream().noneMatch(j->"textSync".equals(j.optString("type"))));
    }
    @Test public void enterCannotRaceUnacknowledgedTextButCanFollowItsConfirmedSnapshot()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());LiveTextEditor.Snapshot value=snapshot("ready",5,0);
        rig.editor.edit(value,false);
        assertFalse(rig.remote.send(WireActions.enter(rig.remote.pairing,rig.remote.status),null));
        assertEquals(LiveTextEditor.State.SYNCING,rig.editor.state());assertEquals(2,rig.socket().sent.size());
        rig.socket().ackLive(1,SESSION,1,value);
        assertTrue(rig.remote.send(WireActions.enter(rig.remote.pairing,rig.remote.status),null));
        assertEquals("textEnd",rig.socket().last().getString("type"));
        rig.socket().listener.onMessage(rig.socket().ack(2,true));
        assertEquals("key",rig.socket().last().getString("type"));assertEquals("enter",rig.socket().last().getString("key"));
    }
    @Test public void keysCannotRaceBeginCompositionOrPausedUncertainty()throws Exception{
        Rig rig=new Rig();rig.connect();rig.editor.open(empty(),false);
        assertFalse(rig.remote.send(WireActions.backspace(rig.remote.pairing,rig.remote.status),null));
        rig.socket().ackLive(0,SESSION,0,empty());rig.editor.edit(snapshot("ni",2,0),true);
        assertFalse(rig.remote.send(WireActions.enter(rig.remote.pairing,rig.remote.status),null));
        rig.editor.end();assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());
        assertFalse(rig.remote.send(WireActions.backspace(rig.remote.pairing,rig.remote.status),null));
        assertTrue(rig.remote.send(WireActions.click(rig.remote.pairing,false),null)); // Navigating away remains possible.
    }
    @Test public void queuedKeyboardActionIsDroppedWhenFocusChangesBeforeDispatch()throws Exception{
        Rig rig=new Rig();rig.connect();rig.remote.send(WireActions.ping(),null);
        List<RemoteSession.Result> results=new ArrayList<>();
        assertTrue(rig.remote.send(WireActions.enter(rig.remote.pairing,rig.remote.status),results::add));
        JSONObject update=hello().put("type","ack").put("id",rig.socket().last().getString("id")).put("ok",true);
        update.getJSONObject("textFocus").put("revision",2);rig.socket().listener.onMessage(update);
        assertEquals(List.of(RemoteSession.Result.REJECTED),results);assertEquals(1,rig.socket().sent.size());
    }
    @Test public void timeoutPreservesDesiredTextAndDoesNotResubmitIt()throws Exception{
        Rig rig=new Rig();rig.connect();rig.open(empty());rig.editor.edit(snapshot("unconfirmed",11,0),false);
        rig.advance(4000);assertEquals(LiveTextEditor.State.PAUSED,rig.editor.state());assertEquals("unconfirmed",rig.editor.snapshot().text);
        rig.advance(1000);rig.socket().listener.onMessage(hello());assertTrue(rig.socket().sent.isEmpty());
    }
}
