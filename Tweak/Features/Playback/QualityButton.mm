#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTKACEQualityButtonKey = @"YTKACE.Preference.Player.QualityButton";
static const void *YTKACEQualityStyledAssociation = &YTKACEQualityStyledAssociation;
static NSHashTable<UIButton *> *YTKACEQualityButtons;
static IMP OriginalRedesignedDidSelectFormat;
static IMP OriginalOriginalDidSelectFormat;

static id YTKACEQualityGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

// "1080p60 HDR" -> "1080p60", "1080p Premium" -> "1080p+"
static NSString *YTKACEShortQualityLabel(NSString *label) {
    NSArray<NSString *> *words = [label componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    NSString *first = words.firstObject;
    if (first.length == 0) return nil;
    return [label rangeOfString:@"Premium" options:NSCaseInsensitiveSearch].location != NSNotFound
        ? [first stringByAppendingString:@"+"] : first;
}

// The quality of the stream that's playing right now.
static NSString *YTKACECurrentQuality(UIView *overlay) {
    for (UIResponder *responder = overlay; responder != nil; responder = responder.nextResponder) {
        if (![NSStringFromClass(responder.class) isEqualToString:@"YTPlayerViewController"]) continue;
        id format = YTKACEQualityGet(YTKACEQualityGet(responder, @"activeVideo"), @"selectedVideoFormat");
        id label = YTKACEQualityGet(format, @"qualityLabel");
        return [label isKindOfClass:NSString.class] ? YTKACEShortQualityLabel(label) : nil;
    }
    return nil;
}

@interface YTKACEQualityButtonTarget : NSObject
+ (instancetype)sharedTarget;
- (void)openQuality:(UIButton *)sender;
@end

@implementation YTKACEQualityButtonTarget

+ (instancetype)sharedTarget {
    static YTKACEQualityButtonTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [YTKACEQualityButtonTarget new];
    });
    return target;
}

// Opens YouTube's own quality menu, like the quality row in the settings sheet.
- (void)openQuality:(UIButton *)sender {
    SEL open = NSSelectorFromString(@"didPressVideoQuality:");
    for (UIResponder *responder = sender; responder != nil; responder = responder.nextResponder) {
        if ([responder respondsToSelector:open]) {
            ((void (*)(id, SEL, id))objc_msgSend)(responder, open, sender);
            return;
        }
    }
    YTKACEDebugLog(@"quality", @"no responder for didPressVideoQuality:");
}

@end

static void YTKACEStyleQualityButton(UIButton *button) {
    if (objc_getAssociatedObject(button, YTKACEQualityStyledAssociation) != nil) return;
    objc_setAssociatedObject(button, YTKACEQualityStyledAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = NO;
    button.titleLabel.lineBreakMode = NSLineBreakByClipping;
    for (NSLayoutConstraint *constraint in button.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeWidth) constraint.active = NO;
    }
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:40.0].active = YES;
}

static void YTKACESetQualityTitle(UIButton *button, NSString *quality) {
    if ([quality isEqualToString:[button titleForState:UIControlStateNormal]]) return;
    [button setTitle:quality forState:UIControlStateNormal];
    [button setImage:quality.length != 0 ? nil
        : [UIImage systemImageNamed:@"slider.horizontal.3"
                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                                                    weight:UIImageSymbolWeightMedium]]
            forState:UIControlStateNormal];
}

// The stream switched quality (Auto changing it, or a pick in the menu).
static void YTKACEQualityDidSelectFormat(id receiver, SEL selector, id video, id format, IMP original) {
    if (original != NULL) ((void (*)(id, SEL, id, id))original)(receiver, selector, video, format);
    id label = YTKACEQualityGet(format, @"qualityLabel");
    if (![label isKindOfClass:NSString.class] || !YTKACEFeatureEnabled(YTKACEQualityButtonKey)) return;
    NSString *quality = YTKACEShortQualityLabel(label);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIButton *button in YTKACEQualityButtons.allObjects) {
            if (!button.hidden && button.window != nil) YTKACESetQualityTitle(button, quality);
        }
    });
}

static void YTKACERedesignedDidSelectFormat(id receiver, SEL selector, id video, id format) {
    YTKACEQualityDidSelectFormat(receiver, selector, video, format, OriginalRedesignedDidSelectFormat);
}

static void YTKACEOriginalDidSelectFormat(id receiver, SEL selector, id video, id format) {
    YTKACEQualityDidSelectFormat(receiver, selector, video, format, OriginalOriginalDidSelectFormat);
}

void YTKACEInstallQualityButtonHooks(void) {
    YTKACEQualityButtons = [NSHashTable weakObjectsHashTable];
    YTKACEInstallInstanceHook(@"YTVideoQualitySwitchRedesignedController", @"singleVideo:didSelectVideoFormat:",
                              (IMP)YTKACERedesignedDidSelectFormat, &OriginalRedesignedDidSelectFormat);
    YTKACEInstallInstanceHook(@"YTVideoQualitySwitchOriginalController", @"singleVideo:didSelectVideoFormat:",
                              (IMP)YTKACEOriginalDidSelectFormat, &OriginalOriginalDidSelectFormat);
    YTKACERegisterOverlayConfigurator(@"quality", ^(UIView *overlay, UIStackView *stack) {
        UIButton *button = YTKACEOverlayButton(stack, @"YTKACE Quality", @"slider.horizontal.3",
                                               YTKACEQualityButtonTarget.sharedTarget,
                                               @selector(openQuality:));
        button.hidden = !YTKACEFeatureEnabled(YTKACEQualityButtonKey);
        if (button.hidden) return;
        YTKACEStyleQualityButton(button);
        [YTKACEQualityButtons addObject:button];
        // shows the icon until the stream has a quality
        YTKACESetQualityTitle(button, YTKACECurrentQuality(overlay));
    });
}
