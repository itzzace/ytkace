#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string>
#import <vector>
#import <algorithm>
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

// The iPhone bar under the video comes in the watch response as a list of
// buttons whose last entry is ⋯. YouTube's template shows as many as fit and
// moves the rest into ⋯, next to the ⋯ entry's own items (Save, Download,
// Report). Rewriting that list before the response is parsed puts YouTube's
// own buttons in the user's order, drops hidden ones, and lets ⋯ items take
// the free spots.

// Buttons YouTube has sent this device, so the editor only offers ones that
// exist here (Clip, Thanks and the like only show on some videos).
extern "C" void YTKACENoteActionBarButtons(NSArray<NSString *> *names) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    NSString *const key = @"YTKACE.State.ActionBarSeen";
    dispatch_once(&once, ^{
        id stored = [NSUserDefaults.standardUserDefaults objectForKey:key];
        seen = [NSMutableSet setWithArray:[stored isKindOfClass:NSArray.class] ? stored : @[]];
    });
    BOOL added = NO;
    @synchronized (seen) {
        for (NSString *name in names) {
            if (name.length != 0 && ![seen containsObject:name]) {
                [seen addObject:name];
                added = YES;
            }
        }
        if (added) [NSUserDefaults.standardUserDefaults setObject:seen.allObjects forKey:key];
    }
}

namespace {

struct PBField {
    uint64_t number;
    int type;
    uint64_t value;
    std::string bytes;
};

bool PBReadVarint(const std::string &data, size_t &index, uint64_t &out) {
    out = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (index >= data.size()) return false;
        const uint8_t byte = (uint8_t)data[index++];
        out |= (uint64_t)(byte & 0x7f) << shift;
        if (byte < 0x80) return true;
    }
    return false;
}

void PBWriteVarint(std::string &out, uint64_t value) {
    while (value >= 0x80) {
        out.push_back((char)((value & 0x7f) | 0x80));
        value >>= 7;
    }
    out.push_back((char)value);
}

bool PBParse(const std::string &data, std::vector<PBField> &fields) {
    size_t index = 0;
    while (index < data.size()) {
        uint64_t key = 0;
        if (!PBReadVarint(data, index, key)) return false;
        PBField field;
        field.number = key >> 3;
        field.type = (int)(key & 7);
        field.value = 0;
        if (field.number == 0) return false;
        switch (field.type) {
            case 0:
                if (!PBReadVarint(data, index, field.value)) return false;
                break;
            case 1:
                if (index + 8 > data.size()) return false;
                field.bytes = data.substr(index, 8);
                index += 8;
                break;
            case 5:
                if (index + 4 > data.size()) return false;
                field.bytes = data.substr(index, 4);
                index += 4;
                break;
            case 2: {
                uint64_t length = 0;
                if (!PBReadVarint(data, index, length) || length > data.size() - index) return false;
                field.bytes = data.substr(index, (size_t)length);
                index += (size_t)length;
                break;
            }
            default:
                return false;
        }
        fields.push_back(std::move(field));
    }
    return true;
}

std::string PBSerialize(const std::vector<PBField> &fields) {
    std::string out;
    for (const PBField &field : fields) {
        PBWriteVarint(out, (field.number << 3) | (uint64_t)field.type);
        if (field.type == 0) {
            PBWriteVarint(out, field.value);
        } else if (field.type == 2) {
            PBWriteVarint(out, field.bytes.size());
            out += field.bytes;
        } else {
            out += field.bytes;
        }
    }
    return out;
}

PBField PBMessage(uint64_t number, const std::string &bytes) {
    PBField field;
    field.number = number;
    field.type = 2;
    field.value = 0;
    field.bytes = bytes;
    return field;
}

bool PBContains(const std::string &data, const char *needle) {
    return data.find(needle) != std::string::npos;
}

// Field numbers in the bar model.
const uint64_t YTKACEBarModelField = 2185;      // the bar
const uint64_t YTKACEBarEntryField = 1;         // one button, repeated
const uint64_t YTKACEEntryRendererField = 10;   // the button's renderer
const uint64_t YTKACEOverflowField = 37098;     // ⋯, inside its renderer
const uint64_t YTKACEOverflowItemField = 2;     // ⋯'s own items
const uint64_t YTKACEOverflowCopyField = 3;     // menu versions of the bar buttons

