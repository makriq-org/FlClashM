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

    void updateDns(in String dns);

    String getAndroidVpnOptions();

    String getCurrentProfileName();

    String getRunTime();

    String getTraffic();

    String getTotalTraffic();

    void startRuntimeNode(in String nodeId,
                         in String executablePath,
                         in String workingDirectory,
                         in List<String> arguments,
                         in IResultInterface result);

    void stopRuntimeNode(in String nodeId, in IResultInterface result);

    long getRuntimeNodeRunTime(in String nodeId);

    String getRuntimeNodeLastError(in String nodeId);

    void startListener();

    void stopListener();
}
