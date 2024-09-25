package ca.psiphon.conduit.nativemodule;

import android.app.ActivityManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.RemoteException;

import androidx.core.content.ContextCompat;

import com.jakewharton.rxrelay2.BehaviorRelay;
import com.jakewharton.rxrelay2.Relay;

import java.util.List;

import ca.psiphon.conduit.nativemodule.logging.MyLog;
import ca.psiphon.conduit.nativemodule.stats.ProxyActivityStats;
import io.reactivex.BackpressureStrategy;
import io.reactivex.Flowable;

public class ConduitServiceInteractor {
    public static final String MAX_CLIENTS = "maxClients";
    public static final String LIMIT_UPSTREAM_BYTES = "limitUpstreamBytesPerSecond";
    public static final String LIMIT_DOWNSTREAM_BYTES = "limitDownstreamBytesPerSecond";
    public static final String PROXY_PRIVATE_KEY = "proxyPrivateKey";

    public static final String SERVICE_STARTING_BROADCAST_PERMISSION = "ca.psiphon.conduit.nativemodule.SERVICE_STARTING_BROADCAST_PERMISSION";
    public static final String SERVICE_STARTING_BROADCAST_INTENT = "ca.psiphon.conduit.nativemodule.SERVICE_STARTING_BROADCAST_INTENT";
    private static final String TAG = ConduitServiceInteractor.class.getSimpleName();
    private final Relay<ProxyState> proxyStateRelay = BehaviorRelay.<ProxyState>create().toSerialized();
    private final Relay<ProxyActivityStats> proxyActivityStatsRelay = BehaviorRelay.<ProxyActivityStats>create()
            .toSerialized();
    private final IConduitClientCallback clientCallback = new IConduitClientCallback.Stub() {
        @Override
        public void onProxyStateUpdated(Bundle proxyStateBundle) {
            ProxyState proxyState = ProxyState.fromBundle(proxyStateBundle);
            proxyStateRelay.accept(proxyState);
        }

        @Override
        public void onProxyActivityStatsUpdated(Bundle proxyActivityStatsBundle) {
            ProxyActivityStats proxyActivityStats = ProxyActivityStats.fromBundle(proxyActivityStatsBundle);
            proxyActivityStatsRelay.accept(proxyActivityStats);
        }

        @Override
        public void ping() {
            // Just a ping to verify the client is alive, do nothing
        }
    };
    private final BroadcastReceiver broadcastReceiver;
    private IConduitService conduitService;
    private final ServiceConnection serviceConnection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder service) {
            conduitService = IConduitService.Stub.asInterface(service);

            try {
                conduitService.registerClient(clientCallback);
            } catch (RemoteException e) {
                MyLog.e(TAG, "Failed to register client" + e);
            }
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            conduitService = null;
            proxyStateRelay.accept(ProxyState.stopped());
            isServiceBound = false;
        }
    };
    private boolean isStopped = true;
    private boolean isServiceBound = false;

    public ConduitServiceInteractor(Context context) {
        IntentFilter intentFilter = new IntentFilter(SERVICE_STARTING_BROADCAST_INTENT);
        this.broadcastReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (!isStopped) {
                    bindService(context, new Intent(context, ConduitService.class));
                }
            }
        };
        // Register the broadcast receiver with a custom permission to make sure the broadcast is our own.
        // The permission is defined in the manifest with the signature protection level.
        // Note that we are registering the receiver with the exported flag set to true to be able to receive the broadcast
        // from the service running in a different process.
        ContextCompat.registerReceiver(context, broadcastReceiver, intentFilter, SERVICE_STARTING_BROADCAST_PERMISSION,
                null, ContextCompat.RECEIVER_EXPORTED);

        proxyStateRelay.accept(ProxyState.unknown());
    }

    public void toggleInProxy(Context context, int maxClients, int limitUpstreamBytesPerSecond,
            int limitDownstreamBytesPerSecond, String privateKey) {
        Intent intent = new Intent(context, ConduitService.class);
        intent.setAction(ConduitService.INTENT_ACTION_TOGGLE_IN_PROXY);

        // Add parameters to the intent using the keys from ConduitServiceParameters
        intent.putExtra(MAX_CLIENTS, maxClients);
        intent.putExtra(LIMIT_UPSTREAM_BYTES, limitUpstreamBytesPerSecond);
        intent.putExtra(LIMIT_DOWNSTREAM_BYTES, limitDownstreamBytesPerSecond);
        intent.putExtra(PROXY_PRIVATE_KEY, privateKey);

        // Always start the service and let it handle the logic in onStartCommand
        ContextCompat.startForegroundService(context, intent);
    }

    public void paramsChanged(Context context, int maxClients, int limitUpstreamBytesPerSecond,
            int limitDownstreamBytesPerSecond, String privateKey) {
        Intent intent = new Intent(context, ConduitService.class);
        intent.setAction(ConduitService.INTENT_ACTION_PARAMS_CHANGED);

        // Add parameters to the intent using the keys from ConduitServiceParameters
        intent.putExtra(MAX_CLIENTS, maxClients);
        intent.putExtra(LIMIT_UPSTREAM_BYTES, limitUpstreamBytesPerSecond);
        intent.putExtra(LIMIT_DOWNSTREAM_BYTES, limitDownstreamBytesPerSecond);
        intent.putExtra(PROXY_PRIVATE_KEY, privateKey);

        // Start the service to handle the paramsChanged action
        ContextCompat.startForegroundService(context, intent);
    }

    public void onStart(Context context) {
        isStopped = false;
        if (isServiceRunning(context)) {
            bindService(context, new Intent(context, ConduitService.class));
        } else {
            proxyStateRelay.accept(ProxyState.stopped());
        }
    }

    public void onStop(Context context) {
        isStopped = true;
        proxyStateRelay.accept(ProxyState.unknown());

        if (conduitService != null) {
            try {
                conduitService.unregisterClient(clientCallback);
            } catch (RemoteException e) {
                MyLog.e(TAG, "Failed to unregister client" + e);
            }
        }
        if (isServiceBound) {
            context.unbindService(serviceConnection);
            isServiceBound = false; // Reset the flag
        }
        conduitService = null;
    }

    public void onDestroy(Context context) {
        context.unregisterReceiver(broadcastReceiver);
    }

    public Flowable<ProxyState> proxyStateFlowable() {
        return proxyStateRelay
                .distinctUntilChanged()
                .toFlowable(BackpressureStrategy.LATEST);
    }

    public Flowable<ProxyActivityStats> proxyActivityStatsFlowable() {
        return proxyActivityStatsRelay
                .distinctUntilChanged()
                .toFlowable(BackpressureStrategy.LATEST);
    }

    private void bindService(Context context, Intent intent) {
        if (!isServiceBound) { // Check if the service is already bound
            isServiceBound = true; // Set the flag as soon as we call bindService
            context.bindService(intent, serviceConnection, 0);
        }
    }

    // Method to check if the service is running
    public boolean isServiceRunning(Context context) {
        ActivityManager activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        if (activityManager == null) {
            return false;
        }

        List<ActivityManager.RunningServiceInfo> services = activityManager.getRunningServices(Integer.MAX_VALUE);
        for (ActivityManager.RunningServiceInfo serviceInfo : services) {
            if (ConduitService.class.getName().equals(serviceInfo.service.getClassName())) {
                return true;
            }
        }
        return false;
    }
}