// The renderer kinds whose field number says what they are.
const uint64_t YTKACELikeRenderer = 484585818;
const uint64_t YTKACEDislikeRenderer = 484590786;
const uint64_t YTKACESaveRenderer = 484598023;
const uint64_t YTKACEDownloadRenderer = 33561776;
const uint64_t YTKACEButtonRenderer = 461054335;
const uint64_t YTKACEAskRenderer = 489973921;

// The setting name ("Like", "Save", ...) of a renderer, or nil.
NSString *YTKACERendererName(const std::string &renderer) {
    std::vector<PBField> fields;
    if (!PBParse(renderer, fields) || fields.empty()) return nil;
    const uint64_t kind = fields.front().number;
    if (kind == YTKACELikeRenderer) return @"Like";
    if (kind == YTKACEDislikeRenderer) return @"Dislike";
    if (kind == YTKACESaveRenderer) return @"Save";
    if (kind == YTKACEDownloadRenderer) return @"Download";
    if (kind == YTKACEOverflowField) return @"Overflow";
    if (kind == YTKACEAskRenderer) return @"Ask";
    if (kind != YTKACEButtonRenderer) return nil;
    if (PBContains(renderer, "/share_24pt") || PBContains(renderer, "id.video.share.button")) return @"Share";
    if (PBContains(renderer, "/spark_24pt") || PBContains(renderer, "you-chat-entrypoint")) return @"Ask";
    if (PBContains(renderer, "/flag_24pt")) return @"Report";
    if (PBContains(renderer, "/scissors")) return @"Clip";
    if (PBContains(renderer, "/remix")) return @"Remix";
    if (PBContains(renderer, "/money_heart") || PBContains(renderer, "/thanks")) return @"Thanks";
    if (PBContains(renderer, "/hype")) return @"Hype";
    if (PBContains(renderer, "/bookmark")) return @"Save";
    if (PBContains(renderer, "/download")) return @"Download";
    return nil;
}

// The renderer inside a bar entry.
bool YTKACEEntryRenderer(const std::string &entry, std::string &renderer) {
    std::vector<PBField> fields;
    if (!PBParse(entry, fields)) return false;
    for (const PBField &field : fields) {
        if (field.number == YTKACEEntryRendererField && field.type == 2) {
            renderer = field.bytes;
            return true;
        }
    }
    return false;
}

// A ⋯ item drawn in the bar (Report) gets the bar's icon-button look; the
// menu's style shows as a grey pill there.
std::string YTKACEBarVersion(const std::string &renderer) {
    std::vector<PBField> fields, button;
    if (!PBParse(renderer, fields) || fields.size() != 1 || fields.front().number != YTKACEButtonRenderer ||
        !PBParse(fields.front().bytes, button)) {
        return renderer;
    }
    // Ask and ⋯ are bare icons: style 3, kind 4, field 40 set.
    bool hasFlag = false;
    for (PBField &field : button) {
        if (field.number == 11 && field.type == 0) field.value = 3;
        if (field.number == 13 && field.type == 0) field.value = 4;
        if (field.number == 40 && field.type == 0) { field.value = 1; hasFlag = true; }
    }
    // No title: even hidden it takes room and pushes the icon left.
    button.erase(std::remove_if(button.begin(), button.end(), [](const PBField &field) {
        return field.number == 3 && field.type == 2;
    }), button.end());
    if (!hasFlag) {
        PBField flag;
        flag.number = 40;
        flag.type = 0;
        flag.value = 1;
        button.push_back(flag);
    }
    return PBSerialize({PBMessage(YTKACEButtonRenderer, PBSerialize(button))});
}

struct YTKACEBarItem {
    NSString *name;
    std::string barRenderer;
    std::string menuRenderer;
    NSUInteger position;
};

