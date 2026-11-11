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

static BOOL YTKACEQualityCompact(void) {
    return [YTKACEPreferenceObject(@"YTKACE.Preference.Player.QualityButtonStyle") integerValue] == 1;
}

static NSArray<NSString *> *YTKACEQualityWords(NSString *label) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [label componentsSeparatedByCharactersInSet:
             NSCharacterSet.whitespaceCharacterSet]) {
        if (word.length != 0) [words addObject:word];
    }
    return words;
}

static BOOL YTKACEQualityIsPremium(NSString *label) {
    return [label rangeOfString:@"Premium" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Standard: "1080p60 HDR" -> "1080p60", "1080p Premium" -> "1080p+"
// Compact: "1080p60" -> "HD\n60", "2160p60 HDR" -> "4K\n60\nHDR", "1080p Premium" -> "HD+"
static NSString *YTKACEShortQualityLabel(NSString *label) {
    NSArray<NSString *> *words = YTKACEQualityWords(label);
    NSString *first = words.firstObject;
    if (first.length == 0) return nil;
    if (!YTKACEQualityCompact()) {
        return YTKACEQualityIsPremium(label) ? [first stringByAppendingString:@"+"] : first;
    }
    NSRange p = [first rangeOfString:@"p"];
    NSString *resolution = p.location == NSNotFound ? first : [first substringToIndex:p.location];
    NSString *fps = p.location == NSNotFound ? @"" : [first substringFromIndex:p.location + 1];
    NSString *name = @{@"2160": @"4K", @"1440": @"2K", @"1080": @"HD"}[resolution]
        ?: (p.location == NSNotFound ? first : [resolution stringByAppendingString:@"p"]);
    if (YTKACEQualityIsPremium(label)) name = [name stringByAppendingString:@"+"];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:name];
    if (fps.length != 0) [lines addObject:fps];
    for (NSUInteger index = 1; index < words.count && lines.count < 3; index++) {
        if (!YTKACEQualityIsPremium(words[index])) [lines addObject:words[index]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

// The last label from the quality switch, which keeps "Premium".
static NSString *YTKACEQualityLastLabel;

// The quality of the stream that's playing right now.
static NSString *YTKACECurrentQualityLabel(UIView *overlay) {
    for (UIResponder *responder = overlay; responder != nil; responder = responder.nextResponder) {
        if (![NSStringFromClass(responder.class) isEqualToString:@"YTPlayerViewController"]) continue;
        id format = YTKACEQualityGet(YTKACEQualityGet(responder, @"activeVideo"), @"selectedVideoFormat");
        id label = YTKACEQualityGet(format, @"qualityLabel");
        if (![label isKindOfClass:NSString.class]) return nil;
        NSString *last = YTKACEQualityLastLabel;
        BOOL same = last.length != 0 &&
            [YTKACEQualityWords(last).firstObject isEqualToString:YTKACEQualityWords(label).firstObject];
        return same ? last : label;
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

static const void *YTKACEQualityMinWidthAssociation = &YTKACEQualityMinWidthAssociation;

static void YTKACEStyleQualityButton(UIButton *button) {
    BOOL compact = YTKACEQualityCompact();
    if (objc_getAssociatedObject(button, YTKACEQualityStyledAssociation) == nil) {
        objc_setAssociatedObject(button, YTKACEQualityStyledAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.adjustsFontSizeToFitWidth = NO;
        button.titleLabel.lineBreakMode = NSLineBreakByClipping;
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        // fit the text; the row used to squeeze it and cut "1080p+" to "1080"
        for (NSLayoutConstraint *constraint in button.constraints) {
            if (constraint.firstItem == button && constraint.firstAttribute == NSLayoutAttributeWidth &&
                constraint.relation == NSLayoutRelationEqual) constraint.active = NO;
        }
        NSLayoutConstraint *minimum = [button.widthAnchor constraintGreaterThanOrEqualToConstant:40.0];
        minimum.active = YES;
        objc_setAssociatedObject(button, YTKACEQualityMinWidthAssociation, minimum, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    }
    button.titleLabel.font = [UIFont systemFontOfSize:compact ? 10.0 : 17.0 weight:UIFontWeightSemibold];
    button.titleLabel.numberOfLines = compact ? 3 : 1;
    NSLayoutConstraint *minimum = objc_getAssociatedObject(button, YTKACEQualityMinWidthAssociation);
    minimum.constant = compact ? 24.0 : 40.0;
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
    dispatch_async(dispatch_get_main_queue(), ^{
        YTKACEQualityLastLabel = [label copy];
        NSString *quality = YTKACEShortQualityLabel(label);
        for (UIButton *button in YTKACEQualityButtons.allObjects) {
            if (!button.hidden && button.window != nil) {
                YTKACEStyleQualityButton(button);
                YTKACESetQualityTitle(button, quality);
            }
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
        NSString *label = YTKACECurrentQualityLabel(overlay);
        YTKACESetQualityTitle(button, label != nil ? YTKACEShortQualityLabel(label) : nil);
    });
}
