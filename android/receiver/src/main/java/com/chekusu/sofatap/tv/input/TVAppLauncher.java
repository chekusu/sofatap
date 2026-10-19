package com.chekusu.sofatap.tv.input;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import com.chekusu.sofatap.tv.TVAppShortcuts;
import java.util.function.BooleanSupplier;

/** Uses the explicitly enabled AccessibilityService's context for Android background launches. */
final class TVAppLauncher implements TVAppShortcuts.Launcher {
    private final Context context;
    TVAppLauncher(Context context) { this.context = context; }

    private Intent intent(String packageName) {
        PackageManager packages = context.getPackageManager();
        Intent launch = packages.getLeanbackLaunchIntentForPackage(packageName);
        if (launch == null) launch = packages.getLaunchIntentForPackage(packageName);
        if (launch == null || launch.getComponent() == null
                || !packageName.equals(launch.getComponent().getPackageName())) return null;
        try {
            ActivityInfo activity = packages.getActivityInfo(launch.getComponent(), 0);
            if (!activity.exported || !activity.enabled || !activity.applicationInfo.enabled) return null;
        } catch (PackageManager.NameNotFoundException unavailable) { return null; }
        return launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    }

    @Override public boolean available(String packageName) { return intent(packageName) != null; }

    @Override public boolean launch(String packageName, BooleanSupplier current) {
        Intent launch = intent(packageName);
        if (launch == null || !current.getAsBoolean()) return false;
        context.startActivity(launch);
        return true;
    }
}
