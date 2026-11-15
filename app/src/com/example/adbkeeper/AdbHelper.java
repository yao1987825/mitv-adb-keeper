package com.example.adbkeeper;

import android.content.Context;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.Socket;

public class AdbHelper {
    private static final String TAG = "AdbKeeper";
    private static final String TV_SERVICE = "TvService";
    private static final String ITV_SERVICE = "mitv.internal.ITvService";
    private static final int CMD_ENABLE_ADB = 4004;

    private static Context appContext;

    public static void init(Context ctx) {
        appContext = ctx.getApplicationContext();
    }

    /** 写日志到应用目录，方便用 run-as 读取 */
    public static void log(String msg) {
        Log.i(TAG, msg);
        try {
            if (appContext == null) return;
            File f = new File(appContext.getFilesDir(), "adbkeeper.log");
            FileOutputStream fos = new FileOutputStream(f, true);
            fos.write((System.currentTimeMillis() + " " + msg + "\n").getBytes("UTF-8"));
            fos.close();
        } catch (Exception e) { }
    }

    /** 探测本机 5555 端口，判断 ADB 网络调试是否真的可用 */
    public static boolean isAdbPortOpen() {
        Socket socket = new Socket();
        try {
            socket.connect(new InetSocketAddress("127.0.0.1", 5555), 1500);
            return true;
        } catch (IOException e) {
            return false;
        } finally {
            try { socket.close(); } catch (IOException e) { }
        }
    }

    /** 调用小米系统服务 TvService 的 4004 命令：1=开启 ADB，0=关闭 ADB */
    public static boolean callTvService(int action) {
        try {
            Class<?> smClass = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) smClass.getMethod("getService", String.class).invoke(null, TV_SERVICE);
            if (binder == null) {
                log("TvService binder is null");
                return false;
            }
            Parcel data = Parcel.obtain();
            data.writeInterfaceToken(ITV_SERVICE);
            data.writeInt(action);
            Parcel reply = Parcel.obtain();
            boolean ok = binder.transact(CMD_ENABLE_ADB, data, reply, 0);
            data.recycle();
            reply.recycle();
            log("callTvService(" + action + ") ok=" + ok);
            return ok;
        } catch (Exception e) {
            log("callTvService(" + action + ") failed: " + e);
            return false;
        }
    }

    /** 先关再开，强制 adbd 重新启动并监听 5555 */
    public static void toggleAdb() {
        callTvService(0);
        try { Thread.sleep(2000); } catch (InterruptedException e) { }
        callTvService(1);
    }

    /** 检查并按需修复：端口未开则调用系统服务重新开启 */
    public static boolean ensureAdb(Context context) {
        init(context);
        if (isAdbPortOpen()) {
            log("ADB 端口正常，无需处理");
            return true;
        }
        log("ADB 端口未开启，调用系统服务重新开启...");
        callTvService(1);
        try { Thread.sleep(3000); } catch (InterruptedException e) { }
        boolean ok = isAdbPortOpen();
        log("处理后端口状态: " + (ok ? "OPEN" : "CLOSED"));
        return ok;
    }
}
