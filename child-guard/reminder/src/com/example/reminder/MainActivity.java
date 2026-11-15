package com.example.reminder;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.view.KeyEvent;
import android.view.Window;
import android.view.WindowManager;
import android.widget.TextView;

public class MainActivity extends Activity {

    private TextView labelView;
    private TextView countView;
    private TextView tipView;
    private final Handler handler = new Handler();

    /** 剩余休息秒数；<0 表示"今天不能再看了" */
    private long remainSec = 0;
    /** 倒计时结束的真实时间戳，用墙钟计算，息屏/卡顿都不会走偏 */
    private long endTime = 0;
    private boolean closing = false;
    /** 夜间禁止时段（20:00~次日08:00）模式 */
    private boolean nightMode = false;

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            render();
            handler.postDelayed(this, 1000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);
        // 注意：不再设置 FLAG_KEEP_SCREEN_ON —— 提醒页不应阻止电视熄屏，
        // 否则看起来像"整个电视被锁死"。
        setContentView(R.layout.activity_main);

        labelView = (TextView) findViewById(R.id.label);
        countView = (TextView) findViewById(R.id.countdown);
        tipView = (TextView) findViewById(R.id.tip);

        applyIntent(getIntent());
        handler.postDelayed(tick, 1000);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        applyIntent(intent);
    }

    /** 守护脚本通过 am start --ei remain_sec N 传入剩余秒数 */
    private void applyIntent(Intent intent) {
        if (intent == null) {
            return;
        }
        // 注意：守护脚本用 --ei 传的是 int，必须用 getIntExtra 读取
        remainSec = intent.getIntExtra("remain_sec", -1);
        nightMode = intent.getIntExtra("night_mode", 0) == 1;
        endTime = System.currentTimeMillis() + remainSec * 1000L;
        closing = false;
        render();
    }

    private void render() {
        if (nightMode) {
            // 夜间禁止时段：显示距离允许时段（早上8点）的倒计时
            long left2 = remainSec < 0 ? 0 : (endTime - System.currentTimeMillis()) / 1000;
            if (left2 < 0) left2 = 0;
            labelView.setText("现在暂停观看");
            countView.setText(String.format("%02d:%02d", left2 / 60, left2 % 60));
            tipView.setText("晚上 8 点到早上 8 点是休息时间，早点睡哦");
            return;
        }
        if (remainSec < 0) {
            labelView.setText("今天不能再看啦");
            countView.setText("明天见");
            tipView.setText("先去喝口水、看看远处吧");
            return;
        }
        if (remainSec == 0) {
            if (!closing) {
                closing = true;
                labelView.setText("休息结束");
                countView.setText("可以继续看啦！");
                tipView.setText("");
                handler.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        finish();
                    }
                }, 3000);
            }
            return;
        }
        long left = (endTime - System.currentTimeMillis()) / 1000;
        if (left < 0) {
            left = 0;
        }
        long m = left / 60;
        long s = left % 60;
        labelView.setText("还需休息");
        countView.setText(String.format("%02d:%02d", m, s));
        tipView.setText("先去喝口水、看看远处吧");
    }

    @Override
    protected void onPause() {
        super.onPause();
        handler.removeCallbacks(tick);
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.removeCallbacks(tick);
        handler.postDelayed(tick, 1000);
    }

    /**
     * v1.3 修正：允许按返回键退出提醒页。
     * 之前这里故意不退出，会让整个电视看起来被锁死；
     * 现在提醒页只是"提醒"，关掉后仍可正常使用电视其它功能，
     * 只有再打开那 3 个受控App 时才会被再次拦下。
     */
    @Override
    public void onBackPressed() {
        finish();
    }
}
