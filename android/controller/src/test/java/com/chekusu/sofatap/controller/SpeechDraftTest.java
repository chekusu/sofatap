package com.chekusu.sofatap.controller;
import org.junit.Test;
import static org.junit.Assert.*;
public final class SpeechDraftTest {
    @Test public void correctedHypothesesReplaceInitialSelectionAndPreserveSuffix(){
        SpeechDraft base=new SpeechDraft("前缀 OLD 后缀",3,3);
        assertEquals("前缀 你好 后缀",base.replacing("你好").text);
        SpeechDraft finalResult=base.replacing("你好世界 🎮");
        assertEquals("前缀 你好世界 🎮 后缀",finalResult.text);
        assertEquals(10,finalResult.start);assertEquals(0,finalResult.length);
    }
    @Test public void supplementarySelectionIsNotSplit(){
        assertEquals("A电视B",new SpeechDraft("A🎮B",1,2).replacing("电视").text);
        assertThrows(IllegalArgumentException.class,()->new SpeechDraft("A🎮B",2,0));
    }
    @Test public void invalidOrOversizedResultsAreRejected(){
        SpeechDraft base=new SpeechDraft("prefix",6,0);
        assertThrows(IllegalArgumentException.class,()->base.replacing("x".repeat(16000)));
        assertThrows(IllegalArgumentException.class,()->base.replacing("\ud800"));
    }
}
