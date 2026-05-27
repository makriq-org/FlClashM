package com.follow.clashx.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.RemoteViews
import androidx.lifecycle.Observer
import com.follow.clashx.GlobalState
import com.follow.clashx.R
import com.follow.clashx.RunState

class OnOffWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "OnOffWidgetProvider"

        const val ACTION_TOGGLE = "com.follow.clashx.widget.ACTION_ONOFF_TOGGLE"

        @Volatile
        private var observersAttached = false

        private val runStateObserver = Observer<RunState> { _ -> refreshAll() }

        fun ensureObservers() {
            if (observersAttached) return
            synchronized(this) {
                if (observersAttached) return
                GlobalState.runState.observeForever(runStateObserver)
                observersAttached = true
            }
        }

        private fun refreshAll() {
            val ctx = com.follow.clashx.FlClashXApplication.getAppContext() ?: return
            val mgr = AppWidgetManager.getInstance(ctx) ?: return
            val component = ComponentName(ctx, OnOffWidgetProvider::class.java)
            val ids = mgr.getAppWidgetIds(component)
            if (ids == null || ids.isEmpty()) return
            for (id in ids) {
                render(ctx, mgr, id)
            }
        }

        private fun render(context: Context, mgr: AppWidgetManager, widgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_on_off)
            val runState = GlobalState.runState.value ?: RunState.STOP
            val logo = if (runState == RunState.START) R.drawable.widget_logo_color else R.drawable.widget_logo_mono
            views.setImageViewResource(R.id.widget_on_off, logo)
            views.setOnClickPendingIntent(R.id.widget_on_off, pending(context, ACTION_TOGGLE))
            mgr.updateAppWidget(widgetId, views)
        }

        private fun pending(context: Context, action: String): PendingIntent {
            val intent = Intent(context, OnOffWidgetProvider::class.java).apply {
                this.action = action
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            return PendingIntent.getBroadcast(context, action.hashCode(), intent, flags)
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        Log.d(TAG, "onUpdate: ${appWidgetIds.joinToString()}")
        ensureObservers()
        GlobalState.syncStatus()
        for (id in appWidgetIds) {
            render(context, appWidgetManager, id)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        ensureObservers()
        if (intent.action == ACTION_TOGGLE) {
            if (GlobalState.runStateFlow.value == RunState.PENDING) {
                Log.d(TAG, "Ignoring toggle — operation in progress")
                return
            }
            GlobalState.handleToggle()
        }
    }

    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        Log.d(TAG, "onEnabled")
        ensureObservers()
        GlobalState.syncStatus()
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        Log.d(TAG, "onDisabled")
        synchronized(Companion) {
            if (observersAttached) {
                GlobalState.runState.removeObserver(runStateObserver)
                observersAttached = false
            }
        }
    }
}
