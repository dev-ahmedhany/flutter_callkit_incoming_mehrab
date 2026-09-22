import 'package:json_annotation/json_annotation.dart';

part 'android_params.g.dart';

/// Object config for Android.
@JsonSerializable(explicitToJson: true)
class AndroidParams {
  const AndroidParams({
    this.isCustomNotification,
    this.isCustomSmallExNotification,
    this.isShowLogo,
    this.logoUrl,
    this.isShowCallID,
    this.ringtonePath,
    this.backgroundColor,
    this.backgroundUrl,
    this.backgroundGradientStart,
    this.backgroundGradientCenter,
    this.backgroundGradientEnd,
    this.actionColor,
    this.textColor,
    this.badgeText,
    this.incomingCallNotificationChannelName,
    this.missedCallNotificationChannelName,
    this.isShowFullLockedScreen,
    this.isImportant,
    this.isBot,
  });

  /// Using custom notifications.
  final bool? isCustomNotification;

  /// Using custom notification small on some devices clipped out in android.
  final bool? isCustomSmallExNotification;

  /// Show logo app inside full screen.
  final bool? isShowLogo;

  /// Logo aoo inside full screen, example: http://... https://... or "assets/abc.png"
  final String? logoUrl;

  /// Show call id app inside full screen.
  final bool? isShowCallID;

  /// File name ringtone, put file into /android/app/src/main/res/raw/ringtone_default.mp3 -> value: `ringtone_default`
  final String? ringtonePath;

  /// Incoming call screen background color.
  final String? backgroundColor;

  /// Using image background for Incoming call screen. example: http://... https://... or "assets/abc.png"
  final String? backgroundUrl;

  /// Start colour of a three-stop background gradient, drawn top-left.
  ///
  /// All three stops must be set for the gradient to be used; with any of them
  /// missing the screen falls back to the flat [backgroundColor], so an older
  /// host app keeps exactly the background it has today.
  final String? backgroundGradientStart;

  /// Middle colour of the gradient, at 45%. Off-centre on purpose: a bright
  /// band placed away from the middle is what reads as metal rather than as a
  /// plastic two-colour ramp.
  final String? backgroundGradientCenter;

  /// End colour of the gradient, drawn bottom-right.
  final String? backgroundGradientEnd;

  /// Color used in button/text on notification.
  final String? actionColor;

  /// Color used for the text in the full screen notification
  final String? textColor;

  /// Short label shown under the caller's name, e.g. a plan or tier name.
  ///
  /// A word, not a colour: the background alone cannot be read by a screen
  /// reader, in greyscale, or by anyone with colour blindness.
  final String? badgeText;

  /// Notification channel name of incoming call.
  final String? incomingCallNotificationChannelName;

  /// Notification channel name of missed call.
  final String? missedCallNotificationChannelName;

  /// Show full locked screen.
  final bool? isShowFullLockedScreen;

  /// Caller is important to the user of this device with regards to how frequently they interact.
  /// https://developer.android.com/reference/androidx/core/app/Person#isImportant()
  final bool? isImportant;

  /// Used primarily to identify automated tooling.
  /// https://developer.android.com/reference/androidx/core/app/Person#isBot()
  final bool? isBot;

  factory AndroidParams.fromJson(Map<String, dynamic> json) =>
      _$AndroidParamsFromJson(json);

  Map<String, dynamic> toJson() => _$AndroidParamsToJson(this);
}
