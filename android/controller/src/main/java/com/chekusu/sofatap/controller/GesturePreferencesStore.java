package com.chekusu.sofatap.controller;

import android.content.Context;
import android.content.SharedPreferences;
import org.json.JSONObject;

/** Non-sensitive, local-only profiles; never changes a paired receiver's permissions. */
public final class GesturePreferencesStore {
    private final SharedPreferences preferences;
    public GesturePreferencesStore(Context context){preferences=context.getSharedPreferences("sofatap.gesturePreferences.v1",Context.MODE_PRIVATE);}
    public GestureConfiguration load(GestureConfiguration.Target target) {
        try {
            JSONObject value=new JSONObject(preferences.getString("profiles","{}"));
            if(!(value.opt("schemaVersion") instanceof Number version)||version.doubleValue()!=1)return new GestureConfiguration(target);
            return GestureConfiguration.fromJson(value.optJSONObject(target.name()),target);
        } catch(Exception invalid){return new GestureConfiguration(target);}
    }
    public boolean save(GestureConfiguration configuration) {
        try {
            JSONObject value=new JSONObject().put("schemaVersion",1);
            for(GestureConfiguration.Target target:GestureConfiguration.Target.values())
                value.put(target.name(),(configuration.target==target?configuration:load(target)).toJson());
            return preferences.edit().putString("profiles",value.toString()).commit();
        } catch(Exception invalid){return false;}
    }
}
