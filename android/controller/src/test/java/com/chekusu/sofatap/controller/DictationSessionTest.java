package com.chekusu.sofatap.controller;

import org.junit.Test;
import static org.junit.Assert.*;

public final class DictationSessionTest {
    @Test public void keepsTheAvailableSystemProviderWithoutProbingAnotherProvider(){
        assertEquals(DictationSession.Backend.SYSTEM,DictationSession.selectBackend(36,new DictationSession.Availability(){
            public boolean system(){return true;}
            public boolean onDevice(){throw new AssertionError("The configured provider must keep precedence");}
        }));
    }
    @Test public void onDeviceOnlyPhonesStillHaveDictationFromApi31(){
        assertEquals(DictationSession.Backend.ON_DEVICE,DictationSession.selectBackend(31,available(false,true)));
        assertEquals(DictationSession.Backend.ON_DEVICE,DictationSession.selectBackend(36,available(false,true)));
    }
    @Test public void olderPhonesNeverCallTheApi31AvailabilityProbe(){
        for(int sdk:new int[]{26,30})assertEquals(DictationSession.Backend.NONE,DictationSession.selectBackend(sdk,new DictationSession.Availability(){
            public boolean system(){return false;}
            public boolean onDevice(){throw new AssertionError("API 31 probe called on an older phone");}
        }));
    }
    @Test public void unavailableServicesSelectKeyboardFallback(){
        assertEquals(DictationSession.Backend.NONE,DictationSession.selectBackend(36,available(false,false)));
    }
    @Test public void failedSystemProbeCanStillUseOnDeviceRecognition(){
        assertEquals(DictationSession.Backend.ON_DEVICE,DictationSession.selectBackend(36,new DictationSession.Availability(){
            public boolean system(){throw new SecurityException("Provider not exposed");}
            public boolean onDevice(){return true;}
        }));
    }
    @Test public void failedProbesSelectKeyboardFallbackWithoutCrashing(){
        assertEquals(DictationSession.Backend.NONE,DictationSession.selectBackend(36,new DictationSession.Availability(){
            public boolean system(){throw new IllegalStateException("Service unavailable");}
            public boolean onDevice(){throw new SecurityException("Provider not exposed");}
        }));
    }
    private static DictationSession.Availability available(boolean system,boolean onDevice){
        return new DictationSession.Availability(){
            public boolean system(){return system;}
            public boolean onDevice(){return onDevice;}
        };
    }
}
