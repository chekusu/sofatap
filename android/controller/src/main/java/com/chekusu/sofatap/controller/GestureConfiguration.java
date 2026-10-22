package com.chekusu.sofatap.controller;

import org.json.JSONObject;
import java.util.EnumMap;
import java.util.EnumSet;
import java.util.List;
import java.util.Set;

/** Local input preferences. Receiver capability checks remain mandatory at dispatch. */
public final class GestureConfiguration {
    public enum Gesture { singleTap,leftDoubleTap,rightDoubleTap,twoFingerTap,threeFingerTap,longPress,doubleTapHold,oneFingerMove,twoFingerMove }
    public enum Action { none,leftClick,rightClick,doubleLeftClick,doubleRightClick,drag,movePointer,scroll,confirm,back,home,toggleKeyboard,toggleDictation }
    public enum Target { computer,television }
    public enum Preset { sofatap,trackpad,pressMenu }
    public final Target target;
    public final int holdDurationMs,doubleTapIntervalMs;
    public final boolean naturalScrolling;
    private final EnumMap<Gesture,Action> bindings;

    public GestureConfiguration(Target target) { this(Preset.sofatap,target); }
    public GestureConfiguration(Preset preset,Target target) {
        this.target=target;holdDurationMs=300;doubleTapIntervalMs=280;naturalScrolling=true;
        bindings=new EnumMap<>(Gesture.class);
        for(Gesture gesture:Gesture.values())bindings.put(gesture,Action.none);
        bindings.put(Gesture.singleTap,Action.leftClick);
        bindings.put(Gesture.oneFingerMove,Action.movePointer);
        bindings.put(Gesture.twoFingerMove,Action.scroll);
        if(target==Target.computer) {
            bindings.put(Gesture.leftDoubleTap,Action.doubleLeftClick);
            bindings.put(Gesture.rightDoubleTap,preset==Preset.sofatap?Action.doubleRightClick:Action.doubleLeftClick);
            bindings.put(Gesture.longPress,preset==Preset.pressMenu?Action.rightClick:Action.drag);
            bindings.put(Gesture.doubleTapHold,Action.drag);
            if(preset==Preset.trackpad)bindings.put(Gesture.twoFingerTap,Action.rightClick);
            if(preset==Preset.pressMenu){bindings.put(Gesture.twoFingerTap,Action.confirm);bindings.put(Gesture.threeFingerTap,Action.toggleKeyboard);}
        } else if(preset!=Preset.sofatap) {
            bindings.put(Gesture.twoFingerTap,Action.confirm);bindings.put(Gesture.longPress,Action.back);
            if(preset==Preset.pressMenu)bindings.put(Gesture.threeFingerTap,Action.home);
        }
    }
    private GestureConfiguration(Target target,EnumMap<Gesture,Action> values,int hold,int interval,boolean natural) {
        this.target=target;bindings=new EnumMap<>(Gesture.class);
        for(Gesture gesture:Gesture.values()) {
            Action action=values.getOrDefault(gesture,Action.none);
            bindings.put(gesture,allowedActions(gesture,target).contains(action)?action:Action.none);
        }
        holdDurationMs=Math.max(200,Math.min(1200,hold));doubleTapIntervalMs=Math.max(150,Math.min(500,interval));naturalScrolling=natural;
    }
    public Action action(Gesture gesture){return bindings.get(gesture);}
    public GestureConfiguration withAction(Gesture gesture,Action action){EnumMap<Gesture,Action> copy=new EnumMap<>(bindings);copy.put(gesture,action==null?Action.none:action);return new GestureConfiguration(target,copy,holdDurationMs,doubleTapIntervalMs,naturalScrolling);}
    public GestureConfiguration withTiming(int holdMs,int intervalMs){return new GestureConfiguration(target,bindings,holdMs,intervalMs,naturalScrolling);}
    public GestureConfiguration withNaturalScrolling(boolean natural){return new GestureConfiguration(target,bindings,holdDurationMs,doubleTapIntervalMs,natural);}
    public GestureConfiguration forTarget(Target next){return new GestureConfiguration(next,bindings,holdDurationMs,doubleTapIntervalMs,naturalScrolling);}
    public Preset matchingPreset(){for(Preset preset:Preset.values())if(equals(new GestureConfiguration(preset,target)))return preset;return null;}
    public static List<Action> allowedActions(Gesture gesture,Target target) {
        if(gesture==Gesture.oneFingerMove||gesture==Gesture.twoFingerMove)return List.of(Action.none,Action.movePointer,Action.scroll);
        if(target==Target.television)return List.of(Action.none,Action.leftClick,Action.confirm,Action.back,Action.home);
        if(gesture==Gesture.longPress||gesture==Gesture.doubleTapHold)return List.of(Action.none,Action.leftClick,Action.rightClick,Action.doubleLeftClick,Action.doubleRightClick,Action.drag,Action.confirm,Action.back,Action.toggleKeyboard,Action.toggleDictation);
        return List.of(Action.none,Action.leftClick,Action.rightClick,Action.doubleLeftClick,Action.doubleRightClick,Action.confirm,Action.back,Action.toggleKeyboard,Action.toggleDictation);
    }
    public static Set<Action> availableActions(ReceiverStatus status,Target target) {
        EnumSet<Action> result=EnumSet.of(Action.none);
        if(target==Target.computer){result.add(Action.toggleKeyboard);result.add(Action.toggleDictation);}
        if(status==null)return result;
        if(status.canMove)result.add(Action.movePointer);if(status.canScroll)result.add(Action.scroll);
        if(status.canClick){result.add(Action.leftClick);if(target==Target.computer)result.add(Action.doubleLeftClick);}
        if(target==Target.computer&&status.canRightClick){result.add(Action.rightClick);result.add(Action.doubleRightClick);}
        if(target==Target.computer&&status.canDrag)result.add(Action.drag);
        if(target==Target.computer?status.canText:status.canNavigate)result.add(Action.confirm);
        if(status.canBack)result.add(Action.back);if(target==Target.television&&status.canHome)result.add(Action.home);
        return result;
    }
    public JSONObject toJson() {
        try {
            JSONObject values=new JSONObject();for(Gesture gesture:Gesture.values())values.put(gesture.name(),action(gesture).name());
            return new JSONObject().put("target",target.name()).put("bindings",values).put("holdDuration",holdDurationMs/1000d).put("doubleTapInterval",doubleTapIntervalMs/1000d).put("naturalScrolling",naturalScrolling);
        } catch(Exception error){throw new IllegalStateException(error);}
    }
    public static GestureConfiguration fromJson(JSONObject value,Target target) {
        GestureConfiguration defaults=new GestureConfiguration(target);
        if(value==null)return defaults;
        EnumMap<Gesture,Action> values=new EnumMap<>(defaults.bindings);
        if(value.has("bindings")) {
            if(value.opt("bindings") instanceof JSONObject bindings) {
                for(Gesture gesture:Gesture.values())if(bindings.has(gesture.name())) {
                    Object raw=bindings.opt(gesture.name());Action action=Action.none;
                    if(raw instanceof String name)try{action=Action.valueOf(name);}catch(IllegalArgumentException ignored){}
                    values.put(gesture,action);
                }
            } else for(Gesture gesture:Gesture.values())values.put(gesture,Action.none);
        }
        int hold=milliseconds(value.opt("holdDuration"),300,200,1200), interval=milliseconds(value.opt("doubleTapInterval"),280,150,500);
        boolean natural=!(value.opt("naturalScrolling") instanceof Boolean b)||b;
        return new GestureConfiguration(target,values,hold,interval,natural);
    }
    private static int milliseconds(Object value,int fallback,int minimum,int maximum) {
        if(!(value instanceof Number number)||!Double.isFinite(number.doubleValue()))return fallback;
        return (int)Math.round(Math.max(minimum,Math.min(maximum,number.doubleValue()*1000)));
    }
    @Override public boolean equals(Object other){return other instanceof GestureConfiguration c&&target==c.target&&holdDurationMs==c.holdDurationMs&&doubleTapIntervalMs==c.doubleTapIntervalMs&&naturalScrolling==c.naturalScrolling&&bindings.equals(c.bindings);}
    @Override public int hashCode(){return java.util.Objects.hash(target,bindings,holdDurationMs,doubleTapIntervalMs,naturalScrolling);}
}