bool YTKACERewriteBar(std::string &bar, NSArray<NSString *> *order, NSSet<NSString *> *hidden) {
    std::vector<PBField> fields;
    if (!PBParse(bar, fields)) return false;

    // The bar's buttons and the ⋯ entry.
    std::vector<YTKACEBarItem> items;
    NSInteger overflowIndex = -1;
    size_t firstEntry = SIZE_MAX;
    std::vector<PBField> overflowEntry, overflowRenderer, overflow;
    for (size_t index = 0; index < fields.size(); index++) {
        const PBField &field = fields[index];
        if (field.number != YTKACEBarEntryField || field.type != 2) continue;
        firstEntry = MIN(firstEntry, index);
        std::string renderer;
        if (!YTKACEEntryRenderer(field.bytes, renderer)) return false;
        NSString *name = YTKACERendererName(renderer);
        if ([name isEqualToString:@"Overflow"]) {
            if (overflowIndex >= 0 || !PBParse(field.bytes, overflowEntry) || !PBParse(renderer, overflowRenderer)) {
                return false;
            }
            for (const PBField &inner : overflowRenderer) {
                if (inner.number == YTKACEOverflowField && inner.type == 2 && !PBParse(inner.bytes, overflow)) return false;
            }
            overflowIndex = (NSInteger)index;
            continue;
        }
        items.push_back({name, renderer, renderer, items.size()});
    }
    if (overflowIndex < 0 || overflow.empty()) return false;

    // Menu versions of the bar's buttons, and ⋯'s own items.
    std::vector<PBField> menuKept;
    for (const PBField &part : overflow) {
        if (part.type != 2) continue;
        NSString *name = YTKACERendererName(part.bytes);
        if (part.number == YTKACEOverflowCopyField) {
            for (YTKACEBarItem &item : items) {
                if (name != nil && [item.name isEqualToString:name]) item.menuRenderer = part.bytes;
            }
        } else if (part.number == YTKACEOverflowItemField) {
            if (name != nil && ![name isEqualToString:@"Overflow"]) {
                items.push_back({name, YTKACEBarVersion(part.bytes), part.bytes, items.size()});
            } else {
                menuKept.push_back(part);
            }
        }
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:@"Overflow"];
    for (const YTKACEBarItem &item : items) {
        if (item.name != nil) [names addObject:item.name];
    }
    YTKACENoteActionBarButtons(names);
    if (order.count == 0 && hidden.count == 0) return false;

    // Hidden ones go; the rest follow the saved order, then YouTube's.
    std::vector<YTKACEBarItem> shown;
    for (const YTKACEBarItem &item : items) {
        if (item.name != nil && [hidden containsObject:item.name]) continue;
        shown.push_back(item);
    }
    std::stable_sort(shown.begin(), shown.end(), [order](const YTKACEBarItem &left, const YTKACEBarItem &right) {
        NSUInteger leftRank = left.name != nil ? [order indexOfObject:left.name] : NSNotFound;
        NSUInteger rightRank = right.name != nil ? [order indexOfObject:right.name] : NSNotFound;
        if (leftRank == NSNotFound) leftRank = order.count + left.position;
        if (rightRank == NSNotFound) rightRank = order.count + right.position;
        return leftRank < rightRank;
    });

    // ⋯ keeps its button and unknown items; its copies match the new bar.
    std::vector<PBField> newOverflow;
    bool copiesWritten = false;
    for (const PBField &part : overflow) {
        if (part.number == YTKACEOverflowItemField && part.type == 2) continue;
        if (part.number == YTKACEOverflowCopyField && part.type == 2) {
            if (!copiesWritten) {
                for (const PBField &kept : menuKept) newOverflow.push_back(kept);
                for (const YTKACEBarItem &item : shown) newOverflow.push_back(PBMessage(YTKACEOverflowCopyField, item.menuRenderer));
                copiesWritten = true;
            }
            continue;
        }
        newOverflow.push_back(part);
        // ⋯'s own items went right after its button.
        if (part.number == 1 && !copiesWritten) {
            for (const PBField &kept : menuKept) newOverflow.push_back(kept);
            for (const YTKACEBarItem &item : shown) newOverflow.push_back(PBMessage(YTKACEOverflowCopyField, item.menuRenderer));
            copiesWritten = true;
        }
    }
    if (!copiesWritten) {
        for (const PBField &kept : menuKept) newOverflow.push_back(kept);
        for (const YTKACEBarItem &item : shown) newOverflow.push_back(PBMessage(YTKACEOverflowCopyField, item.menuRenderer));
    }
    for (PBField &inner : overflowRenderer) {
        if (inner.number == YTKACEOverflowField) inner.bytes = PBSerialize(newOverflow);
    }
    for (PBField &part : overflowEntry) {
        if (part.number == YTKACEEntryRendererField) part.bytes = PBSerialize(overflowRenderer);
    }

    std::vector<PBField> rebuilt;
    for (size_t index = 0; index < fields.size(); index++) {
        if (index == firstEntry) {
            for (const YTKACEBarItem &item : shown) {
                rebuilt.push_back(PBMessage(YTKACEBarEntryField,
                                            PBSerialize({PBMessage(YTKACEEntryRendererField, item.barRenderer)})));
            }
            rebuilt.push_back(PBMessage(YTKACEBarEntryField, PBSerialize(overflowEntry)));
        }
        if (fields[index].number == YTKACEBarEntryField && fields[index].type == 2) continue;
        rebuilt.push_back(fields[index]);
    }
    bar = PBSerialize(rebuilt);
    return true;
}

