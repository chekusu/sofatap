package com.chekusu.sofatap.controller;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.*;
import android.view.*;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;
import com.google.zxing.BarcodeFormat;
import com.journeyapps.barcodescanner.*;
import org.json.JSONObject;
import java.util.*;

/** Native phone controller. The TV receiver remains a separate application. */
public final class MainActivity extends Activity implements TouchSurfaceView.Listener {
    private static final int MINT=0xffb2f5d1, BACKGROUND=0xff0b1114, PANEL=0xff151d22, MUTED=0xff91a6a0;
    private static final int CAMERA=71, MICROPHONE=73;
    private DeviceStore store;
    RemoteSession session;
    private LinearLayout root;
    private FrameLayout pad;
    TouchSurfaceView surface;
    LiveEditText editor;
    private TextView deviceLabel, statusLabel;
    private IconButton keyboardButton, foldButton, sendButton, micButton, resumeButton;
    private LinearLayout composer, tvButtons;
    private boolean keyboardVisible, sending, uncertain, tv;
    private int tvPage, renderedTvPage=-1;
    private AlertDialog scanDialog, guideDialog;
    private DecoratedBarcodeView scanner;
    private final Map<String,String> drafts=new HashMap<>();
    private final Set<String> uncertainDrafts=new HashSet<>();
    private String activeDraftId="", dictationTarget;
    private String lastAutoEditor="", pendingAutoEditor;
    private int autoEditorGeneration, autoEditorAttempts;
    private boolean autoEditorScheduled;
    private ExplicitKeyboardRequest explicitKeyboard;
    private final class ExplicitKeyboardRequest {
        final String target=activeDraftId;
        final long draft=draftGeneration;
        final Pairing pairing=session.pairing;
        final boolean connected=session.connected();
        final int focus=connected?session.status.focusRevision:-1;
        final String editorEpoch=connected?session.status.editorEpoch:null;
        String liveSession=session.liveText.sessionId();
        int attempts;
        boolean scheduled;
    }
    private boolean resumed;
    private boolean compactStatusBar, restoreStatusBar;
    private int previousSystemBarsBehavior;
    private String restoredDraft="";
    private boolean restoredUncertain;
    private int deliveryMessage;
    private long draftGeneration;
    private long appliedLiveSnapshot=-1;
    private GesturePreferencesStore gesturePreferences;
    private boolean tvPointerMode, applyingEditor, pendingDictation, speechWasLive;
    private DictationSession dictation;
    private SpeechDraft speechBase;
    private String speechEditorKey, speechSessionId;
    private long speechGeneration;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if(android.os.Build.VERSION.SDK_INT>=30)getWindow().setDecorFitsSystemWindows(false);
        try { store=new DeviceStore(getApplicationContext()); }
        catch(Exception e) { new AlertDialog.Builder(this).setMessage(R.string.store_error).setPositiveButton(R.string.done,(d,w)->finish()).show(); return; }
        gesturePreferences=new GesturePreferencesStore(this);
        dictation=new DictationSession(this);
        session=new RemoteSession(store,this::updateState);
        if(state!=null) { restoredDraft=state.getString("draft",""); restoredUncertain=state.getBoolean("uncertain"); }
        tvPointerMode=getPreferences(MODE_PRIVATE).getBoolean("tvPointer",false);
        buildUi();
        try {
            DeviceStore.Device selected=store.selected();
            if(selected!=null) { activeDraftId=selected.id; session.select(selected.pairing,false); }
        } catch(Exception e) { toast(R.string.store_error); }
        if(state!=null&&!Objects.equals(state.getString("draftTarget",""),activeDraftId)) { restoredDraft="";restoredUncertain=false; }
        editor.setText(restoredDraft); uncertain=restoredUncertain; updateState();
    }
    private int dp(float n) { return Math.round(n*getResources().getDisplayMetrics().density); }
    private GradientDrawable background(int color,int radius) { GradientDrawable d=new GradientDrawable(); d.setColor(color); d.setCornerRadius(dp(radius)); return d; }
    private TextView label(String text,int size,int color) { TextView v=new TextView(this); v.setText(text); v.setTextSize(size); v.setTextColor(color); return v; }
    private IconButton icon(String name,int label,Runnable action) {
        IconButton b=new IconButton(this,name); b.setContentDescription(getString(label));
        b.setOnClickListener(v->action.run()); return b;
    }
    private void haptic(View v) { v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); }
    private void buildUi() {
        String draft=editor==null?restoredDraft:editor.getText().toString();
        LiveEditText retainedEditor=editor;
        if(retainedEditor!=null&&retainedEditor.getParent() instanceof ViewGroup parent)parent.removeView(retainedEditor);
        boolean landscape=getResources().getConfiguration().orientation==Configuration.ORIENTATION_LANDSCAPE;
        if(!landscape)restoreStatusBar();
        root=new LinearLayout(this); root.setOrientation(landscape?LinearLayout.HORIZONTAL:LinearLayout.VERTICAL); root.setBackgroundColor(BACKGROUND);
        root.setPadding(dp(16),dp(12),dp(16),dp(8));
        setContentView(root);
        root.setOnApplyWindowInsetsListener((v,insets)->{
            if(android.os.Build.VERSION.SDK_INT>=30) {
                adaptLandscapeSystemBars(insets);
                android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
                android.graphics.Insets ime=insets.getInsets(WindowInsets.Type.ime());
                root.setPadding(dp(16)+bars.left,dp(8)+bars.top,dp(16)+bars.right,dp(6)+Math.max(bars.bottom,ime.bottom));
                keyboardVisible=insets.isVisible(WindowInsets.Type.ime()); keyboardVisibilityObserved(); updateKeyboardIcons();
                fitEditorHeight();
            }
            return insets;
        });
        root.addOnLayoutChangeListener((v,l,t,r,b,oldL,oldT,oldR,oldB)->{
            fitEditorHeight();
            if(android.os.Build.VERSION.SDK_INT>=30&&(b-t!=oldB-oldT||r-l!=oldR-oldL))v.requestApplyInsets();
        });
        if(android.os.Build.VERSION.SDK_INT<30) root.getViewTreeObserver().addOnGlobalLayoutListener(()->{
            Rect r=new Rect(); root.getWindowVisibleDisplayFrame(r);
            keyboardVisible=root.getRootView().getHeight()-r.bottom>dp(160); keyboardVisibilityObserved(); updateKeyboardIcons();
        });
        pad=new FrameLayout(this); pad.setBackground(background(0xff10191b,32)); pad.setClipToOutline(true);
        root.addView(pad,landscape?new LinearLayout.LayoutParams(0,-1,1):new LinearLayout.LayoutParams(-1,0,1));
        surface=new TouchSurfaceView(this); surface.setListener(this); surface.setContentDescription(getString(R.string.touch_surface));
        pad.addView(surface,new FrameLayout.LayoutParams(-1,-1));
        LinearLayout top=new LinearLayout(this); top.setGravity(Gravity.CENTER_VERTICAL); top.setPadding(dp(14),0,dp(6),0);
        pad.addView(top,new FrameLayout.LayoutParams(-1,dp(landscape?48:66),Gravity.TOP));
        ImageButton logo=new ImageButton(this); logo.setImageResource(R.drawable.brand_mark); logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        logo.setPadding(0,0,0,0); logo.setBackgroundColor(Color.TRANSPARENT); logo.setContentDescription(getString(R.string.devices));
        logo.setOnClickListener(v->{haptic(logo);showDevices();}); top.addView(logo,new LinearLayout.LayoutParams(dp(landscape?36:44),dp(landscape?36:44)));
        deviceLabel=label(getString(R.string.no_device),14,MINT); deviceLabel.setMaxLines(2); deviceLabel.setEllipsize(TextUtils.TruncateAt.END);
        deviceLabel.setPadding(dp(8),0,0,0); deviceLabel.setOnClickListener(v->showDevices());
        top.addView(deviceLabel,new LinearLayout.LayoutParams(0,-2,1));
        top.addView(icon("scan",R.string.add_device,this::showScanner),new LinearLayout.LayoutParams(dp(44),dp(44)));
        top.addView(icon("help",R.string.guide,this::showGuide),new LinearLayout.LayoutParams(dp(44),dp(44)));
        keyboardButton=icon("keyboard",R.string.keyboard,this::toggleKeyboard);
        FrameLayout.LayoutParams kb=new FrameLayout.LayoutParams(dp(landscape?44:52),dp(landscape?44:52),Gravity.BOTTOM|Gravity.START); kb.setMargins(dp(12),0,0,dp(landscape?4:16)); pad.addView(keyboardButton,kb);
        micButton=icon("mic",R.string.dictate,this::dictate); micButton.setPrimary(true);
        FrameLayout.LayoutParams mic=new FrameLayout.LayoutParams(dp(landscape?52:70),dp(landscape?52:70),Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);mic.bottomMargin=dp(landscape?4:12);pad.addView(micButton,mic);
        renderedTvPage=-1;tvButtons=new LinearLayout(this); tvButtons.setGravity(Gravity.CENTER);
        FrameLayout.LayoutParams tvlp=new FrameLayout.LayoutParams(dp(92),dp(landscape?44:52),Gravity.BOTTOM|Gravity.END);tvlp.setMargins(0,0,dp(8),dp(landscape?4:16));pad.addView(tvButtons,tvlp);
        tvButtons.setOnTouchListener(new View.OnTouchListener(){float x; public boolean onTouch(View v,android.view.MotionEvent e){
            if(e.getActionMasked()==0){x=e.getX();return true;} if(e.getActionMasked()==1){if(Math.abs(e.getX()-x)>dp(20)){tvPage=(tvPage+(e.getX()<x?1:2))%3;renderTvButtons();haptic(v);}return true;}return true;}});
        LinearLayout inputColumn=new LinearLayout(this);inputColumn.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams columnParams=landscape?new LinearLayout.LayoutParams(dp(300),-1):new LinearLayout.LayoutParams(-1,-2);
        if(landscape){columnParams.leftMargin=dp(12);inputColumn.setGravity(Gravity.BOTTOM);}
        root.addView(inputColumn,columnParams);
        composer=new LinearLayout(this); composer.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams cp=new LinearLayout.LayoutParams(-1,-2);cp.topMargin=landscape?0:dp(12);inputColumn.addView(composer,cp);
        FrameLayout field=new FrameLayout(this);field.setBackground(background(PANEL,22));composer.addView(field,new LinearLayout.LayoutParams(-1,-2));
        editor=retainedEditor==null?new LiveEditText(this):retainedEditor;
        if(retainedEditor==null){editor.setId(View.generateViewId());editor.setTextColor(Color.WHITE);editor.setHintTextColor(MUTED);
        editor.setTextSize(17);editor.setHint(R.string.draft_hint);editor.setMinLines(1);editor.setMaxLines(3);
        editor.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        editor.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI);
        editor.setPadding(dp(16),dp(14),dp(64),dp(14));editor.setBackgroundColor(Color.TRANSPARENT);
        editor.setFilters(new InputFilter[]{new InputFilter.LengthFilter(16000)}); if(retainedEditor==null)editor.setText(draft);
        editor.setSaveEnabled(false);}
        editor.setMinHeight(dp(54));
        editor.setMaxLines(3);
        field.addView(editor,new FrameLayout.LayoutParams(-1,-2));
        sendButton=icon("send",R.string.send,this::sendText);sendButton.setPrimary(true);
        FrameLayout.LayoutParams sp=new FrameLayout.LayoutParams(dp(44),dp(44),Gravity.END|Gravity.BOTTOM);sp.setMargins(0,dp(5),dp(7),dp(5));field.addView(sendButton,sp);
        editor.setEditListener(new LiveEditText.Listener(){
            public void edited(String text,int start,int length,boolean composing){
                if(applyingEditor)return;
                session.liveText.edit(new LiveTextEditor.Snapshot(text,start,length),composing);updateSend();
            }
            public void emptyBackspace(){
                if(!usesLiveText()&&!uncertain&&!sending&&!speechBusy()&&session.connected()&&
                    !"protected".equals(session.status.focusState)&&!"other".equals(session.status.focusState))remoteBackspace();
            }
        });
        editor.setOnFocusChangeListener((v,focused)->{if(focused)openLiveEditor();});
        LinearLayout lower=new LinearLayout(this);lower.setGravity(Gravity.CENTER_VERTICAL);inputColumn.addView(lower,new LinearLayout.LayoutParams(-1,dp(44)));
        foldButton=icon("down",R.string.hide_keyboard,this::toggleKeyboard);lower.addView(foldButton,new LinearLayout.LayoutParams(dp(38),dp(38)));
        lower.addView(icon("trash",R.string.clear,this::clearText),new LinearLayout.LayoutParams(dp(38),dp(38)));
        lower.addView(icon("backspace",R.string.backspace,this::remoteBackspace),new LinearLayout.LayoutParams(dp(38),dp(38)));
        lower.addView(icon("enter",R.string.enter,this::remoteEnter),new LinearLayout.LayoutParams(dp(38),dp(38)));
        resumeButton=icon("refresh",R.string.live_resume,this::restartLiveEditor);
        lower.addView(resumeButton,new LinearLayout.LayoutParams(dp(38),dp(38)));
        statusLabel=label("",11,MUTED);statusLabel.setGravity(Gravity.END);statusLabel.setMaxLines(2);
        lower.addView(statusLabel,new LinearLayout.LayoutParams(0,-2,1));
        updateKeyboardIcons();updateState();
    }
    @android.annotation.TargetApi(30)
    private void adaptLandscapeSystemBars(WindowInsets insets){
        // Some landscape phone IMEs leave less than two rows of touch controls.
        // Reclaim only this window's status bar; navigation/cutout insets stay safe.
        // Ignoring visibility makes the threshold stable after hiding the bar.
        android.graphics.Insets stable=insets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
        int bottom=Math.max(stable.bottom,insets.getInsets(WindowInsets.Type.ime()).bottom);
        int height=root.getHeight();
        boolean compact=resumed&&getResources().getConfiguration().orientation==Configuration.ORIENTATION_LANDSCAPE&&
                insets.isVisible(WindowInsets.Type.ime())&&height>0&&height-stable.top-bottom-dp(14)<dp(128);
        WindowInsetsController controller=getWindow().getInsetsController();
        if(compact&&!compactStatusBar&&controller!=null){
            compactStatusBar=true;restoreStatusBar=insets.isVisible(WindowInsets.Type.statusBars());
            previousSystemBarsBehavior=controller.getSystemBarsBehavior();
            controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            controller.hide(WindowInsets.Type.statusBars());
        }else if(!compact)restoreStatusBar();
    }
    private void restoreStatusBar(){
        if(android.os.Build.VERSION.SDK_INT<30||!compactStatusBar)return;
        compactStatusBar=false;
        WindowInsetsController controller=getWindow().getInsetsController();
        if(controller!=null){
            controller.setSystemBarsBehavior(previousSystemBarsBehavior);
            if(restoreStatusBar)controller.show(WindowInsets.Type.statusBars());
        }
        restoreStatusBar=false;
    }
    private void fitEditorHeight(){
        if(editor==null||root==null||root.getHeight()==0)return;
        int lines=3;
        if(getResources().getConfiguration().orientation==Configuration.ORIENTATION_LANDSCAPE){
            int available=root.getHeight()-root.getPaddingTop()-root.getPaddingBottom()-dp(44);
            lines=Math.max(1,Math.min(3,(available-editor.getCompoundPaddingTop()-editor.getCompoundPaddingBottom())/Math.max(1,editor.getLineHeight())));
        }
        if(editor.getMaxLines()!=lines)editor.setMaxLines(lines);
    }
    private void updateKeyboardIcons(){ if(keyboardButton==null)return;keyboardButton.setActive(keyboardVisible);foldButton.setIcon(keyboardVisible?"down":"up");foldButton.setContentDescription(getString(keyboardVisible?R.string.hide_keyboard:R.string.keyboard));keyboardButton.setContentDescription(foldButton.getContentDescription()); }
    private void toggleKeyboard(){
        InputMethodManager ime=(InputMethodManager)getSystemService(INPUT_METHOD_SERVICE);
        if(keyboardVisible){
            String target=currentEditorKey();if(target!=null)lastAutoEditor=target;
            cancelAutoKeyboard();explicitKeyboard=null;
            if(android.os.Build.VERSION.SDK_INT>=30&&editor.getWindowInsetsController()!=null)editor.getWindowInsetsController().hide(WindowInsets.Type.ime());
            ime.hideSoftInputFromWindow(editor.getWindowToken(),0);editor.clearFocus();
        }else {openLiveEditor();editor.requestFocus();showEditorKeyboard();}
    }
    private boolean speechBusy(){return pendingDictation || dictation!=null&&dictation.active();}
    private boolean usesLiveText(){
        if(session==null)return false;
        LiveTextEditor model=session.liveText;
        return model.imported() || model.state()==LiveTextEditor.State.STARTING || model.state()==LiveTextEditor.State.PAUSED ||
            session.connected()&&!session.pairing.isTv()&&session.status.supportsLiveText&&model.state()!=LiveTextEditor.State.UNSUPPORTED&&editor.getText().length()==0;
    }
    private LiveTextEditor.Snapshot localSnapshot(){
        int a=Math.max(0,editor.getSelectionStart()),b=Math.max(0,editor.getSelectionEnd());
        return new LiveTextEditor.Snapshot(editor.getText().toString(),Math.min(a,b),Math.abs(a-b));
    }
    private void openLiveEditor(){
        if(editor==null||session==null||!session.connected()||session.pairing.isTv()||speechBusy())return;
        session.liveText.open(localSnapshot(),editor.composing());
    }
    private void restartLiveEditor(){
        if(speechBusy()||sending)return;
        new AlertDialog.Builder(this).setMessage(R.string.live_reload_confirm).setNegativeButton(R.string.cancel,null)
            .setPositiveButton(R.string.live_resume,(d,w)->session.liveText.restart(localSnapshot(),editor.composing())).show();
    }
    private void updateSend(){
        if(sendButton==null||session==null)return;
        boolean live=usesLiveText();
        sendButton.setIcon(live?"check":"send");
        sendButton.setContentDescription(getString(live?R.string.live_sync:R.string.send));
        sendButton.setEnabled(!live&&session.connected()&&session.status.canText&&!sending&&!speechBusy()&&!editor.composing()&&editor.getText().length()>0);
        editor.setEnabled(!sending&&!speechBusy()&&session.liveText.state()!=LiveTextEditor.State.STARTING&&session.liveText.state()!=LiveTextEditor.State.PAUSED);
        if(resumeButton!=null)resumeButton.setVisibility(session.liveText.state()==LiveTextEditor.State.PAUSED?View.VISIBLE:View.GONE);
        if(micButton!=null){micButton.setActive(speechBusy());micButton.setContentDescription(getString(speechBusy()?R.string.stop_dictation:R.string.dictate));}
    }
    private void renderLiveEditor(){
        LiveTextEditor model=session.liveText;
        if(appliedLiveSnapshot!=model.snapshotVersion()){
            appliedLiveSnapshot=model.snapshotVersion();LiveTextEditor.Snapshot snapshot=model.snapshot();
            applyingEditor=true;
            try {if(snapshot!=null)editor.applySnapshot(snapshot.text,snapshot.selectionStart,snapshot.selectionLength);
                else editor.applySnapshot("",0,0);}
            finally {applyingEditor=false;}
        }
        if(speechBase!=null&&(!Objects.equals(dictationTarget,activeDraftId)||!Objects.equals(speechEditorKey,currentEditorKey())||speechWasLive&&(!model.ready()||!Objects.equals(speechSessionId,model.sessionId()))))cancelSpeech();
    }
    private void clearText(){
        if(sending||speechBusy())return;
        if(session.liveText.ready()){
            new AlertDialog.Builder(this).setMessage(R.string.live_clear_confirm).setNegativeButton(R.string.cancel,null)
                .setPositiveButton(R.string.clear,(d,w)->{editor.applySnapshot("",0,0);editor.flushEdit();}).show();
        }else if(!usesLiveText()){
            editor.setText("");uncertain=false;uncertainDrafts.remove(activeDraftId);deliveryMessage=0;updateState();
        }
    }
    private void updateState(){
        if(deviceLabel==null||session==null)return;
        renderLiveEditor();
        tv=session.pairing!=null&&session.pairing.isTv();
        surface.setConfiguration(gesturePreferences.load(tv?GestureConfiguration.Target.television:GestureConfiguration.Target.computer));
        surface.setTvMode(tv);surface.setTvPointerMode(tvPointerMode);tvButtons.setVisibility(tv?View.VISIBLE:View.GONE);renderTvButtons();
        String name=getString(R.string.no_device);
        try{DeviceStore.Device d=store.selected();if(d!=null)name=d.name;}catch(Exception ignored){}
        if(session.pairing!=null&&session.state==RemoteSession.State.CONNECTING)name=session.pairing.name==null?session.pairing.host:session.pairing.name;
        deviceLabel.setText(name);
        int stateId=switch(session.state){case CONNECTING->R.string.connecting;case RETRYING->R.string.retrying;case BLOCKED->R.string.failed;case CONNECTED->session.status.ready?R.string.connected:R.string.not_ready;default->R.string.no_device;};
        int liveMessage=switch(session.liveText.state()){
            case STARTING->R.string.live_loading;case SYNCING->R.string.live_syncing;
            case PAUSED->R.string.live_paused;default->0;};
        statusLabel.setText(!session.connected()?stateId:speechBusy()?R.string.listening:liveMessage!=0?liveMessage:deliveryMessage!=0?deliveryMessage:stateId);updateSend();
        if(pendingDictation&&session.liveText.state()!=LiveTextEditor.State.STARTING)editor.post(()->{if(pendingDictation)startSpeech();});
        maybeShowKeyboard();
    }
    private String currentEditorKey(){
        if(session==null||!session.connected()||!session.status.canText||!"editable".equals(session.status.focusState))return null;
        String revision=session.pairing.isTv()?session.status.editorEpoch:Integer.toString(session.status.focusRevision);
        return revision==null||revision.equals("-1")?null:session.pairing.identity()+":"+revision;
    }
    private void cancelAutoKeyboard(){pendingAutoEditor=null;autoEditorGeneration++;autoEditorAttempts=0;autoEditorScheduled=false;}
    private void keyboardVisibilityObserved(){
        // Request acceptance is not proof that an OEM keyboard became visible.
        if(!keyboardVisible||editor==null||!editor.hasFocus()||!hasWindowFocus())return;
        explicitKeyboard=null;
        String target=currentEditorKey();
        if(target!=null){lastAutoEditor=target;cancelAutoKeyboard();}
    }
    private void showEditorKeyboard(){
        if(android.os.Build.VERSION.SDK_INT>=30&&editor.getWindowInsetsController()!=null)
            editor.getWindowInsetsController().show(WindowInsets.Type.ime());
        else ((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(editor,InputMethodManager.SHOW_IMPLICIT);
    }
    private void maybeShowKeyboard(){
        maybeShowExplicitKeyboard();
        if(explicitKeyboard!=null)return;
        String target=currentEditorKey();
        if(!resumed||editor==null||target==null||target.equals(lastAutoEditor)){cancelAutoKeyboard();return;}
        if(!target.equals(pendingAutoEditor)){cancelAutoKeyboard();pendingAutoEditor=target;}
        if(autoEditorScheduled||autoEditorAttempts>=4||scanDialog!=null||guideDialog!=null||!hasWindowFocus()||sending||speechBusy())return;
        scheduleAutoKeyboard(target,autoEditorGeneration,0);
    }
    private boolean explicitKeyboardTargetValid(ExplicitKeyboardRequest request){
        if(!resumed||request.draft!=draftGeneration||!Objects.equals(request.target,activeDraftId)||request.pairing!=session.pairing)return false;
        if(request.connected&&(!session.connected()||request.focus!=session.status.focusRevision||!Objects.equals(request.editorEpoch,session.status.editorEpoch)))return false;
        if(session.liveText.state()==LiveTextEditor.State.PAUSED)return false;
        if(request.liveSession!=null&&!Objects.equals(request.liveSession,session.liveText.sessionId()))return false;
        if(request.liveSession==null&&session.liveText.ready())request.liveSession=session.liveText.sessionId();
        return true;
    }
    private boolean explicitKeyboardCanShow(){
        return editor!=null&&editor.isAttachedToWindow()&&editor.isEnabled()&&hasWindowFocus()&&scanDialog==null&&guideDialog==null&&!sending&&!speechBusy();
    }
    private void maybeShowExplicitKeyboard(){
        ExplicitKeyboardRequest request=explicitKeyboard;
        if(request==null)return;
        if(!explicitKeyboardTargetValid(request)){explicitKeyboard=null;return;}
        if(request.scheduled||request.attempts>=4||!explicitKeyboardCanShow())return;
        request.scheduled=true;
        editor.postDelayed(()->{
            request.scheduled=false;
            if(request!=explicitKeyboard)return;
            if(!explicitKeyboardTargetValid(request)){explicitKeyboard=null;return;}
            if(!explicitKeyboardCanShow())return;
            editor.requestFocus();
            // Gaining focus can itself start an asynchronous live import.
            if(!explicitKeyboardCanShow())return;
            request.attempts++;showEditorKeyboard();
            if(request==explicitKeyboard&&request.attempts<4)maybeShowExplicitKeyboard();
        },request.attempts==0?0:request.attempts==1?100:request.attempts==2?250:500);
    }
    private void scheduleAutoKeyboard(String target,int generation,long delay){
        autoEditorScheduled=true;
        editor.postDelayed(()->{
            if(generation!=autoEditorGeneration)return;
            autoEditorScheduled=false;
            if(!resumed||!target.equals(currentEditorKey())||target.equals(lastAutoEditor)||scanDialog!=null||guideDialog!=null||!hasWindowFocus()||sending||!editor.isAttachedToWindow())return;
            openLiveEditor();
            // Opening a live session may disable the editor until its ACK arrives.
            // That state transition calls updateState; it must not consume IME attempts.
            if(!editor.isEnabled()||speechBusy()||session.liveText.state()==LiveTextEditor.State.STARTING||session.liveText.state()==LiveTextEditor.State.PAUSED)return;
            autoEditorAttempts++;editor.requestFocus();showEditorKeyboard();
            // A bounded retry survives the dialog/window focus hand-off. Heartbeats
            // cannot reset the attempt budget; visible IME or explicit hide consumes it.
            if(generation==autoEditorGeneration&&autoEditorAttempts<4)
                scheduleAutoKeyboard(target,generation,autoEditorAttempts==1?100:autoEditorAttempts==2?250:500);
        },delay);
    }
    @Override public void onWindowFocusChanged(boolean hasFocus){
        super.onWindowFocusChanged(hasFocus);
        if(hasFocus)maybeShowKeyboard();else cancelAutoKeyboard();
    }
    private void renderTvButtons(){
        if(tvButtons==null||renderedTvPage==tvPage)return;renderedTvPage=tvPage;tvButtons.removeAllViews();String[][] icons={{"back","home"},{"left","right"},{"up","down"}};
        String[] selected=icons[tvPage];for(String k:selected){IconButton b=icon(k,k.equals("back")?R.string.back:k.equals("home")?R.string.home:k.equals("left")?R.string.left:k.equals("right")?R.string.right:k.equals("up")?R.string.up:R.string.down,()->navigate(k));
            // A horizontal swipe on either button changes pages; a tap retains the button action.
            b.setOnTouchListener(new View.OnTouchListener(){float x;boolean swiped;public boolean onTouch(View v,android.view.MotionEvent e){if(e.getActionMasked()==0){x=e.getX();swiped=false;}if(e.getActionMasked()==2&&Math.abs(e.getX()-x)>dp(20))swiped=true;if(e.getActionMasked()==1&&swiped){tvPage=(tvPage+(e.getX()<x?1:2))%3;renderTvButtons();haptic(v);return true;}return swiped;}});
            tvButtons.addView(b,new LinearLayout.LayoutParams(dp(44),dp(48)));}
    }
    private void toast(int resource){Toast.makeText(this,resource,Toast.LENGTH_SHORT).show();}
    private void saveDraft(){drafts.put(activeDraftId,session.liveText.imported()?"":editor.getText().toString());if(uncertain)uncertainDrafts.add(activeDraftId);else uncertainDrafts.remove(activeDraftId);}
    private void choose(DeviceStore.Device device){
        if(sending||speechBusy()){toast(R.string.queue_busy);return;}
        try{saveDraft();session.liveText.end();store.select(device.id);activeDraftId=device.id;draftGeneration++;session.select(device.pairing,false);editor.applySnapshot(drafts.getOrDefault(device.id,""),0,0);uncertain=uncertainDrafts.contains(device.id);deliveryMessage=uncertain?R.string.uncertain:0;updateState();}catch(Exception e){toast(R.string.store_error);}
    }
    private void showDevices(){
        try{List<DeviceStore.Device> devices=store.list();List<String> names=new ArrayList<>();for(var d:devices)names.add(d.name+(d.id.equals(store.selectedId())?"  ✓":""));names.add("+ "+getString(R.string.add_device));
            new AlertDialog.Builder(this).setTitle(R.string.devices).setItems(names.toArray(new String[0]),(d,w)->{if(w==devices.size())showScanner();else deviceOptions(devices.get(w));}).setNegativeButton(R.string.done,null).show();
        }catch(Exception e){toast(R.string.store_error);}
    }
    private void deviceOptions(DeviceStore.Device device){
        List<String> choices=new ArrayList<>(List.of(getString(R.string.pair),getString(R.string.rename),getString(R.string.disconnect),getString(R.string.remove)));
        if(device.pairing.isTv()){choices.add(getString(R.string.pair_remote));choices.add(getString(R.string.tv_control_mode));}
        new AlertDialog.Builder(this).setTitle(device.name).setItems(choices.toArray(new String[0]),(d,w)->{
            if(w==0)choose(device);
            if(w==1){EditText name=new EditText(this);name.setSingleLine(true);name.setText(device.name);new AlertDialog.Builder(this).setTitle(R.string.rename).setView(name).setNegativeButton(R.string.cancel,null).setPositiveButton(R.string.done,(a,b)->{try{store.rename(device.id,name.getText().toString());updateState();}catch(Exception e){toast(R.string.invalid_pairing);}}).show();}
            if(w==2&&session.pairing!=null&&session.pairing.identity().equals(device.id)){surface.cancelGesture();session.disconnect();}
            if(w==3){try{if(session.pairing!=null&&session.pairing.identity().equals(device.id)){surface.cancelGesture();session.forget();editor.setText("");activeDraftId="";}store.remove(device.id);drafts.remove(device.id);uncertainDrafts.remove(device.id);updateState();}catch(Exception e){toast(R.string.store_error);}}
            if(w==4){if(session.pairing==null||!session.pairing.identity().equals(device.id)||!session.connected()){choose(device);toast(R.string.connecting);}else pairTvRemote();}
            if(w==5){
                new AlertDialog.Builder(this).setTitle(R.string.tv_control_mode).setSingleChoiceItems(new String[]{getString(R.string.tv_navigation),getString(R.string.tv_pointer)},tvPointerMode?1:0,(a,b)->{
                    surface.cancelGesture();tvPointerMode=b==1;getPreferences(MODE_PRIVATE).edit().putBoolean("tvPointer",tvPointerMode).apply();updateState();a.dismiss();
                }).show();
            }
        }).show();
    }
    private void showScanner(){
        if(sending||speechBusy()){toast(R.string.queue_busy);return;}
        LinearLayout content=new LinearLayout(this);content.setOrientation(LinearLayout.VERTICAL);content.setPadding(dp(12),dp(8),dp(12),dp(12));
        scanner=new DecoratedBarcodeView(this);scanner.setDecoderFactory(new DefaultDecoderFactory(List.of(BarcodeFormat.QR_CODE)));
        content.addView(scanner,new LinearLayout.LayoutParams(-1,dp(260)));
        TextView info=label(getString(R.string.supported),14,MUTED);info.setPadding(dp(8),dp(16),dp(8),dp(12));content.addView(info);
        scanDialog=new AlertDialog.Builder(this).setTitle(R.string.scan).setView(content).setNeutralButton(R.string.paste_link,(d,w)->pasteLink()).setNegativeButton(R.string.cancel,null).create();
        scanDialog.setOnDismissListener(d->{if(scanner!=null)scanner.pause();scanner=null;scanDialog=null;});
        scanner.decodeSingle(new BarcodeCallback(){public void barcodeResult(BarcodeResult result){String raw=result.getText();if(scanDialog!=null)scanDialog.dismiss();pair(raw);}public void possibleResultPoints(List<com.google.zxing.ResultPoint> points){}});
        scanDialog.show();
        if(checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)scanner.resume();else requestPermissions(new String[]{Manifest.permission.CAMERA},CAMERA);
    }
    private void pasteLink(){EditText link=new EditText(this);link.setHint("sofatap://…");link.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);link.setSaveEnabled(false);
        new AlertDialog.Builder(this).setTitle(R.string.paste_link).setView(link).setNegativeButton(R.string.cancel,null).setPositiveButton(R.string.pair,(d,w)->pair(link.getText().toString())).show();}
    void pair(String raw){try{Pairing p=Pairing.parse(raw);saveDraft();session.liveText.end();activeDraftId=p.identity();draftGeneration++;session.select(p,true);editor.applySnapshot(drafts.getOrDefault(activeDraftId,""),0,0);uncertain=uncertainDrafts.contains(activeDraftId);deliveryMessage=uncertain?R.string.uncertain:0;updateState();}catch(Exception e){toast(R.string.invalid_pairing);}}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(request==MICROPHONE){if(results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED&&resumed)dictate();else toast(R.string.microphone_permission);}if(request==CAMERA&&scanner!=null){if(results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED)scanner.resume();else toast(R.string.camera_permission);}}
    private void showGuide(){
        cancelAutoKeyboard();
        guideDialog=new AlertDialog.Builder(this).setTitle(R.string.guide).setMessage(tv?R.string.guide_tv:R.string.guide_desktop)
            .setNeutralButton(R.string.gesture_settings,(d,w)->showGestureSettings()).setPositiveButton(R.string.done,null).create();
        guideDialog.setOnDismissListener(d->{guideDialog=null;maybeShowKeyboard();});
        guideDialog.show();
    }
    private void showGestureSettings(){
        surface.cancelGesture();
        GestureConfiguration.Target target=tv?GestureConfiguration.Target.television:GestureConfiguration.Target.computer;
        GestureSettingsDialog.show(this,gesturePreferences,target,GestureConfiguration.availableActions(session.status,target),this::updateState);
    }
    private void dictate(){
        if(dictation.active()){dictation.stop();return;}
        if(pendingDictation){cancelSpeech();updateState();return;}
        if(sending||session.liveText.state()==LiveTextEditor.State.PAUSED){toast(R.string.queue_busy);return;}
        if(!dictation.available()){useKeyboardDictation();return;}
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO},MICROPHONE);return;
        }
        editor.flushEdit();openLiveEditor();pendingDictation=true;updateState();
    }
    private void startSpeech(){
        if(!pendingDictation||!resumed)return;
        if(session.liveText.state()==LiveTextEditor.State.PAUSED){cancelSpeech();updateState();return;}
        pendingDictation=false;captureSpeechDraft();
        if(!dictation.available()){useKeyboardDictation();return;}
        dictation.start(new DictationSession.Listener(){
            public void transcript(String text,boolean finalResult){applySpeechResult(text);}
            public void finished(boolean error){speechBase=null;updateState();if(error)toast(R.string.speech_error);}
        });updateState();
    }
    private void useKeyboardDictation(){
        cancelSpeech();cancelAutoKeyboard();lastAutoEditor="";
        editor.flushEdit();openLiveEditor();
        // An explicit request must survive live import even when the receiver
        // has no focus metadata. Bind it to this device/session, not auto-focus.
        explicitKeyboard=new ExplicitKeyboardRequest();updateState();
        toast(R.string.speech_missing);
    }
    void captureSpeechDraft(){
        dictationTarget=activeDraftId;speechEditorKey=currentEditorKey();speechWasLive=session.liveText.ready();speechSessionId=session.liveText.sessionId();speechGeneration=draftGeneration;
        int a=Math.max(0,editor.getSelectionStart()),b=Math.max(0,editor.getSelectionEnd());
        speechBase=new SpeechDraft(editor.getText().toString(),Math.min(a,b),Math.abs(a-b));
    }
    void applySpeechResult(String text){
        if(speechBase==null||speechGeneration!=draftGeneration||!Objects.equals(dictationTarget,activeDraftId)||
            !Objects.equals(speechEditorKey,currentEditorKey())||speechWasLive&&(!session.liveText.ready()||!Objects.equals(speechSessionId,session.liveText.sessionId()))){cancelSpeech();return;}
        try{SpeechDraft result=speechBase.replacing(text);editor.applySnapshot(result.text,result.start,result.length);editor.flushEdit();}
        catch(IllegalArgumentException invalid){cancelSpeech();toast(R.string.unsupported);}
    }
    private void cancelSpeech(){pendingDictation=false;speechBase=null;if(dictation!=null)dictation.cancel();}
    private void sendText(){
        if(usesLiveText()||speechBusy()||!editor.flushEdit())return;
        if(uncertain){new AlertDialog.Builder(this).setMessage(R.string.uncertain).setNegativeButton(R.string.cancel,null).setPositiveButton(R.string.review,(d,w)->{uncertain=false;uncertainDrafts.remove(activeDraftId);deliveryMessage=0;updateState();}).show();return;}
        if(!session.connected()||sending)return;
        String text=editor.getText().toString();long generation=draftGeneration;
        try{JSONObject action=WireActions.text(session.pairing,session.status,text);sending=true;editor.setEnabled(false);deliveryMessage=R.string.sending;updateState();
            boolean queued=session.send(action,result->{sending=false;editor.setEnabled(true);if(generation!=draftGeneration)return;
                if(result==RemoteSession.Result.ACCEPTED){String current=editor.getText().toString();if(current.startsWith(text))editor.setText(current.substring(text.length()));else uncertain=true;deliveryMessage=uncertain?R.string.uncertain:R.string.sent;}
                else{uncertain=result==RemoteSession.Result.UNCERTAIN;deliveryMessage=uncertain?R.string.uncertain:R.string.not_sent;}updateState();});
            if(!queued){sending=false;editor.setEnabled(true);deliveryMessage=R.string.not_sent;updateState();}
        }catch(Exception e){toast(R.string.unsupported);}
    }
    private interface Action { JSONObject value(); }
    private void execute(Action action){if(!session.connected()){toast(R.string.no_device);return;}try{if(!session.send(action.value(),result->{if(result==RemoteSession.Result.REJECTED||result==RemoteSession.Result.UNCERTAIN)toast(R.string.unsupported);})){toast(R.string.queue_busy);}}catch(Exception e){toast(R.string.unsupported);}}
    private void remoteBackspace(){
        if(sending||speechBusy()||session.liveText.state()==LiveTextEditor.State.PAUSED||editor.composing())return;
        if(session.liveText.ready()){
            int start=Math.min(editor.getSelectionStart(),editor.getSelectionEnd()),end=Math.max(editor.getSelectionStart(),editor.getSelectionEnd());
            if(start==end&&start>0){android.icu.text.BreakIterator chars=android.icu.text.BreakIterator.getCharacterInstance();chars.setText(editor.getText().toString());start=chars.preceding(start);}
            if(start>=0&&end>start){editor.getText().delete(start,end);editor.setSelection(start);editor.flushEdit();}
        }else execute(()->WireActions.backspace(session.pairing,session.status));
    }
    private void remoteEnter(){if(!sending&&!speechBusy()&&session.liveText.state()!=LiveTextEditor.State.PAUSED&&editor.flushEdit())execute(()->WireActions.enter(session.pairing,session.status));}
    private void pairTvRemote(){
        if(!session.connected()||!session.pairing.isTv()){toast(R.string.no_device);return;}
        String target=session.pairing.identity();
        if(!session.send(WireActions.remotePairStart(),result->{
            if(result!=RemoteSession.Result.ACCEPTED){toast(R.string.unsupported);return;}
            if(!resumed||!session.connected()||!target.equals(session.pairing.identity()))return;
            EditText code=new EditText(this);code.setSingleLine(true);
            code.setFilters(new InputFilter[]{new InputFilter.LengthFilter(6)});
            code.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS);
            new AlertDialog.Builder(this).setTitle(R.string.pair_remote).setMessage(R.string.pair_remote_help).setView(code)
                .setNegativeButton(R.string.cancel,null).setPositiveButton(R.string.pair,(d,w)->{
                    if(session.connected()&&target.equals(session.pairing.identity()))execute(()->WireActions.remotePairCode(code.getText().toString()));
                }).show();
        }))toast(R.string.queue_busy);
    }
    @Override public void move(double dx,double dy){if(session.connected()&&session.status.canMove)try{session.send(WireActions.move(session.pairing,Math.max(-500,Math.min(500,dx)),Math.max(-500,Math.min(500,dy))),null);}catch(Exception ignored){}}
    @Override public void scroll(double dx,double dy){if(session.connected()&&session.status.canScroll)try{session.send(WireActions.scroll(session.pairing,Math.max(-500,Math.min(500,dx*8)),Math.max(-500,Math.min(500,dy*8))),null);}catch(Exception ignored){}}
    @Override public void click(boolean right,int count){if(!session.connected()||!(right?session.status.canRightClick:session.status.canClick))return;for(int i=0;i<count;i++)execute(()->WireActions.click(session.pairing,right));}
    @Override public void drag(boolean down){if(session.connected()&&session.status.canDrag)execute(()->WireActions.button(down));}
    @Override public void navigate(String direction){if(session.connected()&&(session.status.canNavigate||direction.equals("back")&&session.status.canBack||direction.equals("home")&&session.status.canHome))execute(()->WireActions.key(session.pairing,session.status,direction));else toast(R.string.unsupported);}
    @Override public void back(){navigate("back");}
    @Override public void shortcut(GestureConfiguration.Action action){switch(action){
        case toggleKeyboard->toggleKeyboard();case toggleDictation->dictate();case confirm->{if(tv)navigate("confirm");else remoteEnter();}case back->navigate("back");case home->navigate("home");default->{} }}
    @Override protected void onResume(){super.onResume();resumed=true;if(root!=null)root.requestApplyInsets();if(session!=null)session.resume();if(scanner!=null&&checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)scanner.resume();}
    @Override protected void onPause(){resumed=false;explicitKeyboard=null;cancelAutoKeyboard();restoreStatusBar();cancelSpeech();if(surface!=null)surface.cancelGesture();if(scanner!=null)scanner.pause();super.onPause();}
    @Override protected void onStop(){if(session!=null)session.suspend();super.onStop();}
    @Override protected void onDestroy(){cancelAutoKeyboard();cancelSpeech();super.onDestroy();}
    @Override public void onConfigurationChanged(Configuration c){super.onConfigurationChanged(c);if(surface!=null)surface.cancelGesture();if(editor!=null)editor.flushEdit();buildUi();}
    @Override protected void onSaveInstanceState(Bundle out){if(editor!=null){out.putString("draft",session.liveText.imported()?"":editor.getText().toString());out.putBoolean("uncertain",uncertain||sending);out.putString("draftTarget",activeDraftId);}super.onSaveInstanceState(out);}
}
