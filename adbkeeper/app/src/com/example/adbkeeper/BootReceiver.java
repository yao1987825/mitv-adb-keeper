package com.example.adbkeeper;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) return;
        AdbHelper.init(context);
        AdbHelper.log("收到开机广播 BOOT_COMPLETED");
        AdbJobService.scheduleOnce(context.getApplicationContext(), 90000L);
        AdbJobService.schedulePeriodic(context.getApplicationContext());
    }
}