// The chip bar (iPad, and iPhones that get the iPad layout): field 17 of
// its model is a flat list of {renderer} entries, the like/dislike pill one
// entry, and no ⋯. Reordering here instead of moving cells keeps the order
// when the row is too narrow and scrolls.
const uint64_t YTKACEChipBarModelField = 389155117;
const uint64_t YTKACEChipBarListField = 17;
const uint64_t YTKACEPillRenderer = 484586709;

bool YTKACERewriteChipBar(std::string &model, NSArray<NSString *> *order, NSSet<NSString *> *hidden) {
    std::vector<PBField> fields;
    if (!PBParse(model, fields)) return false;
    bool changed = false;
    for (PBField &field : fields) {
        if (field.number != YTKACEChipBarListField || field.type != 2) continue;
        std::vector<PBField> list;
        if (!PBParse(field.bytes, list)) return false;
        std::vector<YTKACEBarItem> items;
        std::vector<PBField> others;
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        size_t first = SIZE_MAX;
        for (size_t index = 0; index < list.size(); index++) {
            const PBField &entry = list[index];
            if (entry.number != 1 || entry.type != 2) continue;
            first = MIN(first, index);
            std::vector<PBField> parts;
            NSString *name = nil;
            bool pill = false;
            if (PBParse(entry.bytes, parts) && !parts.empty() && parts.front().type == 2) {
                std::vector<PBField> renderer;
                pill = PBParse(parts.front().bytes, renderer) && !renderer.empty() &&
                    renderer.front().number == YTKACEPillRenderer;
                name = pill ? @"Like" : YTKACERendererName(parts.front().bytes);
            }
            if (name != nil) [names addObject:name];
            if (pill) [names addObject:@"Dislike"];
            // The pill goes only when both halves are hidden; one half is
            // collapsed in the layout hooks.
            const bool gone = name != nil && [hidden containsObject:name] &&
                (!pill || [hidden containsObject:@"Dislike"]);
            if (!gone) items.push_back({name, entry.bytes, entry.bytes, items.size()});
        }
        YTKACENoteActionBarButtons(names);
        if (first == SIZE_MAX || (order.count == 0 && hidden.count == 0)) continue;
        std::stable_sort(items.begin(), items.end(), [order](const YTKACEBarItem &left, const YTKACEBarItem &right) {
            NSUInteger leftRank = left.name != nil ? [order indexOfObject:left.name] : NSNotFound;
            NSUInteger rightRank = right.name != nil ? [order indexOfObject:right.name] : NSNotFound;
            if (leftRank == NSNotFound) leftRank = order.count + left.position;
            if (rightRank == NSNotFound) rightRank = order.count + right.position;
            return leftRank < rightRank;
        });
        std::vector<PBField> rebuilt;
        for (size_t index = 0; index < list.size(); index++) {
            if (index == first) {
                for (const YTKACEBarItem &item : items) rebuilt.push_back(PBMessage(1, item.barRenderer));
            }
            if (list[index].number == 1 && list[index].type == 2) continue;
            rebuilt.push_back(list[index]);
        }
        field.bytes = PBSerialize(rebuilt);
        changed = true;
    }
    if (changed) model = PBSerialize(fields);
    return changed;
}

