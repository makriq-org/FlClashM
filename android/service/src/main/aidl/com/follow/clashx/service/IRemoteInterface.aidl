package com.follow.clashx.service;

import com.follow.clashx.service.ICallbackInterface;
import com.follow.clashx.service.IEventInterface;
import com.follow.clashx.service.IResultInterface;
import com.follow.clashx.service.IStateCallback;
import com.follow.clashx.service.IVoidInterface;
import com.follow.clashx.service.models.NotificationParams;
import com.follow.clashx.service.models.VpnOptions;

interface IRemoteInterface {
    void invokeAction(in String data, in ICallbackInterface callback);

    void quickStart(in String initParamsString,
                    in String paramsString,
                    in String stateParamsString,
                    in ICallbackInterface callback,
                    in IVoidInterface onStarted);

    void updateNotificationParams(in NotificationParams params);

    void startService(in VpnOptions options, in long runTime, in IResultInterface result);

    void stopService(in IResultInterface result);

    void setEventListener(in IEventInterface event);

    // Run-state ownership (StateHub): register delivers the current snapshot
    // immediately, then every transition. getServiceState is the pull fallback
    // for consumers that only need a one-shot answer.
    void registerStateCallback(in IStateCallback callback);

    void unregisterStateCallback(in IStateCallback callback);

    String getServiceState();

    void setState(in String state);

    void setCrashlytics(boolean enable);

    void updateDns(in String dns);

    String getAndroidVpnOptions();

    String getAppliedAndroidVpnOptions();

    String getCurrentProfileName();

    String getRunTime();

    String getTraffic();

    String getTotalTraffic();

    void applyRuntimeNodePlan(in String plan, in ICallbackInterface callback);

    String getRuntimeNodePlanState();

    void stopRuntimeNodePlan(in IResultInterface result);

    void probeRuntimeNode(in String node, in IResultInterface result);

    void probeRuntimeNodes(in String request, in IResultInterface result);

    void attachRuntimeNodeClient();

    void detachRuntimeNodeClient();

    void startListener();

    void stopListener();
}
