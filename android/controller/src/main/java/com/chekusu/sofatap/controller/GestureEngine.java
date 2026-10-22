package com.chekusu.sofatap.controller;

import java.util.LinkedHashMap;
import java.util.Map;
import static com.chekusu.sofatap.controller.GestureConfiguration.*;

/** Touch recognition in dp and monotonic milliseconds, without Android dependencies. */
public final class GestureEngine {
    public interface Listener {
        void move(double dx,double dy);
        void scroll(double dx,double dy);
        void click(boolean right,int count);
        void drag(boolean down);
        void navigate(String direction);
        void back();
        default void shortcut(Action action){if(action==Action.back)back();else if(action==Action.confirm)navigate("confirm");else if(action==Action.home)navigate("home");}
    }
    public static final long LONG_PRESS_MS=300,DOUBLE_TAP_MS=280,TV_REPEAT_MS=150;
    public static final double EDGE_WIDTH=26;
    private static final double SLOP=7,DOUBLE_TAP_DISTANCE=32,TV_STEP=32;
    private static final long MOTION_INTERVAL_MS=16,MULTI_TAP_MS=250;
    private static final class Contact {
        final double startX,startY;double x,y;
        Contact(double x,double y){startX=this.x=x;startY=this.y=y;}
    }
    private final Listener listener;
    private final Map<Integer,Contact> contacts=new LinkedHashMap<>();
    private GestureConfiguration configuration=new GestureConfiguration(Target.computer);
    private boolean tvMode,tvPointerMode,edge,moved,dragging,suppressed,secondTap,multiMoved,multiEligible,lifted,holdFired,tapRight,tapRegionValid;
    private int peakContacts;
    private double width,startX,startY,previousX,previousY,tvAnchorX,tvAnchorY;
    private long startedAt,lastNavigationAt=Long.MIN_VALUE,lastMotionAt;
    private double queuedMoveX,queuedMoveY,queuedScrollX,queuedScrollY;
    private boolean pendingTap,pendingRightHalf;
    private double pendingX,pendingY;
    private long pendingAt;
    public GestureEngine(Listener listener){this.listener=listener;}
    public void setTvMode(boolean enabled){if(tvMode==enabled)return;cancel();tvMode=enabled;configuration=new GestureConfiguration(enabled?Target.television:Target.computer);}
    public void setTvPointerMode(boolean enabled){if(tvPointerMode==enabled)return;cancel();tvPointerMode=enabled;}
    public void setConfiguration(GestureConfiguration value){GestureConfiguration next=value.forTarget(tvMode?Target.television:Target.computer);if(!configuration.equals(next)){cancel();configuration=next;}}
    public GestureConfiguration configuration(){return configuration;}
    public void accessibilityClick(){cancel();if(directionalTv())listener.navigate("confirm");else discrete(configuration.action(Gesture.singleTap));}
    private boolean directionalTv(){return tvMode&&!tvPointerMode;}
    public boolean isDragging(){return dragging;}
    public boolean isEdgeScrolling(){return !contacts.isEmpty()&&edge&&moved&&!suppressed;}
    private double movementTolerance(){return !tvMode&&configuration.action(Gesture.oneFingerMove)==Action.movePointer?3:SLOP;}

