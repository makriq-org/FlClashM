package com.follow.clashx.service;

// Pushed by the :remote StateHub on every run-state transition (and once on
// register, with the current snapshot). oneway so a slow/frozen :main can never
// block the service process's state machine.
oneway interface IStateCallback {
    void onStateChanged(String stateJson);
}
