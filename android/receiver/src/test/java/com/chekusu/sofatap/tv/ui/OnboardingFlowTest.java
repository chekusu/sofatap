package com.chekusu.sofatap.tv.ui;

import static org.junit.Assert.*;

import com.chekusu.sofatap.tv.ui.OnboardingFlow.Inputs;
import com.chekusu.sofatap.tv.ui.OnboardingFlow.Stage;
import org.junit.Test;

public class OnboardingFlowTest {
    private static Inputs in(boolean qr, boolean connected, boolean needsPermission) {
        return new Inputs().set(true, true, false, qr, connected, needsPermission);
    }

    @Test public void firstRunAsksForPermissionBeforeShowingTheCode() {
        OnboardingFlow flow = new OnboardingFlow(false);
        flow.update(in(true, false, true), 0);
        assertEquals(Stage.PERMISSION, flow.stage());
        flow.update(in(true, false, false), 100);
        assertEquals(Stage.READY, flow.stage());
    }

    @Test public void scanPlaysPairingThenGuideDrivenByRealInput() {
        OnboardingFlow flow = new OnboardingFlow(false);
        flow.update(in(true, false, false), 0);
        assertEquals(Stage.READY, flow.stage());
        flow.update(in(false, true, false), 1000);
        assertEquals(Stage.LINKING, flow.stage());
        flow.update(in(false, true, false), 1000 + OnboardingFlow.LINKING_MS);
        assertEquals(Stage.CONNECTED, flow.stage());
        long t = 1000 + OnboardingFlow.LINKING_MS + OnboardingFlow.CONNECTED_MS;
        flow.update(in(false, true, false), t);
        assertEquals(Stage.GUIDE_MOVE, flow.stage());
        for (int i = 0; i < OnboardingFlow.MOVES_TO_ADVANCE - 1; i++) assertFalse(flow.onInput("move", t + i));
        assertTrue(flow.onInput("move", t + 50));
        assertEquals(Stage.GUIDE_TAP, flow.stage());
        assertFalse("taps right after the step opens are ignored", flow.onInput("click", t + 60));
        assertTrue(flow.onInput("click", t + 50 + OnboardingFlow.TAP_GRACE_MS));
        assertEquals(Stage.SCREENS, flow.stage());
        assertFalse(flow.onboarded());
        assertTrue(flow.advance(t + 5000));
        assertEquals(Stage.IDLE, flow.stage());
        assertTrue(flow.onboarded());
    }

    @Test public void laterSkipsPermissionUntilAfterPairing() {
        OnboardingFlow flow = new OnboardingFlow(false);
        flow.update(in(true, false, true), 0);
        assertTrue(flow.advance(10));
        assertEquals(Stage.READY, flow.stage());
        flow.update(in(true, false, true), 20);
        assertEquals("deferred permission does not bounce back", Stage.READY, flow.stage());
        flow.update(in(false, true, true), 30);
        flow.update(in(false, true, true), 30 + OnboardingFlow.LINKING_MS);
        flow.update(in(false, true, true), 30 + OnboardingFlow.LINKING_MS + OnboardingFlow.CONNECTED_MS);
        assertEquals(Stage.IDLE, flow.stage());
    }

    @Test public void onboardedReceiverOpensIdleAndReturnsToPermissionWhenRevoked() {
        OnboardingFlow flow = new OnboardingFlow(true);
        flow.update(in(false, false, false), 0);
        assertEquals(Stage.IDLE, flow.stage());
        flow.update(in(false, false, true), 10);
        assertEquals(Stage.PERMISSION, flow.stage());
        flow.update(in(false, true, false), 20);
        assertEquals(Stage.IDLE, flow.stage());
    }

    @Test public void newPairingCodeShowsReadyAndSkipsGuideOnceOnboarded() {
        OnboardingFlow flow = new OnboardingFlow(true);
        flow.update(in(false, true, false), 0);
        assertEquals(Stage.IDLE, flow.stage());
        flow.update(in(true, false, false), 10);
        assertEquals(Stage.READY, flow.stage());
        flow.update(in(false, true, false), 20);
        flow.update(in(false, true, false), 20 + OnboardingFlow.LINKING_MS);
        flow.update(in(false, true, false), 20 + OnboardingFlow.LINKING_MS + OnboardingFlow.CONNECTED_MS);
        assertEquals(Stage.IDLE, flow.stage());
    }

    @Test public void receiverStatesOverrideTheSequence() {
        OnboardingFlow flow = new OnboardingFlow(false);
        flow.update(new Inputs().set(false, false, false, false, false, false), 0);
        assertEquals(Stage.STOPPED, flow.stage());
        flow.update(new Inputs().set(true, false, false, false, false, false), 1);
        assertEquals(Stage.PREPARING, flow.stage());
        flow.update(new Inputs().set(true, true, true, false, false, false), 2);
        assertEquals(Stage.ERROR, flow.stage());
    }

    @Test public void guideTimesOutWithoutInput() {
        OnboardingFlow flow = new OnboardingFlow(false);
        flow.update(in(false, true, false), 0);
        assertEquals("an upgraded, already paired receiver still sees the guide once", Stage.CONNECTED, flow.stage());
        flow.update(in(false, true, false), OnboardingFlow.CONNECTED_MS);
        assertEquals(Stage.GUIDE_MOVE, flow.stage());
        flow.update(in(false, true, false), OnboardingFlow.CONNECTED_MS + OnboardingFlow.GUIDE_TIMEOUT_MS);
        assertEquals(Stage.GUIDE_TAP, flow.stage());
        assertTrue(flow.skipGuide(OnboardingFlow.CONNECTED_MS + OnboardingFlow.GUIDE_TIMEOUT_MS + 1));
        assertEquals(Stage.IDLE, flow.stage());
    }
}
