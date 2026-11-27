#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Shows the time the video will end after the duration in the player's time
// pill, like "1:53 / 16:44 • 7:42 PM". Speed changes are taken into account.

static NSString *const YTKACEEndTimeKey = @"YTKACE.Preference.Overlay.EndTimeShown";
static const void *YTKACEEndDurationAssociation = &YTKACEEndDurationAssociation;
static const void *YTKACEEndBaseTextAssociation = &YTKACEEndBaseTextAssociation;
static const void *YTKACEEndCurrentAssociation = &YTKACEEndCurrentAssociation;
static IMP OriginalSetCurrentTime;
static IMP OriginalSetDuration;

double YTKACECurrentPlaybackRate(void);

static UILabel *YTKACEEndDurationLabel(UIView *view) {
    SEL selector = NSSelectorFromString(@"durationLabel");
    if (![view respondsToSelector:selector]) return nil;
    id label = ((id (*)(id, SEL))objc_msgSend)(view, selector);
    return [label isKindOfClass:UILabel.class] ? label : nil;
}

static NSString *YTKACEEndClock(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterNoStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
    });
    return [formatter stringFromDate:date];
}

static void YTKACEEndSetText(UIView *view, UILabel *label, NSString *text) {
    if ([label.text isEqualToString:text]) return;
    label.text = text;
    [label sizeToFit];
    [view invalidateIntrinsicContentSize];
    [view setNeedsLayout];
    [view.superview setNeedsLayout];
}

static void YTKACEEndUpdate(UIView *view, double current) {
    UILabel *label = YTKACEEndDurationLabel(view);
    NSString *base = objc_getAssociatedObject(view, YTKACEEndBaseTextAssociation);
    if (label == nil || base == nil) return;
    double duration = [objc_getAssociatedObject(view, YTKACEEndDurationAssociation) doubleValue];
    if (!YTKACEFeatureEnabled(YTKACEEndTimeKey) || duration <= 0.0 || current > duration) {
        YTKACEEndSetText(view, label, base);
        return;
    }
    double rate = YTKACECurrentPlaybackRate();
    if (!(rate > 0.0)) rate = 1.0;
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:(duration - MAX(current, 0.0)) / rate];
    YTKACEEndSetText(view, label, [NSString stringWithFormat:@"%@ • %@", base, YTKACEEndClock(end)]);
}

static void YTKACEEndSetDuration(UIView *receiver, SEL selector, double duration, BOOL offsetFromLive) {
    if (OriginalSetDuration != NULL) {
        ((void (*)(id, SEL, double, BOOL))OriginalSetDuration)(receiver, selector, duration, offsetFromLive);
    }
    UILabel *label = YTKACEEndDurationLabel(receiver);
    // Live streams have no end.
    objc_setAssociatedObject(receiver, YTKACEEndDurationAssociation,
                             offsetFromLive ? nil : @(duration), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver, YTKACEEndBaseTextAssociation,
                             label.text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    // YouTube sets the duration again on every tick, right after the time.
    NSNumber *current = objc_getAssociatedObject(receiver, YTKACEEndCurrentAssociation);
    if (current != nil) YTKACEEndUpdate(receiver, current.doubleValue);
}

static void YTKACEEndSetCurrentTime(UIView *receiver, SEL selector, double current, BOOL remaining) {
    if (OriginalSetCurrentTime != NULL) {
        ((void (*)(id, SEL, double, BOOL))OriginalSetCurrentTime)(receiver, selector, current, remaining);
    }
    objc_setAssociatedObject(receiver, YTKACEEndCurrentAssociation, @(current),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTKACEEndUpdate(receiver, current);
}

__attribute__((constructor)) static void YTKACEInstallEndTime(void) {
    YTKACEInstallInstanceHook(@"WatchTimestampView", @"setDuration:isOffsetFromLive:",
                              (IMP)YTKACEEndSetDuration, &OriginalSetDuration);
    YTKACEInstallInstanceHook(@"WatchTimestampView", @"setCurrentTime:displaysRemaining:",
                              (IMP)YTKACEEndSetCurrentTime, &OriginalSetCurrentTime);
}
