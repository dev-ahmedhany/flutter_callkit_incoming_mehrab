package com.example.flutter_callkit_incoming_example

import android.os.Bundle
import com.hiennv.flutter_callkit_incoming.CallkitEventCallback
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity(){

    private var callkitEventCallback = object: CallkitEventCallback{
        override fun onCallEvent(event: CallkitEventCallback.CallEvent, callData: Bundle) {
            when (event) {
                CallkitEventCallback.CallEvent.INCOMING -> {
                    // The ring is on screen, whichever path showed it
                }
                CallkitEventCallback.CallEvent.ACCEPT -> {
                    // Do something with answer
                }
                CallkitEventCallback.CallEvent.DECLINE -> {
                    // Do something with decline
                }
                CallkitEventCallback.CallEvent.TIMEOUT -> {
                    // The ring ran out unanswered
                }
                CallkitEventCallback.CallEvent.ENDED -> {
                    // The call ended, or its ring was dismissed elsewhere
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FlutterCallkitIncomingPlugin.registerEventCallback(callkitEventCallback)
    }

    override fun onDestroy() {
        FlutterCallkitIncomingPlugin.unregisterEventCallback(callkitEventCallback)
        super.onDestroy()
    }


}
