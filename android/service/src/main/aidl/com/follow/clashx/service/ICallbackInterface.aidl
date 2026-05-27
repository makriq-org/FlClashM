package com.follow.clashx.service;

import com.follow.clashx.service.IAckInterface;

interface ICallbackInterface {
    oneway void onResult(in byte[] data, in boolean isSuccess, in IAckInterface ack);
}
