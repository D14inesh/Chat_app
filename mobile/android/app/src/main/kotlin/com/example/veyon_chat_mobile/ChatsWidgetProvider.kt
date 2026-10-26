package com.example.veyon_chat_mobile

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen widget: unread chats at a glance (name + unread count, never
 * message text — it's visible on the home screen). The app writes the data
 * (see "updateWidget" in MainActivity); tapping a row opens that chat.
 */
class ChatsWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { render(context, manager, it) }
    }

    companion object {
        const val PREFS = "veyon_widget"
        const val EXTRA_CHAT = "veyon_open_chat"
        private val ROWS = listOf(
            Triple(R.id.row1, R.id.name1, R.id.count1),
            Triple(R.id.row2, R.id.name2, R.id.count2),
            Triple(R.id.row3, R.id.name3, R.id.count3),
            Triple(R.id.row4, R.id.name4, R.id.count4),
        )

        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            manager.getAppWidgetIds(ComponentName(context, ChatsWidgetProvider::class.java)).forEach { render(context, manager, it) }
        }

        private fun openIntent(context: Context, chatId: String?, code: Int): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                action = if (chatId != null) "veyon.OPEN_CHAT.$chatId" else Intent.ACTION_MAIN
                if (chatId != null) putExtra(EXTRA_CHAT, chatId)
            }
            return PendingIntent.getActivity(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }

        private fun render(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_chats)
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("data", null)
            val data = try { if (raw != null) JSONObject(raw) else null } catch (e: Exception) { null }
            val signedIn = data?.optBoolean("signedIn", false) ?: false
            val items = data?.optJSONArray("items")
            val total = data?.optInt("total", 0) ?: 0

            views.setOnClickPendingIntent(R.id.widget_root, openIntent(context, null, 0))
            views.setTextViewText(R.id.widget_total, if (total > 99) "99+" else total.toString())
            views.setViewVisibility(R.id.widget_total, if (total > 0) View.VISIBLE else View.GONE)

            val count = items?.length() ?: 0
            ROWS.forEachIndexed { i, (row, name, badge) ->
                if (i < count) {
                    val item = items!!.getJSONObject(i)
                    views.setViewVisibility(row, View.VISIBLE)
                    views.setTextViewText(name, item.optString("title", "Chat"))
                    val unread = item.optInt("unread", 0)
                    views.setTextViewText(badge, if (unread > 99) "99+" else unread.toString())
                    views.setOnClickPendingIntent(row, openIntent(context, item.optString("id"), 100 + i))
                } else {
                    views.setViewVisibility(row, View.GONE)
                }
            }
            views.setTextViewText(
                R.id.widget_empty,
                when {
                    !signedIn -> "Open Veyon Chat to sign in"
                    else -> "You're all caught up ✓"
                },
            )
            views.setViewVisibility(R.id.widget_empty, if (count == 0) View.VISIBLE else View.GONE)
            manager.updateAppWidget(widgetId, views)
        }
    }
}
