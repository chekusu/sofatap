package com.chekusu.sofatap.controller;
import android.content.Context;
import static com.chekusu.sofatap.controller.GestureConfiguration.*;
public final class GestureLabels {
    private GestureLabels(){}
    public static String target(Context context,Target target){return context.getString(target==Target.computer?R.string.gs_computer:R.string.gs_tv);}
    public static String gesture(Context context,Gesture gesture){return context.getString(switch(gesture){case singleTap->R.string.gs_single;case leftDoubleTap->R.string.gs_left_double;case rightDoubleTap->R.string.gs_right_double;case twoFingerTap->R.string.gs_two_tap;case threeFingerTap->R.string.gs_three_tap;case longPress->R.string.gs_hold;case doubleTapHold->R.string.gs_double_hold;case oneFingerMove->R.string.gs_one_move;case twoFingerMove->R.string.gs_two_move;});}
    public static String action(Context context,Action action,Target target){return context.getString(switch(action){case none->R.string.gs_none;case leftClick->target==Target.computer?R.string.gs_left_click:R.string.gs_click;case rightClick->R.string.gs_right_click;case doubleLeftClick->R.string.gs_double_left;case doubleRightClick->R.string.gs_double_right;case drag->R.string.gs_drag;case movePointer->R.string.gs_move;case scroll->R.string.gs_scroll;case confirm->target==Target.computer?R.string.gs_enter:R.string.gs_confirm;case back->target==Target.computer?R.string.gs_escape:R.string.gs_back;case home->R.string.gs_home;case toggleKeyboard->R.string.gs_keyboard;case toggleDictation->R.string.gs_dictation;});}
    public static String preset(Context context,Preset preset){return context.getString(switch(preset){case sofatap->R.string.gs_sofatap;case trackpad->R.string.gs_trackpad;case pressMenu->R.string.gs_press_menu;});}
    public static String detail(Context context,Preset preset,Target target){return context.getString(target==Target.computer?switch(preset){case sofatap->R.string.gs_computer_sofatap;case trackpad->R.string.gs_computer_trackpad;case pressMenu->R.string.gs_computer_press;}:switch(preset){case sofatap->R.string.gs_tv_sofatap;case trackpad->R.string.gs_tv_trackpad;case pressMenu->R.string.gs_tv_press;});}
}
