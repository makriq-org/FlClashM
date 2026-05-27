package com.follow.clashx.service;

import com.follow.clashx.service.IAckInterface;

interface IEventInterface {
    oneway void onEvent(in String id, in byte[] data, in boolean isSuccess, in IAckInterface ack);
}
