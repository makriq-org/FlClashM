package com.follow.clashx.service;
import com.follow.clashx.service.ICallbackInterface;
import com.follow.clashx.service.IEventInterface;
import com.follow.clashx.service.IStateCallback;
import com.follow.clashx.service.models.NotificationParams;

interface IRemoteInterface {
    void invokeAction(in String data, in ICallbackInterface callback);
    void setEventListener(in IEventInterface event);
    void registerStateCallback(in IStateCallback callback);
    void unregisterStateCallback(in IStateCallback callback);
    String getServiceState();
    String getAndroidVpnOptions();
    String getAppliedAndroidVpnOptions();
    String getCurrentProfileName();
    String getRunTime();
    String getTraffic();
    String getTotalTraffic();
    void updateNotificationParams(in NotificationParams params);
}