// Walks down the messages that hold the like button until a bar model.
bool YTKACERewriteMessage(std::string &message, int depth, NSArray *order, NSSet *hidden) {
    if (depth > 40) return false;
    std::vector<PBField> fields;
    if (!PBParse(message, fields)) return false;
    bool changed = false;
    for (PBField &field : fields) {
        if (field.type != 2 || !PBContains(field.bytes, "id.video.like.button")) continue;
        if (field.number == YTKACEBarModelField) {
            std::string bar = field.bytes;
            if (YTKACERewriteBar(bar, order, hidden)) {
                field.bytes = bar;
                changed = true;
            }
        } else if (field.number == YTKACEChipBarModelField) {
            std::string bar = field.bytes;
            if (YTKACERewriteChipBar(bar, order, hidden)) {
                field.bytes = bar;
                changed = true;
            }
        } else if (YTKACERewriteMessage(field.bytes, depth + 1, order, hidden)) {
            changed = true;
        }
    }
    if (changed) message = PBSerialize(fields);
    return changed;
}

NSArray<NSString *> *YTKACEBarNames(void) {
    return @[@"Like", @"Dislike", @"Share", @"Ask", @"Save", @"Download", @"Clip",
             @"Remix", @"Thanks", @"Hype", @"Report"];
}

}  // namespace

static NSData *YTKACERewrittenResponse(NSData *data) {
    static const char marker[] = "id.video.like.button";
    if (data.length == 0 || !YTKACEFeatureEnabled(@"YTKACE.Preference.Enabled")) return data;
    NSArray *order = YTKACEPreferenceObject(@"YTKACE.Preference.ActionBar.Order");
    if (![order isKindOfClass:NSArray.class]) order = @[];
    NSMutableSet *hidden = [NSMutableSet set];
    for (NSString *name in YTKACEBarNames()) {
        if (YTKACEFeatureEnabled([NSString stringWithFormat:@"YTKACE.Preference.ActionBar.%@Hidden", name])) {
            [hidden addObject:name];
        }
    }
    // With nothing moved or hidden this only notes which buttons exist.
    if (memmem(data.bytes, data.length, marker, sizeof(marker) - 1) == NULL) return data;
    std::string message((const char *)data.bytes, data.length);
    if (!YTKACERewriteMessage(message, 0, order, hidden)) return data;
    return [NSData dataWithBytes:message.data() length:message.size()];
}

static IMP OriginalGetWatchInit;
static IMP OriginalGetWatchMerge;
static IMP OriginalWatchNextInit;

static id YTKACEGetWatchInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    return ((id (*)(id, SEL, id, id, NSError **))OriginalGetWatchInit)(
        receiver, selector, YTKACERewrittenResponse(data), registry, error);
}

static void YTKACEGetWatchMerge(id receiver, SEL selector, NSData *data, id registry) {
    ((void (*)(id, SEL, id, id))OriginalGetWatchMerge)(receiver, selector, YTKACERewrittenResponse(data), registry);
}

static id YTKACEWatchNextInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    return ((id (*)(id, SEL, id, id, NSError **))OriginalWatchNextInit)(
        receiver, selector, YTKACERewrittenResponse(data), registry, error);
}

__attribute__((constructor)) static void YTKACEInstallActionBarModelHooks(void) {
    YTKACEInstallInstanceHook(@"YTIGetWatchResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)YTKACEGetWatchInit, &OriginalGetWatchInit);
    YTKACEInstallInstanceHook(@"YTIGetWatchResponse", @"mergeFromData:extensionRegistry:",
                              (IMP)YTKACEGetWatchMerge, &OriginalGetWatchMerge);
    YTKACEInstallInstanceHook(@"YTIWatchNextResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)YTKACEWatchNextInit, &OriginalWatchNextInit);
}
