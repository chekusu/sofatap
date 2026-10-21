package com.chekusu.sofatap.controller;

import org.junit.Test;
import java.util.ArrayList;
import java.util.List;
import static org.junit.Assert.*;

public class GestureEngineTest {
    private static final class Recording implements GestureEngine.Listener {
        final List<String> actions = new ArrayList<>();
        final List<double[]> moves = new ArrayList<>(), scrolls = new ArrayList<>();
        @Override public void move(double x, double y) { moves.add(new double[]{x, y}); actions.add("move"); }
        @Override public void scroll(double x, double y) { scrolls.add(new double[]{x, y}); actions.add("scroll"); }
        @Override public void click(boolean right, int count) { actions.add((right ? "right:" : "left:") + count); }
        @Override public void drag(boolean down) { actions.add("drag:" + down); }
        @Override public void navigate(String direction) { actions.add(direction); }
        @Override public void back() { actions.add("back"); }
        @Override public void shortcut(GestureConfiguration.Action action) { actions.add("shortcut:"+action); }
    }

    private final Recording listener = new Recording();
    private final GestureEngine engine = new GestureEngine(listener);
    private void down(int id, double x, double y, long now) { engine.down(id, x, y, 360, now); }
    private void move(int id, double x, double y, long now) {
        engine.move(new int[]{id}, new double[]{x}, new double[]{y}, now);
    }
    private void tap(int id, double x, long start) { down(id, x, 80, start); engine.up(id, x, 80, start + 40); }

    @Test public void singleTapWaitsForDoubleTapDeadlineThenFiresOnce() {
        tap(3, 50, 0);
        engine.tick(319);
        assertTrue(listener.actions.isEmpty());
        engine.tick(320);
        engine.tick(600);
        assertEquals(List.of("left:1"), listener.actions);
    }

    @Test public void leftHalfDoubleTapIsOneDoubleClickWithoutExtraSingle() {
        tap(3, 50, 0);
        tap(8, 52, 150);
        engine.tick(1000);
        assertEquals(List.of("left:2"), listener.actions);
    }

    @Test public void rightHalfDoubleTapDoesNotActivateLeftClickFirst() {
        tap(10, 280, 0);
        tap(31, 281, 150);
        engine.tick(1000);
        assertEquals(List.of("right:2"), listener.actions);
    }

    @Test public void doubleTapCannotCrossInvisibleHalvesOrLongDistance() {
        tap(1, 178, 0);
        tap(1, 181, 150);
        engine.tick(500);
        assertEquals(List.of("left:1", "left:1"), listener.actions);
        listener.actions.clear();
        tap(1, 40, 600);
        tap(1, 100, 750);
        engine.tick(1100);
        assertEquals(List.of("left:1", "left:1"), listener.actions);
    }

    @Test public void holdBeginsAt300msAndCancelReleasesExactlyOnce() {
        down(99, 50, 70, 100);
        engine.tick(399);
        assertTrue(listener.actions.isEmpty());
        engine.tick(400);
        assertTrue(engine.isDragging());
        engine.cancel();
        engine.cancel();
        engine.tick(1000);
        assertEquals(List.of("drag:true", "drag:false"), listener.actions);
    }

    @Test public void holdDragMovesAndReleasesWithoutClick() {
        down(1, 100, 100, 0);
        engine.tick(300);
        move(1, 130, 120, 350);
        engine.up(1, 130, 120, 400);
        engine.tick(900);
        assertEquals(List.of("drag:true", "move", "drag:false"), listener.actions);
        assertArrayEquals(new double[]{30, 20}, listener.moves.get(0), .001);
    }

    @Test public void movingBeyondSlopCancelsHoldAndTap() {
        down(1, 50, 70, 0);
        move(1, 52, 72, 100);
        assertTrue(listener.moves.isEmpty());
        move(1, 70, 70, 150);
        engine.tick(500);
        engine.up(1, 70, 70, 600);
        assertEquals(List.of("move"), listener.actions);
        assertArrayEquals(new double[]{20, 0}, listener.moves.get(0), .001);
    }

