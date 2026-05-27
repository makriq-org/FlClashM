package com.follow.clashx.service;

import com.follow.clashx.service.ICallbackInterface;
import com.follow.clashx.service.IEventInterface;
import com.follow.clashx.service.IResultInterface;
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

    void setState(in String state);

    void updateDns(in String dns);

    String getAndroidVpnOptions();

    String getCurrentProfileName();

    String getRunTime();

    String getTraffic();

    String getTotalTraffic();

    void startListener();

    void stopListener();
}
