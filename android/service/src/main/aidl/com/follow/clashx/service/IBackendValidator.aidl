package com.follow.clashx.service;
import com.follow.clashx.service.ICallbackInterface;

// Private same-UID host. Configuration bytes stay in private shared storage.
interface IBackendValidator {
    int getPid();
    oneway void validate(String path, ICallbackInterface callback);
}
