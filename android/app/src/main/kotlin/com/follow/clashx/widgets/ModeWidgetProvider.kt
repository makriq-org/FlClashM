package com.follow.clashx.widgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.lifecycle.Observer
import com.follow.clashx.GlobalState
import com.follow.clashx.R
import com.follow.clashx.RunState

class ModeWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "ModeWidgetProvider"

        const val ACTION_TOGGLE = "com.follow.clashx.widget.ACTION_TOGGLE"
        const val ACTION_MODE_RULE = "com.follow.clashx.widget.ACTION_MODE_RULE"
        const val ACTION_MODE_GLOBAL = "com.follow.clashx.widget.ACTION_MODE_GLOBAL"
        const val ACTION_MODE_DIRECT = "com.follow.clashx.widget.ACTION_MODE_DIRECT"

        @Volatile
        private var observersAttached = false

        private val runStateObserver = Observer<RunState> { _ ->
            refreshAll()
        }
        private val modeObserver = Observer<String> { _ -> refreshAll() }
        private val globalModeEnabledObserver = Observer<Boolean> { _ -> refreshAll() }

        fun ensureObservers() {
            if (observersAttached) return
            synchronized(this) {
                if (observersAttached) return
                GlobalState.runState.observeForever(runStateObserver)
                GlobalState.currentMode.observeForever(modeObserver)
                GlobalState.globalModeEnabled.observeForever(globalModeEnabledObserver)
                observersAttached = true
            }
        }

        private fun refreshAll() {
            val ctx = com.follow.clashx.FlClashXApplication.getAppContext() ?: return
            val mgr = AppWidgetManager.getInstance(ctx) ?: return
            val component = ComponentName(ctx, ModeWidgetProvider::class.java)
            val ids = mgr.getAppWidgetIds(component)
            if (ids == null || ids.isEmpty()) return
            for (id in ids) {
                render(ctx, mgr, id)
            }
        }

        private fun render(context: Context, mgr: AppWidgetManager, widgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_mode)
            val runState = GlobalState.runState.value ?: RunState.STOP
            val mode = GlobalState.currentMode.value ?: "rule"

            applyMode(views, mode)
            views.setOnClickPendingIntent(R.id.widget_btn_rule, pending(context, ACTION_MODE_RULE))
            views.setOnClickPendingIntent(R.id.widget_btn_global, pending(context, ACTION_MODE_GLOBAL))
            views.setOnClickPendingIntent(R.id.widget_btn_direct, pending(context, ACTION_MODE_DIRECT))

            val globalEnabled = GlobalState.globalModeEnabled.value ?: true
            views.setViewVisibility(
                R.id.widget_mode_col,
                if (globalEnabled) View.VISIBLE else View.GONE,
            )

            val logo = when (runState) {
                RunState.START -> R.drawable.widget_logo_color
                else -> R.drawable.widget_logo_mono
            }
            views.setImageViewResource(R.id.widget_toggle, logo)
            views.setOnClickPendingIntent(R.id.widget_toggle, pending(context, ACTION_TOGGLE))

            mgr.updateAppWidget(widgetId, views)
        }

        private fun applyMode(views: RemoteViews, mode: String) {
            views.setInt(
                R.id.widget_btn_rule,
                "setBackgroundResource",
                if (mode == "rule") R.drawable.widget_mode_btn_active else R.drawable.widget_mode_btn_inactive,
            )
            views.setInt(
                R.id.widget_btn_global,
                "setBackgroundResource",
                if (mode == "global") R.drawable.widget_mode_btn_active else R.drawable.widget_mode_btn_inactive,
            )
            views.setInt(
                R.id.widget_btn_direct,
                "setBackgroundResource",
                if (mode == "direct") R.drawable.widget_mode_btn_active else R.drawable.widget_mode_btn_inactive,
            )
            val activeTxt = 0xFF000000.toInt()
            val inactiveTxt = 0xFFFFFFFF.toInt()
            views.setTextColor(R.id.widget_btn_rule, if (mode == "rule") activeTxt else inactiveTxt)
            views.setTextColor(R.id.widget_btn_global, if (mode == "global") activeTxt else inactiveTxt)
            views.setTextColor(R.id.widget_btn_direct, if (mode == "direct") activeTxt else inactiveTxt)
        }

        private fun pending(context: Context, action: String): PendingIntent {
            val intent = Intent(context, ModeWidgetProvider::class.java).apply {
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
        Log.d(TAG, "onReceive: ${intent.action}")
        ensureObservers()
        when (intent.action) {
            ACTION_TOGGLE -> {
                if (GlobalState.runStateFlow.value == RunState.PENDING) {
                    Log.d(TAG, "Ignoring toggle — operation in progress")
                    return
                }
                GlobalState.handleToggle()
            }
            ACTION_MODE_RULE -> GlobalState.handleChangeMode("rule")
            ACTION_MODE_GLOBAL -> GlobalState.handleChangeMode("global")
            ACTION_MODE_DIRECT -> GlobalState.handleChangeMode("direct")
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
                GlobalState.currentMode.removeObserver(modeObserver)
                GlobalState.globalModeEnabled.removeObserver(globalModeEnabledObserver)
                observersAttached = false
            }
        }
    }
}
