package com.chekusu.sofatap.controller;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import java.util.ArrayList;
import java.util.Locale;

/** Foreground, user-started system dictation. Audio and recognition belong to the installed provider. */
final class DictationSession {
    interface Listener {
        void transcript(String text,boolean finalResult);
        void finished(boolean error);
    }
    private final Context context;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private SpeechRecognizer recognizer;
    private Listener listener;
    private int generation;
    private boolean active,stopping;
    DictationSession(Context context){this.context=context;}
    boolean available(){return SpeechRecognizer.isRecognitionAvailable(context);}
    boolean active(){return active;}
    void start(Listener next) {
        cancel();listener=next;active=true;stopping=false;
        final int current=++generation;
        try {
            recognizer=SpeechRecognizer.createSpeechRecognizer(context);
            recognizer.setRecognitionListener(new RecognitionListener() {
                public void onReadyForSpeech(Bundle p) { }
                public void onBeginningOfSpeech() { }
                public void onRmsChanged(float value) { }
                public void onBufferReceived(byte[] buffer) { }
                public void onEndOfSpeech() { if(current==generation)finishDeadline(current); }
                public void onError(int error) { if(current==generation)finish(error!=SpeechRecognizer.ERROR_NO_MATCH && error!=SpeechRecognizer.ERROR_SPEECH_TIMEOUT); }
                public void onResults(Bundle values) { receive(values,true,current); }
                public void onPartialResults(Bundle values) { receive(values,false,current); }
                public void onEvent(int type,Bundle values) { }
            });
            Intent intent=new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
            intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE,Locale.getDefault().toLanguageTag());
            intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,1);
            intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS,true);
            recognizer.startListening(intent);
            // Recording cannot remain active after a stalled provider.
            handler.postDelayed(()->{if(current==generation && active)stop();},60000);
        } catch(RuntimeException failure) { finish(true); }
    }
    private void receive(Bundle values,boolean last,int current) {
        if(current!=generation || !active)return;
        ArrayList<String> texts=values==null?null:values.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
        if(texts!=null && !texts.isEmpty() && listener!=null)listener.transcript(texts.get(0),last);
        if(last && current==generation)finish(false);
    }
    void stop() {
        if(!active || stopping)return;stopping=true;
        try {recognizer.stopListening();finishDeadline(generation);}catch(RuntimeException failure){finish(true);}
    }
    private void finishDeadline(int current){handler.postDelayed(()->{if(current==generation && active)finish(false);},5000);}
    private void finish(boolean error){Listener done=listener;cancel();if(done!=null)done.finished(error);}
    void cancel(){
        generation++;active=false;stopping=false;listener=null;handler.removeCallbacksAndMessages(null);
        if(recognizer!=null){SpeechRecognizer old=recognizer;recognizer=null;try{old.cancel();}finally{old.destroy();}}
    }
}