    public void down(int pointerId,double x,double y,double surfaceWidth,long now) {
        if(!valid(x,y)||!Double.isFinite(surfaceWidth)||surfaceWidth<=0||contacts.containsKey(pointerId)){cancel();return;}
        if(contacts.isEmpty()) {
            tick(now);width=surfaceWidth;tapRight=x>=width/2;tapRegionValid=true;
            secondTap=!directionalTv()&&pendingTap&&now-pendingAt<configuration.doubleTapIntervalMs
                &&Math.hypot(x-pendingX,y-pendingY)<=DOUBLE_TAP_DISTANCE&&tapRight==pendingRightHalf&&defersSingle(tapRight);
            if(secondTap)pendingTap=false;else flushTap();
            startX=previousX=tvAnchorX=x;startY=previousY=tvAnchorY=y;
            startedAt=lastMotionAt=now;lastNavigationAt=Long.MIN_VALUE;
            edge=!tvMode&&x>=width-EDGE_WIDTH;
            moved=suppressed=multiMoved=lifted=holdFired=false;multiEligible=true;peakContacts=1;
        } else {
            flushMotion();pendingTap=false;secondTap=false;
            multiEligible&=!moved&&!holdFired&&!dragging&&!lifted&&now-startedAt<=MULTI_TAP_MS;
            releaseDrag();
            if(edge||contacts.size()>=3||lifted)suppressed=true;
            multiMoved|=moved;peakContacts=Math.max(peakContacts,contacts.size()+1);
        }
        contacts.put(pointerId,new Contact(x,y));previousX=centroidX();previousY=centroidY();
    }
    /** Coordinates include all active IDs, including before the lifted contact is removed. */
    public void move(int[] ids,double[] xs,double[] ys,long now) {
        if(contacts.isEmpty())return;
        if(ids.length!=contacts.size()||ids.length!=xs.length||ids.length!=ys.length){cancel();return;}
        java.util.HashSet<Integer> seen=new java.util.HashSet<>();
        for(int i=0;i<ids.length;i++) {
            Contact contact=contacts.get(ids[i]);
            if(contact==null||!seen.add(ids[i])||!valid(xs[i],ys[i])){cancel();return;}
            contact.x=xs[i];contact.y=ys[i];
            if(Math.hypot(contact.x-contact.startX,contact.y-contact.startY)>SLOP)multiMoved=true;
        }
        double x=centroidX(),y=centroidY();
        if(suppressed||lifted){previousX=x;previousY=y;return;}
        if(peakContacts>1) {
            if(contacts.size()==2&&!directionalTv()&&multiMoved){moved=true;motion(configuration.action(Gesture.twoFingerMove),x-previousX,y-previousY,now);}
            previousX=x;previousY=y;return;
        }
        if((x>=width/2)!=tapRight)tapRegionValid=false;
        double distance=Math.hypot(x-startX,y-startY);
        if(!moved&&!dragging&&distance<=(edge?3:movementTolerance())){tick(now);return;}
        moved=true;flushTap();secondTap=false;
        if(directionalTv()) {
            double dx=x-tvAnchorX,dy=y-tvAnchorY;
            if(Math.max(Math.abs(dx),Math.abs(dy))>=TV_STEP&&(lastNavigationAt==Long.MIN_VALUE||now-lastNavigationAt>=TV_REPEAT_MS)) {
                listener.navigate(Math.abs(dx)>Math.abs(dy)?(dx>0?"right":"left"):(dy>0?"down":"up"));
                lastNavigationAt=now;tvAnchorX=x;tvAnchorY=y;
            }
        } else if(edge)queueScroll(0,-(y-previousY),now);
        else if(dragging)queueMove(x-previousX,y-previousY,now);
        else motion(configuration.action(Gesture.oneFingerMove),x-previousX,y-previousY,now);
        previousX=x;previousY=y;
    }
    public void up(int pointerId,double x,double y,long now) {
        Contact contact=contacts.get(pointerId);if(contact==null||!valid(x,y)){cancel();return;}
        int[] ids=new int[contacts.size()];double[] xs=new double[ids.length],ys=new double[ids.length];int i=0;
        for(Map.Entry<Integer,Contact> item:contacts.entrySet()) {
            ids[i]=item.getKey();xs[i]=ids[i]==pointerId?x:item.getValue().x;ys[i]=ids[i]==pointerId?y:item.getValue().y;i++;
        }
        move(ids,xs,ys,now);if(!contacts.containsKey(pointerId))return;
        contacts.remove(pointerId);
        if(!contacts.isEmpty()){lifted=true;previousX=centroidX();previousY=centroidY();return;}
        flushMotion();boolean wasDragging=dragging;releaseDrag();
        if(!suppressed&&!wasDragging&&!moved&&!multiMoved) {
            if(peakContacts>1&&multiEligible&&now-startedAt<=MULTI_TAP_MS) {
                if(directionalTv()){if(peakContacts==2)listener.back();}
                else if(peakContacts==2||peakContacts==3)discrete(configuration.action(peakContacts==2?Gesture.twoFingerTap:Gesture.threeFingerTap));
            } else if(peakContacts==1&&!edge&&!holdFired) {
                if(directionalTv()){if(now-startedAt<LONG_PRESS_MS)listener.navigate("confirm");}
                else if(secondTap) {
                    Action action=tapRegionValid?configuration.action(tapRight?Gesture.rightDoubleTap:Gesture.leftDoubleTap):Action.none;
                    if(action==Action.none){discrete(configuration.action(Gesture.singleTap));discrete(configuration.action(Gesture.singleTap));}
                    else discrete(action);
                } else if(defersSingle(tapRight)) {
                    pendingTap=true;pendingX=x;pendingY=y;pendingAt=now;pendingRightHalf=tapRight;
                } else discrete(configuration.action(Gesture.singleTap));
            }
        }
        secondTap=false;
    }
    public void tick(long now) {
        if(pendingTap&&now-pendingAt>=configuration.doubleTapIntervalMs)flushTap();
        if(!directionalTv()&&contacts.size()==1&&peakContacts==1&&!edge&&!suppressed&&!lifted&&!moved&&!holdFired&&now-startedAt>=configuration.holdDurationMs) {
            pendingTap=false;holdFired=true;
            Action action=configuration.action(secondTap?Gesture.doubleTapHold:Gesture.longPress);secondTap=false;
            if(action==Action.drag){dragging=true;listener.drag(true);}else discrete(action);
        }
        flushIfDue(now);
    }
    /** Configuration, target, interruption and dismissal drop deferred actions and release drag. */
    public void cancel(){contacts.clear();queuedMoveX=queuedMoveY=queuedScrollX=queuedScrollY=0;pendingTap=secondTap=false;suppressed=moved=multiMoved=edge=lifted=holdFired=false;peakContacts=0;lastNavigationAt=Long.MIN_VALUE;releaseDrag();}
    private boolean defersSingle(boolean right){return configuration.action(right?Gesture.rightDoubleTap:Gesture.leftDoubleTap)!=Action.none||configuration.action(Gesture.doubleTapHold)!=Action.none;}
    private void discrete(Action action) {
        switch(action) {
            case leftClick->listener.click(false,1);case rightClick->listener.click(true,1);
            case doubleLeftClick->listener.click(false,2);case doubleRightClick->listener.click(true,2);
            case confirm,back,home,toggleKeyboard,toggleDictation->listener.shortcut(action);
            default->{}
        }
    }
    private void motion(Action action,double dx,double dy,long now){if(action==Action.movePointer)queueMove(dx,dy,now);else if(action==Action.scroll)queueScroll(dx*(configuration.naturalScrolling?1:-1),dy*(configuration.naturalScrolling?1:-1),now);}
    private void releaseDrag(){if(dragging){dragging=false;listener.drag(false);}}
    private void queueMove(double dx,double dy,long now){queuedMoveX=bounded(queuedMoveX+dx,240);queuedMoveY=bounded(queuedMoveY+dy,240);flushIfDue(now);}
    private void queueScroll(double dx,double dy,long now){queuedScrollX=bounded(queuedScrollX+dx,120);queuedScrollY=bounded(queuedScrollY+dy,120);flushIfDue(now);}
    private void flushIfDue(long now){if(now-lastMotionAt>=MOTION_INTERVAL_MS){flushMotion();lastMotionAt=now;}}
    private void flushMotion(){double mx=queuedMoveX,my=queuedMoveY,sx=queuedScrollX,sy=queuedScrollY;queuedMoveX=queuedMoveY=queuedScrollX=queuedScrollY=0;if(mx!=0||my!=0)listener.move(mx,my);if(sx!=0||sy!=0)listener.scroll(sx,sy);}
    private void flushTap(){if(pendingTap){pendingTap=false;discrete(configuration.action(Gesture.singleTap));}}
    private double centroidX(){double total=0;for(Contact contact:contacts.values())total+=contact.x;return total/contacts.size();}
    private double centroidY(){double total=0;for(Contact contact:contacts.values())total+=contact.y;return total/contacts.size();}
    private static boolean valid(double x,double y){return Double.isFinite(x)&&Double.isFinite(y);}
    private static double bounded(double value,double limit){return Math.max(-limit,Math.min(limit,value));}
}
