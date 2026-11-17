package com.example.adbkeeper;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;

public class AdbJobService extends JobService {
    public static final int JOB_ID = 1001;          // 周期任务（兜底）
    public static final int JOB_ID_NEXT = 1002;     // 链式单次任务（快速通道）
    private static final long CHAIN_DELAY_MS = 30000L;   // 链式间隔 30 秒
    private static final long PERIODIC_MS = 5 * 60 * 1000L;
    private static final long PERIODIC_RENEW_MS = 10 * 60 * 1000L; // 周期任务最多 10 分钟重排一次

    /** 上次重排周期任务的时间（避免每次运行都重排，把 5 分钟计时器反复重置） */
    private static long lastPeriodicRenew = 0L;

    /** 注册随系统持久化的周期任务（重启后系统自动恢复） */
    public static void schedulePeriodic(Context context) {
        try {
            JobScheduler js = (JobScheduler) context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            JobInfo job = new JobInfo.Builder(JOB_ID, new ComponentName(context, AdbJobService.class))
                    .setPersisted(true)
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_NONE)
                    .setPeriodic(PERIODIC_MS)
                    .build();
            js.schedule(job);
            lastPeriodicRenew = System.currentTimeMillis();
            AdbHelper.log("周期任务已注册(5分钟)");
        } catch (Exception e) {
            AdbHelper.log("注册周期任务失败: " + e);
        }
    }

    /** 注册 N 毫秒后执行的单次持久化任务（链式续期用） */
    public static void scheduleOnce(Context context, long delayMs) {
        try {
            JobScheduler js = (JobScheduler) context.getSystemService(Context.JOB_SCHEDULER_SERVICE);
            if (js == null) return;
            JobInfo job = new JobInfo.Builder(JOB_ID_NEXT, new ComponentName(context, AdbJobService.class))
                    .setPersisted(true)
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_NONE)
                    .setMinimumLatency(delayMs)
                    .setOverrideDeadline(delayMs + 60000)
                    .build();
            js.schedule(job);
        } catch (Exception e) {
            AdbHelper.log("注册单次任务失败: " + e);
        }
    }

    /**
     * 确保兜底用的周期任务存在。
     * 注意：不能每次运行都重排它——那会把 5 分钟计时器反复重置，
     * 导致这个"兜底"永远等不到 5 分钟而形同虚设（v1.6 修正）。
     */
    private static void ensurePeriodic(Context context) {
        long now = System.currentTimeMillis();
        if (now - lastPeriodicRenew >= PERIODIC_RENEW_MS) {
            schedulePeriodic(context);
        }
    }

    @Override
    public boolean onStartJob(JobParameters params) {
        // ① 关键：先排下一次任务，再干活。
        //    万一本进程在执行过程中被系统回收，链也不会断（v1.6 修正）。
        scheduleOnce(this, CHAIN_DELAY_MS);
        ensurePeriodic(this);

        final JobParameters p = params;
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    AdbHelper.ensureAdb(AdbJobService.this);
                } catch (Exception e) {
                    AdbHelper.log("任务执行异常: " + e);
                } finally {
                    try { jobFinished(p, false); } catch (Exception e) { }
                }
            }
        }).start();
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters params) {
        // 被系统中断时立刻重排，保证链条不断
        scheduleOnce(this, CHAIN_DELAY_MS);
        return true;
    }
}
