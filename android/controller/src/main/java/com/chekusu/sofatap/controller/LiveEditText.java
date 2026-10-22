package com.chekusu.sofatap.controller;

import android.content.Context;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.widget.EditText;

/** Publishes complete native edits, including selection and IME composition transitions. */
public final class LiveEditText extends EditText {
    public interface Listener {
        void edited(String text, int start, int length, boolean composing);
        void emptyBackspace();
    }
    private Listener listener;
    private boolean applying, queued;
    private int batches, operationDepth;
    private final Runnable publish = () -> { queued=false; flushEdit(); };

    public LiveEditText(Context context) {
        super(context);
        addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s,int start,int count,int after) { }
            public void onTextChanged(CharSequence s,int start,int before,int count) { scheduleEdit(); }
            public void afterTextChanged(Editable value) { }
        });
    }
    public void setEditListener(Listener value) { listener=value; }
    public boolean composing() {
        return BaseInputConnection.getComposingSpanStart(getText())>=0 ||
            BaseInputConnection.getComposingSpanEnd(getText())>=0;
    }
    public void applySnapshot(String text,int start,int length) {
        applying=true;
        try {
            removeCallbacks(publish);queued=false;
            if(!getText().toString().equals(text))setText(text);
            setSelection(Math.min(start,text.length()),Math.min(start+length,text.length()));
        } finally { applying=false; }
    }
    public boolean flushEdit() {
        if(!applying && batches==0 && listener!=null) {
            int first=Math.max(0,getSelectionStart()),last=Math.max(0,getSelectionEnd());
            listener.edited(getText().toString(),Math.min(first,last),Math.abs(last-first),composing());
        }
        return !composing() && batches==0;
    }
    private void finishNativeEdit() {
        if(batches==0){removeCallbacks(publish);queued=false;flushEdit();}
    }
    private void scheduleEdit() {
        if(applying || queued || listener==null)return;
        queued=true;post(publish);
    }
    @Override protected void onSelectionChanged(int start,int end) {
        super.onSelectionChanged(start,end);scheduleEdit();
    }
    private boolean empty() { return isEnabled() && getText().length()==0 && !composing(); }
    private void emptyDelete(boolean wasEmpty) { if(wasEmpty && !applying && listener!=null)listener.emptyBackspace(); }
    @Override public boolean onKeyDown(int code,KeyEvent event) {
        boolean empty=operationDepth==0 && code==KeyEvent.KEYCODE_DEL && empty();
        boolean handled=super.onKeyDown(code,event);emptyDelete(empty);finishNativeEdit();return handled;
    }
    @Override public InputConnection onCreateInputConnection(EditorInfo info) {
        InputConnection target=super.onCreateInputConnection(info);
        if(target==null)return null;
        return new InputConnectionWrapper(target,false) {
            @Override public boolean beginBatchEdit(){batches++;return super.beginBatchEdit();}
            @Override public boolean endBatchEdit(){boolean result=super.endBatchEdit();batches=Math.max(0,batches-1);finishNativeEdit();return result;}
            @Override public boolean commitText(CharSequence text,int cursor){boolean result=super.commitText(text,cursor);finishNativeEdit();return result;}
            @Override public boolean setComposingText(CharSequence text,int cursor){boolean result=super.setComposingText(text,cursor);finishNativeEdit();return result;}
            @Override public boolean setComposingRegion(int start,int end){boolean result=super.setComposingRegion(start,end);finishNativeEdit();return result;}
            @Override public boolean finishComposingText(){boolean result=super.finishComposingText();finishNativeEdit();return result;}
            @Override public boolean setSelection(int start,int end){boolean result=super.setSelection(start,end);finishNativeEdit();return result;}
            @Override public boolean deleteSurroundingText(int before,int after){
                boolean empty=before>0 && after==0 && empty();operationDepth++;
                try {boolean result=super.deleteSurroundingText(before,after);emptyDelete(empty);finishNativeEdit();return result;}
                finally {operationDepth--;}
            }
            @Override public boolean deleteSurroundingTextInCodePoints(int before,int after){
                boolean empty=before>0 && after==0 && empty();operationDepth++;
                try {boolean result=super.deleteSurroundingTextInCodePoints(before,after);emptyDelete(empty);finishNativeEdit();return result;}
                finally {operationDepth--;}
            }
            @Override public boolean sendKeyEvent(KeyEvent event){
                // BaseInputConnection dispatches asynchronously. onKeyDown is the sole
                // empty-delete callback, so one IME key cannot delete twice remotely.
                return super.sendKeyEvent(event);
            }
            @Override public boolean performContextMenuAction(int id){boolean result=super.performContextMenuAction(id);finishNativeEdit();return result;}
            @Override public void closeConnection(){super.closeConnection();batches=0;scheduleEdit();}
        };
    }
}
