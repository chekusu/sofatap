package com.chekusu.sofatap.controller;

/** Every recognition hypothesis replaces the same initial selection, never the previous hypothesis. */
final class SpeechDraft {
    final String text;
    final int start,length;
    SpeechDraft(String text,int start,int length) {
        if(text==null || start<0 || length<0 || start>text.length() || length>text.length()-start ||
            !boundary(text,start) || !boundary(text,start+length))throw new IllegalArgumentException("Invalid selection");
        this.text=text;this.start=start;this.length=length;
    }
    SpeechDraft replacing(String transcript) {
        if(transcript==null || !Pairing.validUnicode(transcript))throw new IllegalArgumentException("Invalid transcript");
        String result=text.substring(0,start)+transcript+text.substring(start+length);
        if(result.length()>16000)throw new IllegalArgumentException("Text is too long");
        return new SpeechDraft(result,start+transcript.length(),0);
    }
    private static boolean boundary(String text,int index) {
        return index==0 || index==text.length() || !Character.isHighSurrogate(text.charAt(index-1)) || !Character.isLowSurrogate(text.charAt(index));
    }
}
