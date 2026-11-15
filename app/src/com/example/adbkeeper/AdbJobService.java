package com.example.adbkeeper;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;

public class AdbJobService extends JobService {
    public static final int JOB_ID = 1001;
    public static final int JOB_ID_NEXT = 1002;
    private static final long CHAIN_DELAY_MS = 60000L;

    /** 注册随系统持久化的周期任务（重启后系统自动恢复） */
    public static void schedulePeriodic(Context context) {
        try {
            JobScheduler js = (JobScheduler) context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(context, AdbJobService.class))
                    .setPersisted(true)
                    .setPeriodic(5 * 60 * 1000L)
                    .build();
            js.schedule(job);
            AdbHelper.log("周期任务已注册(5分钟)");
        } catch (Exception e) {
            AdbHelper.log("注册周期任务失败: " + e);
        }
    }

    /** 注册 N 秒后执行的单次持久化任务 */
    public static void scheduleOnce(Context context, long delayMs) {
        try {
            JobScheduler js = (JobScheduler) context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            JobInfo job = new JobInfo.Builder(JOB_ID_NEXT, new ComponentName(context, AdbJobService.class))
                    .setPersisted(true)
                    .setMinimumLatency(delayMs)
                    .setOverrideDeadline(delayMs + 60000)
                    .build();
            js.schedule(job);
        } catch (Exception e) {
            AdbHelper.log("注册单次任务失败: " + e);
        }
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    AdbHelper.ensureAdb(AdbJobService.this);
                } catch (Exception e) {
                    AdbHelper.log("任务执行异常: " + e);
                }
                // 链式续期：60 秒后再检查一次（系统会在重启后自动恢复该任务）
                scheduleOnce(AdbJobService.this, CHAIN_DELAY_MS);
                jobFinished(params, false);
            }
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        return true;
    }
}
