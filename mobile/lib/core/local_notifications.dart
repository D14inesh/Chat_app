/// Reminder delivery via a plain on-device scheduled notification rather
/// than server push (which would need FCM -- infrastructure this project
/// doesn't have yet). Since reminders already carry an absolute `remindAt`
/// fetched from the server, the OS can fire the notification itself at that
/// exact time with zero server involvement, at the cost of only firing on
/// *this* device rather than all of the account's devices -- an acceptable
/// trade for now, matching the CATEGORY_TITLES flavor text from
/// schedulers/reminders_scheduler.py so it reads the same on mobile as web.
library local_notifications;

import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const Map<String, List<String>> kCategoryTitles = {
  'birthday': ['🎂 Happy Birthday!', "🎉 It's your special day!", '🎈 Wishing you the happiest birthday!'],
  'happy': ['😊 Something to smile about', '🌟 A happy little reminder', '🥳 Celebrating this with you'],
  'love': ['❤️ A love note for you', '💕 Thinking of you', '💖 Sending you love'],
  'sad': ["🤗 Sending you strength", "💙 You're not alone in this", '🫂 Thinking of you today'],
  'breakup': ['💙 Be gentle with yourself', '🌤️ This too shall pass', '🫶 You deserve peace'],
  'general': ['⏰ Reminder'],
};

String pickTitle(String category) {
  final options = kCategoryTitles[category] ?? kCategoryTitles['general']!;
  return options[Random().nextInt(options.length)];
}

class LocalNotifications {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: androidInit));
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    _initialized = true;
  }

  static int _idFor(String reminderId) => reminderId.hashCode & 0x7fffffff;

  static Future<void> scheduleReminder({required String id, required String content, required String category, required DateTime remindAt}) async {
    await init();
    if (remindAt.isBefore(DateTime.now())) return;
    await _plugin.zonedSchedule(
      _idFor(id),
      pickTitle(category),
      content,
      tz.TZDateTime.from(remindAt, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails('reminders', 'Reminders', importance: Importance.high, priority: Priority.high),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> cancel(String id) => _plugin.cancel(_idFor(id));

  /// A new message, while this app is running but the chat isn't on screen.
  /// One notification per chat, replaced by that chat's newest message.
  static Future<void> showMessage({required String conversationId, required String title, required String body}) async {
    await init();
    await _plugin.show(
      _idFor('msg:$conversationId'),
      title,
      body.length > 120 ? '${body.substring(0, 120)}…' : body,
      const NotificationDetails(
        android: AndroidNotificationDetails('messages', 'Messages',
            channelDescription: 'New chat messages', importance: Importance.high, priority: Priority.high),
      ),
    );
  }

  /// Clears a chat's message notification once it's opened.
  static Future<void> clearMessage(String conversationId) async {
    if (!_initialized) return;
    await _plugin.cancel(_idFor('msg:$conversationId'));
  }

  static Future<void> showCall({required String conversationId, required String callerName, required bool video}) async {
    await init();
    await _plugin.show(
      _idFor('call:$conversationId'),
      'Incoming ${video ? 'video' : 'voice'} call',
      callerName,
      const NotificationDetails(
        android: AndroidNotificationDetails('calls', 'Calls',
            channelDescription: 'Incoming calls',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call),
      ),
    );
  }

  /// Someone is signing in to this account on a computer — open the app to
  /// accept or reject (features/auth/login_approval.dart asks on open).
  static Future<void> showLoginApproval({required String id, required String device}) async {
    await init();
    await _plugin.show(
      _idFor('login:$id'),
      'Is this you signing in?',
      'Someone is signing in to your account on $device. Open Veyon to accept or reject.',
      const NotificationDetails(
        android: AndroidNotificationDetails('security', 'Security',
            channelDescription: 'Sign-in requests', importance: Importance.max, priority: Priority.max),
      ),
    );
  }

  static Future<void> clearLoginApproval(String id) async {
    if (!_initialized) return;
    await _plugin.cancel(_idFor('login:$id'));
  }

  static Future<void> clearCall(String conversationId) async {
    if (!_initialized) return;
    await _plugin.cancel(_idFor('call:$conversationId'));
  }
}
