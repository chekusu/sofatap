package com.chekusu.sofatap.controller;
import org.json.JSONObject;
import org.junit.Test;
import static org.junit.Assert.*;
import static com.chekusu.sofatap.controller.GestureConfiguration.*;
public class GestureConfigurationTest {
    @Test public void computerPresetsMatchIosBindings(){
        var standard=new GestureConfiguration(Target.computer);
        assertEquals(Action.doubleRightClick,standard.action(Gesture.rightDoubleTap));assertEquals(Action.none,standard.action(Gesture.twoFingerTap));assertEquals(Action.drag,standard.action(Gesture.doubleTapHold));
        var trackpad=new GestureConfiguration(Preset.trackpad,Target.computer);assertEquals(Action.doubleLeftClick,trackpad.action(Gesture.rightDoubleTap));assertEquals(Action.rightClick,trackpad.action(Gesture.twoFingerTap));
        var press=new GestureConfiguration(Preset.pressMenu,Target.computer);assertEquals(Action.rightClick,press.action(Gesture.longPress));assertEquals(Action.confirm,press.action(Gesture.twoFingerTap));assertEquals(Action.toggleKeyboard,press.action(Gesture.threeFingerTap));
    }
    @Test public void televisionPresetsHaveNoDesktopOnlyActions(){for(Preset preset:Preset.values()){
        var config=new GestureConfiguration(preset,Target.television);for(Gesture gesture:Gesture.values())assertTrue(allowedActions(gesture,Target.television).contains(config.action(gesture)));
        assertEquals(Action.none,config.action(Gesture.doubleTapHold));assertEquals(Action.none,config.action(Gesture.leftDoubleTap));
    }assertEquals(Action.home,new GestureConfiguration(Preset.pressMenu,Target.television).action(Gesture.threeFingerTap));}
    @Test public void invalidMappingsAreDisabledAndCannotTurnMotionIntoClicks(){
        var config=new GestureConfiguration(Target.computer).withAction(Gesture.oneFingerMove,Action.leftClick).withAction(Gesture.singleTap,Action.drag);
        assertEquals(Action.none,config.action(Gesture.oneFingerMove));assertEquals(Action.none,config.action(Gesture.singleTap));
        var tv=config.forTarget(Target.television);assertEquals(Action.none,tv.action(Gesture.rightDoubleTap));assertEquals(Action.none,tv.action(Gesture.longPress));
    }
    @Test public void malformedBindingsDisableAllWhileUnknownActionsDisableOnlyThatGesture()throws Exception{
        var broken=GestureConfiguration.fromJson(new JSONObject("{\"bindings\":[]}"),Target.computer);for(Gesture gesture:Gesture.values())assertEquals(Action.none,broken.action(gesture));
        var unknown=GestureConfiguration.fromJson(new JSONObject("{\"bindings\":{\"singleTap\":\"newAction\",\"newGesture\":\"leftClick\"}}"),Target.computer);
        assertEquals(Action.none,unknown.action(Gesture.singleTap));assertEquals(Action.drag,unknown.action(Gesture.longPress));
    }
    @Test public void timingClampsAndMalformedTypesUseDefaults()throws Exception{
        var low=GestureConfiguration.fromJson(new JSONObject("{\"holdDuration\":-1,\"doubleTapInterval\":8,\"naturalScrolling\":false}"),Target.computer);
        assertEquals(200,low.holdDurationMs);assertEquals(500,low.doubleTapIntervalMs);assertFalse(low.naturalScrolling);
        var wrong=GestureConfiguration.fromJson(new JSONObject("{\"holdDuration\":\"1\",\"doubleTapInterval\":null,\"naturalScrolling\":\"false\"}"),Target.computer);
        assertEquals(300,wrong.holdDurationMs);assertEquals(280,wrong.doubleTapIntervalMs);assertTrue(wrong.naturalScrolling);
    }
    @Test public void roundTripAndPresetEqualityAreStable(){for(Target target:Target.values())for(Preset preset:Preset.values()){
        var config=new GestureConfiguration(preset,target);assertEquals(config,GestureConfiguration.fromJson(config.toJson(),target));assertEquals(preset,config.matchingPreset());
        assertNull(config.withTiming(750,310).matchingPreset());
    }}
    @Test public void unsupportedCapabilitiesNeverDeleteConfiguredMapping()throws Exception{
        var config=new GestureConfiguration(Preset.trackpad,Target.computer);
        ReceiverStatus status=ReceiverStatus.fromHello(new JSONObject("{\"type\":\"hello\",\"version\":1,\"name\":\"Locked\",\"platform\":\"windows\",\"inputAvailable\":false,\"inputStatus\":\"screen_locked\",\"dryRun\":false}"),false);
        assertFalse(availableActions(status,Target.computer).contains(Action.rightClick));assertTrue(availableActions(status,Target.computer).contains(Action.toggleKeyboard));assertEquals(Action.rightClick,config.action(Gesture.twoFingerTap));
    }
}
