package com.chekusu.sofatap.controller;

import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.WindowInsets;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.InputMethodManager;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry;
import androidx.test.runner.lifecycle.Stage;
import androidx.lifecycle.Lifecycle;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.File;
import java.io.FileOutputStream;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import java.util.function.Predicate;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;
import static com.chekusu.sofatap.controller.GestureConfiguration.*;

/** Settings UI and local practice on the isolated test device; never desktop input. */
@RunWith(AndroidJUnit4.class)
public final class GestureSettingsDeviceTest {
    private final Instrumentation instrumentation=InstrumentationRegistry.getInstrumentation();
    private ActivityScenario<MainActivity> scenario;
    private GesturePreferencesStore store;
    private SharedPreferences preferences;
    private String original;
    @Before public void prepare(){
        Context context=instrumentation.getTargetContext();preferences=context.getSharedPreferences("sofatap.gesturePreferences.v1",Context.MODE_PRIVATE);
        original=preferences.getString("profiles",null);store=new GesturePreferencesStore(context);
        assertTrue(store.save(new GestureConfiguration(Target.computer)));assertTrue(store.save(new GestureConfiguration(Preset.pressMenu,Target.television)));
        scenario=ActivityScenario.launch(MainActivity.class);
        withActivity(a->a.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT));
        await(()->mainCondition(a->a.getResources().getConfiguration().orientation==Configuration.ORIENTATION_PORTRAIT
            &&a.getWindow().getDecorView().hasWindowFocus()),"portrait activity window after any preceding rotation");
        withActivity(a->{a.session.disconnect();((InputMethodManager)a.getSystemService(Context.INPUT_METHOD_SERVICE)).hideSoftInputFromWindow(a.editor.getWindowToken(),0);a.editor.clearFocus();});
        await(()->mainCondition(a->a.getWindow().getDecorView().getRootWindowInsets()!=null
            &&!a.getWindow().getDecorView().getRootWindowInsets().isVisible(WindowInsets.Type.ime())),"hidden keyboard before settings");
    }
    @After public void finish(){
        try {
            if(scenario!=null){
                // ActivityScenario.close/onActivity first wait for global idleness. Finish on main
                // before closing the scenario so an animated dialog cannot strand cleanup.
                mainThread(()->{for(android.app.Activity activity:ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED))if(activity instanceof MainActivity)activity.finish();});
                await(()->scenario.getState()==Lifecycle.State.DESTROYED);scenario.close();
            }
        }finally{
            if(preferences!=null){SharedPreferences.Editor edit=preferences.edit();if(original==null)edit.remove("profiles");else edit.putString("profiles",original);assertTrue(edit.commit());}
        }
    }
    private void openSettings(){withActivity(a->GestureSettingsDialog.show(a,store,Target.computer,null,()->{}));awaitNode(label(R.string.gs_title));}

    @Test public void mappingsTimingPresetConfirmationPersistWithoutChangingTv()throws Exception{
        openSettings();screenshot("gesture-settings.png");
        clickVisible(label(R.string.gs_single));clickVisible(label(R.string.gs_keyboard));
        assertEquals(Action.toggleKeyboard,store.load(Target.computer).action(Gesture.singleTap));
        scrollTo(label(R.string.gs_hold_time));
        AccessibilityNodeInfo slider=awaitNode(label(R.string.gs_hold_time));Bundle progress=new Bundle();progress.putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE,9);
        assertTrue(slider.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.getId(),progress));
        await(()->store.load(Target.computer).holdDurationMs==650);
        scrollTo(label(R.string.gs_natural));clickVisible(label(R.string.gs_natural));assertFalse(store.load(Target.computer).naturalScrolling);
        clickVisible(label(R.string.gs_done));scenario.recreate();
        assertEquals(Action.toggleKeyboard,new GesturePreferencesStore(instrumentation.getTargetContext()).load(Target.computer).action(Gesture.singleTap));
        assertEquals(new GestureConfiguration(Preset.pressMenu,Target.television),store.load(Target.television));
        openSettings();clickVisible(GestureLabels.preset(instrumentation.getTargetContext(),Preset.trackpad)+"\n"+GestureLabels.detail(instrumentation.getTargetContext(),Preset.trackpad,Target.computer));
        clickVisible(label(R.string.gs_cancel));assertEquals(Action.toggleKeyboard,store.load(Target.computer).action(Gesture.singleTap));
        clickVisible(GestureLabels.preset(instrumentation.getTargetContext(),Preset.trackpad)+"\n"+GestureLabels.detail(instrumentation.getTargetContext(),Preset.trackpad,Target.computer));
        clickVisible(label(R.string.gs_apply));assertEquals(new GestureConfiguration(Preset.trackpad,Target.computer),store.load(Target.computer));
        scrollTo(label(R.string.gs_reset));clickVisible(label(R.string.gs_reset));clickVisible(label(R.string.gs_apply));
        assertEquals(new GestureConfiguration(Target.computer),store.load(Target.computer));assertEquals(new GestureConfiguration(Preset.pressMenu,Target.television),store.load(Target.television));
        clickVisible(label(R.string.gs_done));
    }
    @Test public void practiceDisplaysConfiguredShortcutWithoutExecutingIt()throws Exception{
        assertTrue(store.save(new GestureConfiguration(Target.computer).withAction(Gesture.singleTap,Action.toggleKeyboard)));
        openSettings();scrollTo(label(R.string.gs_practice));clickVisible(label(R.string.gs_practice));
        Rect area=awaitPracticeSurface();
        float tapX=area.left+area.width()/3f,tapY=area.exactCenterY();
        long down=SystemClock.uptimeMillis();MotionEvent press=MotionEvent.obtain(down,down,MotionEvent.ACTION_DOWN,tapX,tapY,0);press.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        assertTrue(instrumentation.getUiAutomation().injectInputEvent(press,true));press.recycle();SystemClock.sleep(45);
        MotionEvent release=MotionEvent.obtain(down,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,tapX,tapY,0);release.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        assertTrue(instrumentation.getUiAutomation().injectInputEvent(release,true));release.recycle();
        try {
            await(()->{
                AccessibilityNodeInfo root=instrumentation.getUiAutomation().getRootInActiveWindow();
                return find(root,label(R.string.gs_practice))!=null&&find(root,label(R.string.gs_keyboard))!=null;
            },"configured keyboard shortcut result in the practice dialog after one raw tap");
        }catch(AssertionError failure){try{screenshot("gesture-practice-failure.png");}catch(Exception ignored){}throw failure;}
        withActivity(a->{assertFalse(a.session.connected());assertFalse(a.getWindow().getDecorView().getRootWindowInsets().isVisible(WindowInsets.Type.ime()));});
        screenshot("gesture-practice.png");clickVisible(label(R.string.gs_done));awaitNode(label(R.string.gs_title));clickVisible(label(R.string.gs_done));
    }
    // Animated main/practice surfaces need not make the global queue idle. Every main-thread
    // inspection instead has a bounded dispatch, and each UI transition has its own assertion.
    private void mainQueueBarrier(){mainThread(()->{});}
    private boolean mainCondition(Predicate<MainActivity> condition){
        AtomicReference<Boolean> result=new AtomicReference<>(false);
        mainThread(()->{for(android.app.Activity activity:ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED))
            if(activity instanceof MainActivity current){result.set(condition.test(current));break;}});
        return result.get();
    }
    private void withActivity(Consumer<MainActivity> action){mainThread(()->{
        for(android.app.Activity activity:ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED))if(activity instanceof MainActivity current){action.accept(current);return;}
        fail("No resumed controller Activity");
    });}
    private void mainThread(Runnable action){
        CountDownLatch done=new CountDownLatch(1);AtomicReference<Throwable> failure=new AtomicReference<>();Handler main=new Handler(Looper.getMainLooper());
        Runnable work=()->{try{action.run();}catch(Throwable problem){failure.set(problem);}finally{done.countDown();}};
        assertTrue(main.post(work));
        try{if(!done.await(8,TimeUnit.SECONDS)){main.removeCallbacks(work);fail("Controller main thread did not respond within 8 seconds");}}
        catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new AssertionError(interrupted);}
        if(failure.get()!=null)throw new AssertionError("Controller main-thread assertion failed",failure.get());
    }
    private String label(int id){return instrumentation.getTargetContext().getString(id);}
    private void clickVisible(String value){AccessibilityNodeInfo node=awaitNode(value);while(node!=null&&!node.isClickable())node=node.getParent();assertNotNull(node);assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK));mainQueueBarrier();}
    private AccessibilityNodeInfo awaitNode(String value){final AccessibilityNodeInfo[] found={null};await(()->{found[0]=find(instrumentation.getUiAutomation().getRootInActiveWindow(),value);return found[0]!=null;},"visible node: "+value);return found[0];}
    private Rect awaitPracticeSurface(){
        Rect stable=new Rect();int[] window={-1};long[] since={0};
        await(()->{
            AccessibilityNodeInfo root=instrumentation.getUiAutomation().getRootInActiveWindow();
            // Both windows contain a touch_surface. Require the practice-only ready label
            // and stable final geometry before the single raw touch is injected. A window
            // focus/size change otherwise cancels the gesture in TouchSurfaceView itself.
            if(root==null||find(root,label(R.string.gs_practice))==null||find(root,label(R.string.gs_practice_ready))==null){since[0]=0;return false;}
            AccessibilityNodeInfo surface=find(root,label(R.string.touch_surface));
            if(surface==null||!surface.isEnabled()){since[0]=0;return false;}
            Rect bounds=new Rect();surface.getBoundsInScreen(bounds);
            if(bounds.isEmpty()){since[0]=0;return false;}
            long now=SystemClock.uptimeMillis();
            if(since[0]==0||window[0]!=root.getWindowId()||!stable.equals(bounds)){stable.set(bounds);window[0]=root.getWindowId();since[0]=now;return false;}
            return now-since[0]>=250;
        },"practice dialog ready with stable touch region");
        return new Rect(stable);
    }
    private static AccessibilityNodeInfo find(AccessibilityNodeInfo node,String value){
        if(node==null)return null;
        if(node.isVisibleToUser()&&(value.equalsIgnoreCase(String.valueOf(node.getText()))||value.equals(String.valueOf(node.getContentDescription()))))return node;
        for(int i=0;i<node.getChildCount();i++){AccessibilityNodeInfo found=find(node.getChild(i),value);if(found!=null)return found;}return null;
    }
    private void scrollTo(String value){
        for(int i=0;i<12;i++){
            AccessibilityNodeInfo[] target={null},scroll={null};
            // A shown Dialog can precede its accessibility window/content tree. Wait for
            // the correct settings window and a usable row or scroll container, not global idle.
            await(()->{
                AccessibilityNodeInfo root=instrumentation.getUiAutomation().getRootInActiveWindow();
                if(find(root,label(R.string.gs_title))==null)return false;
                target[0]=find(root,value);scroll[0]=scrollable(root);
                return target[0]!=null||scroll[0]!=null;
            });
            if(target[0]!=null)return;
            assertNotNull("No scroll container for "+value,scroll[0]);
            assertTrue("Cannot scroll toward "+value,scroll[0].performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD));SystemClock.sleep(220);
        }fail("Cannot find visible settings row: "+value);
    }
    private static AccessibilityNodeInfo scrollable(AccessibilityNodeInfo node){if(node==null)return null;if(node.isScrollable())return node;for(int i=0;i<node.getChildCount();i++){AccessibilityNodeInfo found=scrollable(node.getChild(i));if(found!=null)return found;}return null;}
    private static void await(BooleanSupplier condition){await(condition,"gesture settings transition");}
    private static void await(BooleanSupplier condition,String description){long deadline=SystemClock.uptimeMillis()+8000;while(SystemClock.uptimeMillis()<deadline){if(condition.getAsBoolean())return;SystemClock.sleep(60);}fail("Timed out waiting for "+description);}
    private void screenshot(String name)throws Exception{SystemClock.sleep(350);Bitmap bitmap=instrumentation.getUiAutomation().takeScreenshot();assertNotNull(bitmap);File directory=new File(instrumentation.getTargetContext().getExternalFilesDir(null),"acceptance");assertTrue(directory.isDirectory()||directory.mkdirs());try(FileOutputStream stream=new FileOutputStream(new File(directory,name))){assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG,100,stream));}finally{bitmap.recycle();}}
}