    @Test public void finalUpPositionCanNeverTurnASwipeIntoATap() {
        down(1, 100, 100, 0);
        engine.up(1, 150, 110, 100);
        engine.tick(1000);
        assertEquals(List.of("move"), listener.actions);
    }

    @Test public void pointerIdsAndArrayReorderingPreserveNaturalScrolling() {
        down(11, 80, 100, 0);
        down(42, 120, 100, 20);
        engine.move(new int[]{42, 11}, new double[]{120, 80}, new double[]{130, 130}, 60);
        assertEquals(1, listener.scrolls.size());
        assertArrayEquals(new double[]{0, 30}, listener.scrolls.get(0), .001);
        engine.up(11, 80, 130, 90);
        move(42, 200, 200, 120);
        engine.up(42, 200, 200, 140);
        engine.tick(1000);
        assertEquals(List.of("scroll"), listener.actions);
    }

    @Test public void twoFingerTapIsRightClickWithNoTrailingSingle() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Preset.trackpad,GestureConfiguration.Target.computer));
        down(5, 50, 100, 0);
        down(7, 100, 100, 10);
        engine.up(7, 100, 100, 80);
        engine.up(5, 50, 100, 100);
        engine.tick(1000);
        assertEquals(List.of("right:1"), listener.actions);
    }

    @Test public void thirdFingerSuppressesUntilAllAreLifted() {
        down(1, 30, 100, 0);
        down(2, 80, 100, 10);
        down(3, 130, 100, 20);
        engine.up(3, 130, 100, 30);
        engine.up(2, 80, 100, 40);
        engine.up(1, 30, 100, 50);
        engine.tick(1000);
        assertTrue(listener.actions.isEmpty());
    }

    @Test public void edgeScrollOpposesNaturalScrollAndCannotTapOrHold() {
        down(1, 349, 100, 0);
        engine.tick(350);
        assertTrue(listener.actions.isEmpty());
        move(1, 349, 130, 400);
        assertTrue(engine.isEdgeScrolling());
        engine.up(1, 349, 130, 450);
        engine.tick(1000);
        assertEquals(List.of("scroll"), listener.actions);
        assertArrayEquals(new double[]{0, -30}, listener.scrolls.get(0), .001);
    }

    @Test public void addingFingerToEdgeScrollSuppressesRemainingGesture() {
        down(1, 349, 100, 0);
        down(2, 300, 100, 10);
        engine.up(2, 300, 100, 20);
        move(1, 349, 180, 50);
        engine.up(1, 349, 180, 60);
        engine.tick(1000);
        assertTrue(listener.actions.isEmpty());
    }

    @Test public void scrollFloodIsCoalescedBoundedAndHasNoTailAfterCancel() {
        down(1, 349, 100, 0);
        for (int t = 1; t <= 15; t++) move(1, 349, 100 + 100 * t, t);
        assertTrue(listener.scrolls.isEmpty());
        engine.tick(16);
        assertEquals(1, listener.scrolls.size());
        assertArrayEquals(new double[]{0, -120}, listener.scrolls.get(0), .001);
        move(1, 349, 1800, 20);
        engine.cancel();
        engine.tick(100);
        assertEquals(1, listener.scrolls.size());
    }

    @Test public void modeChangeCancelsDeferredTapAndReleasesDrag() {
        tap(1, 50, 0);
        engine.setTvMode(true);
        engine.tick(1000);
        assertTrue(listener.actions.isEmpty());
        engine.setTvMode(false);
        down(1, 50, 100, 1100);
        engine.tick(1400);
        engine.setTvMode(true);
        assertEquals(List.of("drag:true", "drag:false"), listener.actions);
    }

    @Test public void tvTapsConfirmAndTwoFingerTapGoesBackWithoutDesktopCommands() {
        engine.setTvMode(true);
        tap(1, 50, 0);
        down(2, 40, 100, 200);
        down(9, 80, 100, 210);
        engine.up(2, 40, 100, 240);
        engine.up(9, 80, 100, 250);
        engine.tick(1000);
        assertEquals(List.of("confirm", "back"), listener.actions);
    }

    @Test public void tvSwipeRequires32dpAndRateLimitsWithoutQueuingSteps() {
        engine.setTvMode(true);
        down(1, 100, 100, 0);
        move(1, 131, 100, 20);
        assertTrue(listener.actions.isEmpty());
        move(1, 132, 100, 40);
        move(1, 200, 100, 60);
        move(1, 260, 100, 80);
        assertEquals(List.of("right"), listener.actions);
        move(1, 270, 100, 190);
        engine.up(1, 270, 100, 200);
        engine.tick(1000);
        assertEquals(List.of("right", "right"), listener.actions);
    }

    @Test public void tvLongPressAndTwoFingerScrollNeverEmitMouseEvents() {
        engine.setTvMode(true);
        down(1, 50, 100, 0);
        engine.tick(500);
        engine.up(1, 50, 100, 600);
        down(2, 50, 100, 800);
        down(3, 80, 100, 810);
        engine.move(new int[]{3, 2}, new double[]{80, 50}, new double[]{180, 180}, 850);
        engine.up(3, 80, 180, 880);
        engine.up(2, 50, 180, 890);
        assertTrue(listener.actions.isEmpty());
    }

    @Test public void separateTvSwipesDoNotInheritThePreviousGestureThrottle() {
        engine.setTvMode(true);
        down(1, 100, 100, 0);
        move(1, 140, 100, 40);
        engine.up(1, 140, 100, 60);
        down(2, 100, 100, 80);
        move(2, 60, 100, 100);
        engine.up(2, 60, 100, 120);
        assertEquals(List.of("right", "left"), listener.actions);
    }

    @Test public void malformedSampleCancelsDragRatherThanLeavingButtonHeld() {
        down(1, 50, 100, 0);
        engine.tick(300);
        move(8, 70, 100, 400);
        engine.up(1, 50, 100, 450);
        assertEquals(List.of("drag:true", "drag:false"), listener.actions);
    }

    @Test public void nonFiniteSampleCancelsWithoutSendingMovement() {
        down(1, 50, 100, 0);
        move(1, Double.NaN, 100, 50);
        engine.up(1, 50, 100, 100);
        engine.tick(1000);
        assertTrue(listener.actions.isEmpty());
    }
    @Test public void mappingsChangeDiscreteActionsAndDisabledDoublePreservesTwoSingles() {
        var config=new GestureConfiguration(GestureConfiguration.Target.computer)
            .withAction(GestureConfiguration.Gesture.singleTap,GestureConfiguration.Action.rightClick)
            .withAction(GestureConfiguration.Gesture.leftDoubleTap,GestureConfiguration.Action.none)
            .withAction(GestureConfiguration.Gesture.doubleTapHold,GestureConfiguration.Action.none);
        engine.setConfiguration(config);tap(1,50,0);tap(1,50,100);engine.tick(1000);
        assertEquals(List.of("right:1","right:1"),listener.actions);
    }
    @Test public void disabledDoubleWithHoldReservedStillProducesTwoSingles() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Target.computer)
            .withAction(GestureConfiguration.Gesture.leftDoubleTap,GestureConfiguration.Action.none));
        tap(1,50,0);tap(1,50,100);engine.tick(1000);
        assertEquals(List.of("left:1","left:1"),listener.actions);
    }
    @Test public void holdTimingAndDoubleTapHoldAreIndependent() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Preset.pressMenu,GestureConfiguration.Target.computer).withTiming(650,400));
        down(1,50,80,0);engine.tick(649);assertTrue(listener.actions.isEmpty());engine.tick(650);
        engine.up(1,50,80,700);assertEquals(List.of("right:1"),listener.actions);
        listener.actions.clear();tap(1,50,800);down(1,50,80,1000);engine.tick(1649);assertTrue(listener.actions.isEmpty());engine.tick(1650);
        move(1,70,80,1700);engine.up(1,70,80,1750);
        assertEquals(List.of("drag:true","move","drag:false"),listener.actions);
    }
    @Test public void thirdFingerTapUsesConfiguredShortcutAndFourFingersStaySuppressed() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Preset.pressMenu,GestureConfiguration.Target.computer));
        down(1,30,100,0);down(2,80,100,10);down(3,130,100,20);
        engine.up(3,130,100,30);engine.up(2,80,100,40);engine.up(1,30,100,50);
        assertEquals(List.of("shortcut:toggleKeyboard"),listener.actions);listener.actions.clear();
        down(1,30,100,500);down(2,80,100,510);down(3,130,100,520);down(4,180,100,530);
        engine.up(4,180,100,540);engine.up(3,130,100,550);engine.up(2,80,100,560);engine.up(1,30,100,570);engine.tick(1000);
        assertTrue(listener.actions.isEmpty());
    }
    @Test public void slowMultiTapAndMovingTailCannotTriggerShortcut() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Preset.trackpad,GestureConfiguration.Target.computer));
        down(1,30,100,0);down(2,80,100,10);engine.up(2,80,100,240);engine.up(1,30,100,260);
        assertTrue(listener.actions.isEmpty());
        down(1,30,100,500);down(2,80,100,510);engine.up(2,80,100,540);move(1,50,100,550);engine.up(1,50,100,560);
        assertTrue(listener.actions.isEmpty());
    }
    @Test public void movementMappingsAndNaturalScrollNeverReverseEdgeStrip() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Target.computer)
            .withAction(GestureConfiguration.Gesture.oneFingerMove,GestureConfiguration.Action.scroll)
            .withAction(GestureConfiguration.Gesture.twoFingerMove,GestureConfiguration.Action.movePointer).withNaturalScrolling(false));
        down(1,80,100,0);move(1,80,120,50);engine.up(1,80,120,70);
        assertArrayEquals(new double[]{0,-20},listener.scrolls.get(0),.001);
        down(1,80,100,100);down(2,120,100,110);engine.move(new int[]{1,2},new double[]{80,120},new double[]{120,120},150);
        engine.up(2,120,120,160);engine.up(1,80,120,170);assertArrayEquals(new double[]{0,20},listener.moves.get(0),.001);
        down(1,349,100,200);move(1,349,120,250);engine.up(1,349,120,270);assertArrayEquals(new double[]{0,-20},listener.scrolls.get(1),.001);
    }
    @Test public void configurationChangeCancelsPendingAndReleasesHeldButtonButEqualUpdateDoesNot() {
        var config=new GestureConfiguration(GestureConfiguration.Target.computer);
        tap(1,50,0);engine.setConfiguration(config.withNaturalScrolling(false));engine.tick(1000);assertTrue(listener.actions.isEmpty());
        down(1,50,100,1100);engine.tick(1400);engine.setConfiguration(config.withNaturalScrolling(false));assertTrue(engine.isDragging());
        engine.setConfiguration(config);assertFalse(engine.isDragging());assertEquals(List.of("drag:true","drag:false"),listener.actions);
    }
    @Test public void tvPointerUsesTelevisionProfileWhileDirectionalModeIgnoresIt() {
        engine.setTvMode(true);engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Preset.pressMenu,GestureConfiguration.Target.television));
        tap(1,50,0);assertEquals(List.of("confirm"),listener.actions);listener.actions.clear();
        engine.setTvPointerMode(true);tap(1,50,100);assertEquals(List.of("left:1"),listener.actions);listener.actions.clear();
        down(1,50,80,200);engine.tick(500);engine.up(1,50,80,550);assertEquals(List.of("shortcut:back"),listener.actions);
    }
    @Test public void accessibilityActivationUsesCurrentMappingWithoutDeferredClick() {
        engine.setConfiguration(new GestureConfiguration(GestureConfiguration.Target.computer).withAction(GestureConfiguration.Gesture.singleTap,GestureConfiguration.Action.toggleDictation));
        engine.accessibilityClick();engine.tick(1000);assertEquals(List.of("shortcut:toggleDictation"),listener.actions);
    }

}
