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
import android.speech.RecognizerIntent;
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
    private static final int CAMERA=71, DICTATION=72;
    private DeviceStore store;
    RemoteSession session;
    private LinearLayout root;
    private FrameLayout pad;
    TouchSurfaceView surface;
    EditText editor;
    private TextView deviceLabel, statusLabel;
    private IconButton keyboardButton, foldButton, sendButton, micButton;
    private LinearLayout composer, tvButtons;
    private boolean keyboardVisible, sending, uncertain, tv;
    private int tvPage, renderedTvPage=-1;
    private AlertDialog scanDialog;
    private DecoratedBarcodeView scanner;
    private final Map<String,String> drafts=new HashMap<>();
    private final Set<String> uncertainDrafts=new HashSet<>();
    private String activeDraftId="", dictationTarget;
    private String lastAutoEditor="";
    private boolean resumed;
    private String restoredDraft="";
    private boolean restoredUncertain;
    private int deliveryMessage;
    private long draftGeneration;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        if(android.os.Build.VERSION.SDK_INT>=30)getWindow().setDecorFitsSystemWindows(false);
        try { store=new DeviceStore(getApplicationContext()); }
        catch(Exception e) { new AlertDialog.Builder(this).setMessage(R.string.store_error).setPositiveButton(R.string.done,(d,w)->finish()).show(); return; }
        session=new RemoteSession(store,this::updateState);
        if(state!=null) { restoredDraft=state.getString("draft",""); restoredUncertain=state.getBoolean("uncertain"); }
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
        boolean landscape=getResources().getConfiguration().orientation==Configuration.ORIENTATION_LANDSCAPE;
        root=new LinearLayout(this); root.setOrientation(landscape?LinearLayout.HORIZONTAL:LinearLayout.VERTICAL); root.setBackgroundColor(BACKGROUND);
        root.setPadding(dp(16),dp(12),dp(16),dp(8));
        setContentView(root);
        root.setOnApplyWindowInsetsListener((v,insets)->{
            if(android.os.Build.VERSION.SDK_INT>=30) {
                android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.displayCutout());
                android.graphics.Insets ime=insets.getInsets(WindowInsets.Type.ime());
                root.setPadding(dp(16)+bars.left,dp(8)+bars.top,dp(16)+bars.right,dp(6)+Math.max(bars.bottom,ime.bottom));
                keyboardVisible=insets.isVisible(WindowInsets.Type.ime()); updateKeyboardIcons();
            }
            return insets;
        });
        if(android.os.Build.VERSION.SDK_INT<30) root.getViewTreeObserver().addOnGlobalLayoutListener(()->{
            Rect r=new Rect(); root.getWindowVisibleDisplayFrame(r);
            keyboardVisible=root.getRootView().getHeight()-r.bottom>dp(160); updateKeyboardIcons();
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
        editor=new EditText(this);editor.setId(View.generateViewId());editor.setTextColor(Color.WHITE);editor.setHintTextColor(MUTED);
        editor.setTextSize(17);editor.setHint(R.string.draft_hint);editor.setMinLines(1);editor.setMaxLines(3);
        editor.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE|android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        editor.setImeOptions(android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI);
        editor.setPadding(dp(16),dp(14),dp(64),dp(14));editor.setBackgroundColor(Color.TRANSPARENT);
        editor.setFilters(new InputFilter[]{new InputFilter.LengthFilter(16000)}); editor.setText(draft);
        editor.setSaveEnabled(false);field.addView(editor,new FrameLayout.LayoutParams(-1,-2));
        sendButton=icon("send",R.string.send,this::sendText);sendButton.setPrimary(true);
        FrameLayout.LayoutParams sp=new FrameLayout.LayoutParams(dp(44),dp(44),Gravity.END|Gravity.BOTTOM);sp.setMargins(0,dp(5),dp(7),dp(5));field.addView(sendButton,sp);
        editor.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int st,int c,int a){}public void onTextChanged(CharSequence s,int st,int before,int count){updateSend();}public void afterTextChanged(Editable e){}});
        LinearLayout lower=new LinearLayout(this);lower.setGravity(Gravity.CENTER_VERTICAL);inputColumn.addView(lower,new LinearLayout.LayoutParams(-1,dp(44)));
        foldButton=icon("down",R.string.hide_keyboard,this::toggleKeyboard);lower.addView(foldButton,new LinearLayout.LayoutParams(dp(38),dp(38)));
        lower.addView(icon("trash",R.string.clear,()->{if(!sending){editor.setText("");uncertain=false;uncertainDrafts.remove(activeDraftId);deliveryMessage=0;updateState();}}),new LinearLayout.LayoutParams(dp(38),dp(38)));
        lower.addView(icon("backspace",R.string.backspace,this::remoteBackspace),new LinearLayout.LayoutParams(dp(38),dp(38)));
        lower.addView(icon("enter",R.string.enter,this::remoteEnter),new LinearLayout.LayoutParams(dp(38),dp(38)));
        statusLabel=label("",11,MUTED);statusLabel.setGravity(Gravity.END);statusLabel.setMaxLines(2);
        lower.addView(statusLabel,new LinearLayout.LayoutParams(0,-2,1));
        updateKeyboardIcons();updateState();
    }
    private void updateKeyboardIcons(){ if(keyboardButton==null)return;keyboardButton.setActive(keyboardVisible);foldButton.setIcon(keyboardVisible?"down":"up");foldButton.setContentDescription(getString(keyboardVisible?R.string.hide_keyboard:R.string.keyboard));keyboardButton.setContentDescription(foldButton.getContentDescription()); }
    private void toggleKeyboard(){
        InputMethodManager ime=(InputMethodManager)getSystemService(INPUT_METHOD_SERVICE);
        if(keyboardVisible){ime.hideSoftInputFromWindow(editor.getWindowToken(),0);editor.clearFocus();}
        else {editor.requestFocus();ime.showSoftInput(editor,InputMethodManager.SHOW_IMPLICIT);}
    }
    private void updateSend(){if(sendButton!=null)sendButton.setEnabled(session!=null&&session.connected()&&session.status.canText&&!sending&&!editor.getText().toString().isEmpty());}
    private void updateState(){
        if(deviceLabel==null||session==null)return;
        tv=session.pairing!=null&&session.pairing.isTv();surface.setTvMode(tv);tvButtons.setVisibility(tv?View.VISIBLE:View.GONE);renderTvButtons();
        String name=getString(R.string.no_device);
        try{DeviceStore.Device d=store.selected();if(d!=null)name=d.name;}catch(Exception ignored){}
        if(session.pairing!=null&&session.state==RemoteSession.State.CONNECTING)name=session.pairing.name==null?session.pairing.host:session.pairing.name;
        deviceLabel.setText(name);
        int stateId=switch(session.state){case CONNECTING->R.string.connecting;case RETRYING->R.string.retrying;case BLOCKED->R.string.failed;case CONNECTED->session.status.ready?R.string.connected:R.string.not_ready;default->R.string.no_device;};
        statusLabel.setText(session.connected()&&deliveryMessage!=0?deliveryMessage:stateId);updateSend();
        maybeShowKeyboard();
    }
    private String currentEditorKey(){
        if(session==null||!session.connected()||!session.status.canText||!"editable".equals(session.status.focusState))return null;
        String revision=session.pairing.isTv()?session.status.editorEpoch:Integer.toString(session.status.focusRevision);
        return revision==null||revision.equals("-1")?null:session.pairing.identity()+":"+revision;
    }
    private void maybeShowKeyboard(){
        String target=currentEditorKey();
        if(!resumed||editor==null||target==null||target.equals(lastAutoEditor))return;
        editor.post(()->{
            if(!resumed||!target.equals(currentEditorKey())||target.equals(lastAutoEditor)||scanDialog!=null||!hasWindowFocus()||sending)return;
            editor.requestFocus();
            if(((InputMethodManager)getSystemService(INPUT_METHOD_SERVICE)).showSoftInput(editor,InputMethodManager.SHOW_IMPLICIT))
                lastAutoEditor=target; // Respect a later manual dismissal until the remote field changes.
        });
    }
    @Override public void onWindowFocusChanged(boolean hasFocus){super.onWindowFocusChanged(hasFocus);if(hasFocus)maybeShowKeyboard();}
    private void renderTvButtons(){
        if(tvButtons==null||renderedTvPage==tvPage)return;renderedTvPage=tvPage;tvButtons.removeAllViews();String[][] icons={{"back","home"},{"left","right"},{"up","down"}};
        String[] selected=icons[tvPage];for(String k:selected){IconButton b=icon(k,k.equals("back")?R.string.back:k.equals("home")?R.string.home:k.equals("left")?R.string.left:k.equals("right")?R.string.right:k.equals("up")?R.string.up:R.string.down,()->navigate(k));
            // A horizontal swipe on either button changes pages; a tap retains the button action.
            b.setOnTouchListener(new View.OnTouchListener(){float x;boolean swiped;public boolean onTouch(View v,android.view.MotionEvent e){if(e.getActionMasked()==0){x=e.getX();swiped=false;}if(e.getActionMasked()==2&&Math.abs(e.getX()-x)>dp(20))swiped=true;if(e.getActionMasked()==1&&swiped){tvPage=(tvPage+(e.getX()<x?1:2))%3;renderTvButtons();haptic(v);return true;}return swiped;}});
            tvButtons.addView(b,new LinearLayout.LayoutParams(dp(44),dp(48)));}
    }
    private void toast(int resource){Toast.makeText(this,resource,Toast.LENGTH_SHORT).show();}
    private void saveDraft(){drafts.put(activeDraftId,editor.getText().toString());if(uncertain)uncertainDrafts.add(activeDraftId);else uncertainDrafts.remove(activeDraftId);}
    private void choose(DeviceStore.Device device){
        if(sending){toast(R.string.queue_busy);return;}
        try{store.select(device.id);saveDraft();activeDraftId=device.id;draftGeneration++;editor.setText(drafts.getOrDefault(device.id,""));uncertain=uncertainDrafts.contains(device.id);deliveryMessage=uncertain?R.string.uncertain:0;session.select(device.pairing,false);}catch(Exception e){toast(R.string.store_error);}
    }
    private void showDevices(){
        try{List<DeviceStore.Device> devices=store.list();List<String> names=new ArrayList<>();for(var d:devices)names.add(d.name+(d.id.equals(store.selectedId())?"  ✓":""));names.add("+ "+getString(R.string.add_device));
            new AlertDialog.Builder(this).setTitle(R.string.devices).setItems(names.toArray(new String[0]),(d,w)->{if(w==devices.size())showScanner();else deviceOptions(devices.get(w));}).setNegativeButton(R.string.done,null).show();
        }catch(Exception e){toast(R.string.store_error);}
    }
    private void deviceOptions(DeviceStore.Device device){
        List<String> choices=new ArrayList<>(List.of(getString(R.string.pair),getString(R.string.rename),getString(R.string.disconnect),getString(R.string.remove)));
        if(device.pairing.isTv())choices.add(getString(R.string.pair_remote));
        new AlertDialog.Builder(this).setTitle(device.name).setItems(choices.toArray(new String[0]),(d,w)->{
            if(w==0)choose(device);
            if(w==1){EditText name=new EditText(this);name.setSingleLine(true);name.setText(device.name);new AlertDialog.Builder(this).setTitle(R.string.rename).setView(name).setNegativeButton(R.string.cancel,null).setPositiveButton(R.string.done,(a,b)->{try{store.rename(device.id,name.getText().toString());updateState();}catch(Exception e){toast(R.string.invalid_pairing);}}).show();}
            if(w==2&&session.pairing!=null&&session.pairing.identity().equals(device.id)){surface.cancelGesture();session.disconnect();}
            if(w==3){try{if(session.pairing!=null&&session.pairing.identity().equals(device.id)){surface.cancelGesture();session.forget();editor.setText("");activeDraftId="";}store.remove(device.id);drafts.remove(device.id);uncertainDrafts.remove(device.id);updateState();}catch(Exception e){toast(R.string.store_error);}}
            if(w==4){if(session.pairing==null||!session.pairing.identity().equals(device.id)||!session.connected()){choose(device);toast(R.string.connecting);}else pairTvRemote();}
        }).show();
    }
    private void showScanner(){
        if(sending){toast(R.string.queue_busy);return;}
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
    void pair(String raw){try{Pairing p=Pairing.parse(raw);saveDraft();activeDraftId=p.identity();draftGeneration++;editor.setText(drafts.getOrDefault(activeDraftId,""));uncertain=uncertainDrafts.contains(activeDraftId);deliveryMessage=uncertain?R.string.uncertain:0;session.select(p,true);}catch(Exception e){toast(R.string.invalid_pairing);}}
    @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] results){super.onRequestPermissionsResult(request,permissions,results);if(request==CAMERA&&scanner!=null){if(results.length>0&&results[0]==PackageManager.PERMISSION_GRANTED)scanner.resume();else toast(R.string.camera_permission);}}
    private void showGuide(){new AlertDialog.Builder(this).setTitle(R.string.guide).setMessage(tv?R.string.guide_tv:R.string.guide_desktop).setPositiveButton(R.string.done,null).show();}
    private void dictate(){
        if(sending){toast(R.string.queue_busy);return;}dictationTarget=activeDraftId;
        Intent intent=new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,1);
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE,Locale.getDefault().toLanguageTag());
        try{startActivityForResult(intent,DICTATION);}catch(ActivityNotFoundException e){toast(R.string.speech_missing);}
    }
    @Override protected void onActivityResult(int req,int result,Intent data){super.onActivityResult(req,result,data);if(req==DICTATION&&result==RESULT_OK&&data!=null&&Objects.equals(dictationTarget,activeDraftId)){
        ArrayList<String> results=data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS);if(results!=null&&!results.isEmpty()){int start=Math.max(0,editor.getSelectionStart()),end=Math.max(start,editor.getSelectionEnd());editor.getText().replace(start,end,results.get(0));}}
    }
    private void sendText(){
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
    private void remoteBackspace(){execute(()->WireActions.backspace(session.pairing,session.status));}
    private void remoteEnter(){execute(()->WireActions.enter(session.pairing,session.status));}
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
    @Override protected void onResume(){super.onResume();resumed=true;if(session!=null)session.resume();if(scanner!=null&&checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)scanner.resume();}
    @Override protected void onPause(){resumed=false;if(surface!=null)surface.cancelGesture();if(scanner!=null)scanner.pause();super.onPause();}
    @Override protected void onStop(){if(session!=null)session.suspend();super.onStop();}
    @Override public void onConfigurationChanged(Configuration c){super.onConfigurationChanged(c);if(surface!=null)surface.cancelGesture();buildUi();}
    @Override protected void onSaveInstanceState(Bundle out){if(editor!=null){out.putString("draft",editor.getText().toString());out.putBoolean("uncertain",uncertain||sending);out.putString("draftTarget",activeDraftId);}super.onSaveInstanceState(out);}
}
