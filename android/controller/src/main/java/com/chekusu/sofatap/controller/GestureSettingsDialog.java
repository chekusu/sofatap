package com.chekusu.sofatap.controller;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.View;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.List;
import java.util.Set;
import static com.chekusu.sofatap.controller.GestureConfiguration.*;

/** Native settings and an explicitly local practice surface; no network/session is owned here. */
public final class GestureSettingsDialog {
    private final Activity activity;
    private final GesturePreferencesStore store;
    private final Target target;
    private final Set<Action> available;
    private final Runnable onChanged;
    private GestureConfiguration configuration;
    private final EnumMap<Gesture,Button> mappings=new EnumMap<>(Gesture.class);
    private final EnumMap<Preset,Button> presets=new EnumMap<>(Preset.class);
    private TextView profileNote,holdLabel,doubleLabel;
    private SeekBar holdSlider,doubleSlider;
    private Switch natural;
    private static final int MINT=0xffb2f5d1,MUTED=0xff99b3aa;

    private GestureSettingsDialog(Activity activity,GesturePreferencesStore store,Target target,Set<Action> available,Runnable onChanged) {
        this.activity=activity;this.store=store;this.target=target;
        this.available=available==null?null:Set.copyOf(available);this.onChanged=onChanged;configuration=store.load(target);
    }
    public static AlertDialog show(Activity activity,GesturePreferencesStore store,Target target,Set<Action> available,Runnable onChanged) {
        return new GestureSettingsDialog(activity,store,target,available,onChanged).open();
    }
    private AlertDialog open() {
        ScrollView scroll=new ScrollView(activity);scroll.setFillViewport(true);
        LinearLayout content=column();content.setPadding(dp(16),dp(6),dp(16),dp(16));scroll.addView(content);
        section(content,activity.getString(R.string.gs_presets)+" · "+GestureLabels.target(activity,target));
        for(Preset preset:Preset.values()) {
            Button button=button("",()->confirmPreset(preset));button.setTag("gesturePreset_"+preset.name());
            presets.put(preset,button);content.addView(button);
        }
        profileNote=text("",13,MUTED);content.addView(profileNote);
        if(target==Target.television)content.addView(text(activity.getString(R.string.gs_tv_pointer),13,MUTED));
        section(content,activity.getString(R.string.gs_mappings));
        for(Gesture gesture:Gesture.values()) {
            Button button=button("",()->chooseAction(gesture));button.setContentDescription(GestureLabels.gesture(activity,gesture));
            button.setTag("gestureBinding_"+gesture.name());mappings.put(gesture,button);content.addView(button);
        }
        content.addView(text(activity.getString(R.string.gs_mapping_note),13,MUTED));
        section(content,activity.getString(R.string.gs_feel));
        holdLabel=text("",15,Color.WHITE);content.addView(holdLabel);
        holdSlider=slider("gestureHoldDuration",20,()->save(configuration.withTiming(200+holdSlider.getProgress()*50,configuration.doubleTapIntervalMs)));
        holdSlider.setContentDescription(activity.getString(R.string.gs_hold_time));content.addView(holdSlider);
        doubleLabel=text("",15,Color.WHITE);content.addView(doubleLabel);
        doubleSlider=slider("gestureDoubleTapInterval",35,()->save(configuration.withTiming(configuration.holdDurationMs,150+doubleSlider.getProgress()*10)));
        doubleSlider.setContentDescription(activity.getString(R.string.gs_double_time));content.addView(doubleSlider);
        natural=new Switch(activity);natural.setText(R.string.gs_natural);natural.setTextColor(Color.WHITE);natural.setMinHeight(dp(48));
        natural.setTag("gestureNaturalScrolling");natural.setOnCheckedChangeListener((button,checked)->{if(checked!=configuration.naturalScrolling)save(configuration.withNaturalScrolling(checked));});content.addView(natural);
        content.addView(text(activity.getString(R.string.gs_timing_note),13,MUTED));
        Button practice=button(activity.getString(R.string.gs_practice),this::practice);practice.setTag("gesturePractice");content.addView(practice);
        Button reset=button(activity.getString(R.string.gs_reset),()->confirmPreset(Preset.sofatap));reset.setTag("gestureReset");content.addView(reset);
        update();
        AlertDialog dialog=new AlertDialog.Builder(activity).setTitle(R.string.gs_title).setView(scroll).setPositiveButton(R.string.gs_done,null).create();
        dialog.show();return dialog;
    }
    private void chooseAction(Gesture gesture) {
        List<Action> actions=new ArrayList<>();
        for(Action action:allowedActions(gesture,target))if(action==Action.none||available==null||available.contains(action)||action==configuration.action(gesture))actions.add(action);
        String[] labels=new String[actions.size()];
        for(int i=0;i<actions.size();i++){Action action=actions.get(i);labels[i]=GestureLabels.action(activity,action,target)+(supported(action)?"":" — "+activity.getString(R.string.gs_unsupported));}
        ArrayAdapter<String> adapter=new ArrayAdapter<>(activity,android.R.layout.select_dialog_singlechoice,labels){
            @Override public boolean isEnabled(int position){return supported(actions.get(position));}
            @Override public View getView(int position,View convert,android.view.ViewGroup parent){View view=super.getView(position,convert,parent);view.setEnabled(isEnabled(position));view.setAlpha(isEnabled(position)?1f:.48f);return view;}
        };
        AlertDialog dialog=new AlertDialog.Builder(activity).setTitle(GestureLabels.gesture(activity,gesture)).setSingleChoiceItems(adapter,actions.indexOf(configuration.action(gesture)),(d,which)->{
            Action action=actions.get(which);if(!supported(action))return;save(configuration.withAction(gesture,action));d.dismiss();
        }).setNegativeButton(R.string.gs_cancel,null).create();dialog.show();
    }
    private boolean supported(Action action){return action==Action.none||available==null||available.contains(action);}
    private void confirmPreset(Preset preset) {
        new AlertDialog.Builder(activity).setTitle(R.string.gs_replace).setMessage(R.string.gs_replace_note)
            .setNegativeButton(R.string.gs_cancel,null).setPositiveButton(R.string.gs_apply,(d,w)->save(new GestureConfiguration(preset,target))).show();
    }
    private void save(GestureConfiguration next) {
        if(next.equals(configuration))return;
        if(store.save(next)){configuration=next;if(onChanged!=null)onChanged.run();}
        else Toast.makeText(activity,R.string.gs_save_error,Toast.LENGTH_SHORT).show();
        update();
    }
    private void update() {
        Preset selected=configuration.matchingPreset();
        for(Preset preset:Preset.values()){Button button=presets.get(preset);button.setText((preset==selected?"✓  ":"")+GestureLabels.preset(activity,preset)+"\n"+GestureLabels.detail(activity,preset,target));button.setSelected(preset==selected);}
        profileNote.setText(selected==null?R.string.gs_custom:R.string.gs_separate);
        for(Gesture gesture:Gesture.values()) {
            Action action=configuration.action(gesture);Button button=mappings.get(gesture);
            button.setText(GestureLabels.gesture(activity,gesture)+"\n"+GestureLabels.action(activity,action,target)+(supported(action)?"":"\n"+activity.getString(R.string.gs_unsupported)));
        }
        holdSlider.setProgress((configuration.holdDurationMs-200)/50);doubleSlider.setProgress((configuration.doubleTapIntervalMs-150)/10);
        natural.setChecked(configuration.naturalScrolling);timingLabels();
    }
    private void timingLabels(){if(holdLabel!=null&&holdSlider!=null)holdLabel.setText(activity.getString(R.string.gs_hold_time)+" · "+(200+holdSlider.getProgress()*50)+" ms");if(doubleLabel!=null&&doubleSlider!=null)doubleLabel.setText(activity.getString(R.string.gs_double_time)+" · "+(150+doubleSlider.getProgress()*10)+" ms");}
    private SeekBar slider(String tag,int max,Runnable save) {
        SeekBar slider=new SeekBar(activity);slider.setTag(tag);slider.setMax(max);
        slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar bar,int progress,boolean user){timingLabels();if(user)save.run();}public void onStartTrackingTouch(SeekBar bar){}public void onStopTrackingTouch(SeekBar bar){save.run();}});return slider;
    }
    private void practice() {
        LinearLayout content=column();content.setPadding(dp(14),dp(8),dp(14),dp(14));
        content.addView(text(activity.getString(R.string.gs_practice_note),14,MUTED));
        TextView result=text(activity.getString(R.string.gs_practice_ready),17,MINT);result.setTag("gesturePracticeResult");result.setMinHeight(dp(62));
        TouchSurfaceView surface=new TouchSurfaceView(activity);surface.setTag("gesturePracticeSurface");surface.setContentDescription(activity.getString(R.string.touch_surface));
        surface.setTvMode(target==Target.television);surface.setTvPointerMode(target==Target.television);surface.setConfiguration(configuration);
        surface.setListener(new TouchSurfaceView.Listener(){
            private void show(Action action){result.setText(GestureLabels.action(activity,action,target)+(supported(action)?"":"\n"+activity.getString(R.string.gs_unsupported)));}
            public void move(double x,double y){show(Action.movePointer);}public void scroll(double x,double y){show(Action.scroll);}
            public void click(boolean right,int count){show(right?(count>1?Action.doubleRightClick:Action.rightClick):(count>1?Action.doubleLeftClick:Action.leftClick));}
            public void drag(boolean down){if(down)show(Action.drag);else result.setText(R.string.gs_drag_end);}
            public void navigate(String direction){show(direction.equals("home")?Action.home:Action.confirm);}public void back(){show(Action.back);}public void shortcut(Action action){show(action);}
        });
        int usableHeight=activity.getResources().getDisplayMetrics().heightPixels;
        content.addView(surface,new LinearLayout.LayoutParams(-1,Math.max(dp(100),Math.min(dp(340),usableHeight-dp(240)))));content.addView(result);
        AlertDialog practice=new AlertDialog.Builder(activity).setTitle(R.string.gs_practice).setView(content).setPositiveButton(R.string.gs_done,null).create();
        practice.setOnDismissListener(d->surface.cancelGesture());practice.show();
    }
    private LinearLayout column(){LinearLayout layout=new LinearLayout(activity);layout.setOrientation(LinearLayout.VERTICAL);layout.setBackgroundColor(0xff0b1114);return layout;}
    private TextView text(String value,int size,int color){TextView view=new TextView(activity);view.setText(value);view.setTextSize(size);view.setTextColor(color);view.setPadding(0,dp(8),0,dp(8));return view;}
    private void section(LinearLayout content,String title){TextView label=text(title,15,MINT);label.setPadding(0,dp(22),0,dp(8));content.addView(label);}
    private Button button(String title,Runnable callback){Button button=new Button(activity);button.setAllCaps(false);button.setText(title);button.setTextColor(MINT);button.setGravity(Gravity.START|Gravity.CENTER_VERTICAL);button.setMinHeight(dp(56));button.setPadding(dp(12),dp(10),dp(12),dp(10));GradientDrawable background=new GradientDrawable();background.setColor(0xff152024);background.setCornerRadius(dp(12));button.setBackground(background);LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(6);button.setLayoutParams(lp);button.setOnClickListener(v->{v.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);callback.run();});return button;}
    private int dp(float value){return Math.round(value*activity.getResources().getDisplayMetrics().density);}
}
