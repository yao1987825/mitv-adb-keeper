package com.example.adbkeeper;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        AdbHelper.init(this);
        AdbJobService.schedulePeriodic(this);
        AdbJobService.scheduleOnce(this, 90000L);
        AdbHelper.log("应用已启动，注册任务完成");
        new Handler(getMainLooper()).postDelayed(new Runnable() {
            @Override
            public void run() {
                finish();
            }
        }, 5000);
    }
}
