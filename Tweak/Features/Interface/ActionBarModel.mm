#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <string>
#import <vector>
#import <algorithm>
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

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

// The fullscreen bar's buttons in the order the response lists them, after
// any rewrite. Comments, Ask and ⋯ share one id in the drawn bar, so its
// layout code names them from this.
static NSArray<NSString *> *YTKACEFullscreenNames;

extern "C" NSArray<NSString *> *YTKACEFullscreenBarNames(void) {
    @synchronized (NSArray.class) {
        return YTKACEFullscreenNames;
    }
}

static void YTKACESetFullscreenBarNames(NSArray<NSString *> *names) {
    @synchronized (NSArray.class) {
        YTKACEFullscreenNames = [names copy];
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
    if (PBContains(renderer, "/text_bubble") || PBContains(renderer, "comment-item-section")) return @"Comments";
    if (PBContains(renderer, "/bookmark")) return @"Save";
    if (PBContains(renderer, "/download")) return @"Download";
    return nil;
}

// The renderer inside a bar entry.
bool YTKACEEntryRenderer(const std::string &entry, std::string &renderer,
                         uint64_t rendererField = YTKACEEntryRendererField) {
    std::vector<PBField> fields;
    if (!PBParse(entry, fields)) return false;
    for (const PBField &field : fields) {
        if (field.number == rendererField && field.type == 2) {
            renderer = field.bytes;
            return true;
        }
    }
    return false;
}

// Drops the text from the buttons inside a ⋯ item, like Save's toggle, which
// wraps its buttons instead of being one.
bool YTKACEStripButtonTitles(std::string &message, int depth) {
    if (depth > 8) return false;
    std::vector<PBField> fields;
    if (!PBParse(message, fields)) return false;
    bool changed = false;
    std::vector<PBField> kept;
    for (PBField &field : fields) {
        if (field.type == 2) {
            if (field.number == YTKACEButtonRenderer) {
                std::vector<PBField> button;
                if (PBParse(field.bytes, button)) {
                    const size_t before = button.size();
                    button.erase(std::remove_if(button.begin(), button.end(), [](const PBField &part) {
                        return part.number == 3 && part.type == 2;
                    }), button.end());
                    if (button.size() != before) {
                        field.bytes = PBSerialize(button);
                        changed = true;
                    }
                }
            } else if (YTKACEStripButtonTitles(field.bytes, depth + 1)) {
                changed = true;
            }
        }
        kept.push_back(std::move(field));
    }
    if (changed) message = PBSerialize(kept);
    return changed;
}

// A ⋯ item drawn in the bar (Report) gets the bar's icon-button look; the
// menu's style shows as a grey pill there.
std::string YTKACEBarVersion(const std::string &renderer) {
    std::vector<PBField> fields, button;
    if (!PBParse(renderer, fields) || fields.size() != 1) return renderer;
    if (fields.front().number != YTKACEButtonRenderer) {
        // Save's menu version has a "Save" label that, even hidden, pushes the
        // icon out of its slot on some devices.
        std::string copy = renderer;
        YTKACEStripButtonTitles(copy, 0);
        return copy;
    }
    if (!PBParse(fields.front().bytes, button)) return renderer;
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

// A bar button as a ⋯ row: titled (from its spoken label when it has no
// title) and in the menu's style. Goes through toggles, which wrap buttons.
std::string YTKACEMenuVersion(const std::string &message, int depth = 0) {
    std::vector<PBField> fields;
    if (depth > 6 || !PBParse(message, fields)) return message;
    for (PBField &field : fields) {
        if (field.type != 2) continue;
        if (field.number != YTKACEButtonRenderer) {
            field.bytes = YTKACEMenuVersion(field.bytes, depth + 1);
            continue;
        }
        std::vector<PBField> button;
        if (!PBParse(field.bytes, button)) continue;
        std::string label;
        bool titled = false, hasMenuFlag = false;
        for (const PBField &part : button) {
            if (part.number == 3 && part.type == 2) titled = true;
            if (part.number == 5 && part.type == 2) label = part.bytes;
        }
        button.erase(std::remove_if(button.begin(), button.end(), [](const PBField &part) {
            return part.number == 40 && part.type == 0;
        }), button.end());
        for (PBField &part : button) {
            if (part.type != 0) continue;
            if (part.number == 7) part.value = 9;
            if (part.number == 13) part.value = 1;
            if (part.number == 14) { part.value = 1; hasMenuFlag = true; }
        }
        if (!hasMenuFlag) {
            PBField flag;
            flag.number = 14;
            flag.type = 0;
            flag.value = 1;
            button.push_back(flag);
        }
        if (!titled && !label.empty()) button.push_back(PBMessage(3, label));
        field.bytes = PBSerialize(button);
    }
    return PBSerialize(fields);
}

// A ⋯ row from a bar button. Toggles (Like, Dislike, Save) stay toggles so
// they still fill in and undo; their field 4 is the display style, 7 for a
// menu row as in YouTube's own ⋯ Save (0 in the bar draws it centered).
std::string YTKACEMenuRow(const std::string &renderer) {
    std::string converted = YTKACEMenuVersion(renderer);
    std::vector<PBField> top;
    if (!PBParse(converted, top) || top.size() != 1 || top.front().number == YTKACEButtonRenderer ||
        top.front().type != 2) {
        return converted;
    }
    std::vector<PBField> toggle;
    if (!PBParse(top.front().bytes, toggle)) return converted;
    bool styled = false;
    for (PBField &field : toggle) {
        if (field.number == 4 && field.type == 0) {
            field.value = 7;
            styled = true;
        }
    }
    if (!styled) {
        PBField style;
        style.number = 4;
        style.type = 0;
        style.value = 7;
        toggle.push_back(style);
    }
    // Like and Dislike draw an animated icon the menu doesn't show; give
    // their off (1) and on (2) buttons YouTube's named thumb icons.
    for (PBField &field : toggle) {
        if (field.number != 1 || field.type != 2) continue;
        std::vector<PBField> wrapper;
        if (!PBParse(field.bytes, wrapper)) continue;
        for (PBField &inner : wrapper) {
            if (inner.type != 2) continue;
            std::vector<PBField> states;
            if (!PBParse(inner.bytes, states)) continue;
            for (PBField &state : states) {
                if ((state.number != 1 && state.number != 2) || state.type != 2) continue;
                std::vector<PBField> holder;
                if (!PBParse(state.bytes, holder) || holder.empty() || holder.front().number != YTKACEButtonRenderer) continue;
                std::vector<PBField> button;
                if (!PBParse(holder.front().bytes, button)) continue;
                bool named = false;
                const char *thumb = nullptr;
                for (const PBField &part : button) {
                    if (part.number == 2 && part.type == 2) named = true;
                    if (part.number == 17 && part.type == 2) {
                        if (PBContains(part.bytes, "dislike")) thumb = "thumb_down_24pt";
                        else if (PBContains(part.bytes, "like")) thumb = "thumb_up_24pt";
                    }
                }
                if (named || thumb == nullptr) continue;
                std::string icon = std::string(state.number == 2 ? "youtube_fill_experimental/"
                                                                 : "youtube_outline_experimental/") + thumb;
                button.insert(button.begin(), PBMessage(2, icon));
                holder.front().bytes = PBSerialize(button);
                state.bytes = PBSerialize(holder);
            }
            inner.bytes = PBSerialize(states);
        }
        field.bytes = PBSerialize(wrapper);
    }
    top.front().bytes = PBSerialize(toggle);
    return PBSerialize(top);
}

struct YTKACEBarItem {
    NSString *name;
    std::string barRenderer;
    std::string menuRenderer;
    NSUInteger position;
    bool hasMenu;  // YouTube sent a ⋯ version of it
};

// Where a bar keeps its buttons. The iPhone bar under the video lists them as
// field 1 entries with the renderer in field 10; the fullscreen bar as field
// 10 entries with it in field 15. menuItems limits which ⋯ items may move into
// the bar (nil: any).
struct YTKACEBarShape {
    uint64_t entryField;
    uint64_t rendererField;
    NSSet<NSString *> *menuItems;
    BOOL noteButtons;
    NSString *logName;
    BOOL menuFromOrder;  // the fullscreen bar: buttons in menuNames go into ⋯
    NSSet<NSString *> *menuNames;
};

const YTKACEBarShape YTKACEWatchBarShape = {YTKACEBarEntryField, YTKACEEntryRendererField, nil, YES, @"model", NO, nil};

bool YTKACERewriteBar(std::string &bar, NSArray<NSString *> *order, NSSet<NSString *> *hidden,
                      const YTKACEBarShape &shape = YTKACEWatchBarShape) {
    std::vector<PBField> fields;
    if (!PBParse(bar, fields)) return false;

    // The bar's buttons and the ⋯ entry.
    std::vector<YTKACEBarItem> items;
    NSInteger overflowIndex = -1;
    size_t firstEntry = SIZE_MAX;
    std::vector<PBField> overflowEntry, overflowRenderer, overflow;
    for (size_t index = 0; index < fields.size(); index++) {
        const PBField &field = fields[index];
        if (field.number != shape.entryField || field.type != 2) continue;
        firstEntry = MIN(firstEntry, index);
        std::string renderer;
        if (!YTKACEEntryRenderer(field.bytes, renderer, shape.rendererField)) return false;
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
        items.push_back({name, renderer, renderer, items.size(), false});
    }
    if (overflowIndex < 0 || overflow.empty()) return false;

    // Menu versions of the bar's buttons, and ⋯'s own items.
    std::vector<PBField> menuKept;
    for (const PBField &part : overflow) {
        if (part.type != 2) continue;
        NSString *name = YTKACERendererName(part.bytes);
        if (part.number == YTKACEOverflowCopyField) {
            for (YTKACEBarItem &item : items) {
                if (name != nil && [item.name isEqualToString:name]) {
                    item.menuRenderer = part.bytes;
                    item.hasMenu = true;
                }
            }
        } else if (part.number == YTKACEOverflowItemField) {
            if (name != nil && ![name isEqualToString:@"Overflow"] &&
                (shape.menuItems == nil || [shape.menuItems containsObject:name])) {
                items.push_back({name, YTKACEBarVersion(part.bytes), part.bytes, items.size(), true});
            } else {
                menuKept.push_back(part);
            }
        }
    }

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:@"Overflow"];
    for (const YTKACEBarItem &item : items) {
        if (item.name != nil) [names addObject:item.name];
    }
    if (shape.noteButtons) YTKACENoteActionBarButtons(names);
    YTKACEDebugLog(@"actionbar", @"%@ bar=%@", shape.logName, [names componentsJoinedByString:@","]);
    if (shape.menuFromOrder) {
        NSMutableArray<NSString *> *natural = [NSMutableArray array];
        for (const YTKACEBarItem &item : items) [natural addObject:item.name ?: @"?"];
        [natural addObject:@"Overflow"];
        YTKACESetFullscreenBarNames(natural);
    }
    if (order.count == 0 && hidden.count == 0 && shape.menuNames.count == 0) return false;

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

    // Buttons the user put in ⋯ go into its menu. The fullscreen ⋯ lists its
    // copies field as the menu, so only those go there, not copies of the bar.
    std::vector<PBField> movedIn;
    if (shape.menuFromOrder && shape.menuNames.count != 0) {
        std::vector<YTKACEBarItem> bar;
        for (const YTKACEBarItem &item : shown) {
            if (item.name != nil && [shape.menuNames containsObject:item.name] &&
                [@[@"Like", @"Dislike", @"Comments", @"Save", @"Share", @"Ask"] containsObject:item.name]) {
                movedIn.push_back(PBMessage(YTKACEOverflowCopyField,
                                            item.hasMenu ? item.menuRenderer : YTKACEMenuRow(item.barRenderer)));
            } else {
                bar.push_back(item);
            }
        }
        shown = bar;
    }
    menuKept.insert(menuKept.end(), movedIn.begin(), movedIn.end());

    if (shape.menuFromOrder) {
        NSMutableArray<NSString *> *drawn = [NSMutableArray array];
        for (const YTKACEBarItem &item : shown) [drawn addObject:item.name ?: @"?"];
        NSUInteger overflowAt = drawn.count;
        const NSUInteger overflowRank = [order indexOfObject:@"Overflow"];
        if (overflowRank != NSNotFound) {
            for (NSUInteger at = 0; at < drawn.count; at++) {
                const NSUInteger rank = [order indexOfObject:drawn[at]];
                if (rank != NSNotFound && rank > overflowRank) { overflowAt = at; break; }
            }
        }
        [drawn insertObject:@"Overflow" atIndex:overflowAt];
        YTKACESetFullscreenBarNames(drawn);
    }
    NSMutableArray<NSString *> *shownNames = [NSMutableArray array];
    for (const YTKACEBarItem &item : shown) [shownNames addObject:item.name ?: @"?"];
    YTKACEDebugLog(@"actionbar", @"%@ rewritten=%@,Overflow", shape.logName, [shownNames componentsJoinedByString:@","]);

    // ⋯ keeps its button and unknown items; its copies match the new bar.
    std::vector<PBField> newOverflow;
    bool copiesWritten = false;
    for (const PBField &part : overflow) {
        if (part.number == YTKACEOverflowItemField && part.type == 2) continue;
        if (part.number == YTKACEOverflowCopyField && part.type == 2) {
            if (!copiesWritten) {
                for (const PBField &kept : menuKept) newOverflow.push_back(kept);
                if (!shape.menuFromOrder) for (const YTKACEBarItem &item : shown) newOverflow.push_back(PBMessage(YTKACEOverflowCopyField, item.menuRenderer));
                copiesWritten = true;
            }
            continue;
        }
        newOverflow.push_back(part);
        // ⋯'s own items went right after its button.
        if (part.number == 1 && !copiesWritten) {
            for (const PBField &kept : menuKept) newOverflow.push_back(kept);
            if (!shape.menuFromOrder) for (const YTKACEBarItem &item : shown) newOverflow.push_back(PBMessage(YTKACEOverflowCopyField, item.menuRenderer));
            copiesWritten = true;
        }
    }
    if (!copiesWritten) {
        for (const PBField &kept : menuKept) newOverflow.push_back(kept);
        if (!shape.menuFromOrder) for (const YTKACEBarItem &item : shown) newOverflow.push_back(PBMessage(YTKACEOverflowCopyField, item.menuRenderer));
    }
    for (PBField &inner : overflowRenderer) {
        if (inner.number == YTKACEOverflowField) inner.bytes = PBSerialize(newOverflow);
    }
    for (PBField &part : overflowEntry) {
        if (part.number == shape.rendererField) part.bytes = PBSerialize(overflowRenderer);
    }

    std::vector<PBField> rebuilt;
    for (size_t index = 0; index < fields.size(); index++) {
        if (index == firstEntry) {
            // ⋯ goes where the order puts it in the fullscreen bar, last otherwise.
            size_t overflowAt = shown.size();
            const NSUInteger overflowRank = shape.menuFromOrder ? [order indexOfObject:@"Overflow"] : NSNotFound;
            if (overflowRank != NSNotFound) {
                for (size_t at = 0; at < shown.size(); at++) {
                    const NSUInteger rank = shown[at].name != nil ? [order indexOfObject:shown[at].name] : NSNotFound;
                    if (rank != NSNotFound && rank > overflowRank) {
                        overflowAt = at;
                        break;
                    }
                }
            }
            for (size_t at = 0; at <= shown.size(); at++) {
                if (at == overflowAt) rebuilt.push_back(PBMessage(shape.entryField, PBSerialize(overflowEntry)));
                if (at == shown.size()) break;
                rebuilt.push_back(PBMessage(shape.entryField,
                                            PBSerialize({PBMessage(shape.rendererField, shown[at].barRenderer)})));
            }
        }
        if (fields[index].number == shape.entryField && fields[index].type == 2) continue;
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
            if (!gone) items.push_back({name, entry.bytes, entry.bytes, items.size(), false});
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

// The fullscreen bar under the progress bar: same list as the bar under the
// video, in its own fields. Only ⋯ items the fullscreen editor knows can move in.
const uint64_t YTKACEFullscreenBarModelField = 386137609;
const YTKACEBarShape YTKACEFullscreenBarShape = {10, 15, nil, NO, @"fullscreen", YES, nil};

struct YTKACEBarPrefs {
    NSArray *fullscreenOrder;
    NSSet *fullscreenHidden;
    NSSet *fullscreenMenu;
};
static YTKACEBarPrefs YTKACECurrentBarPrefs;

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
        } else if (field.number == YTKACEFullscreenBarModelField) {
            std::string bar = field.bytes;
            YTKACEBarShape shape = YTKACEFullscreenBarShape;
            shape.menuItems = [NSSet setWithArray:@[@"Like", @"Dislike", @"Comments", @"Save", @"Share", @"Ask"]];
            shape.menuNames = YTKACECurrentBarPrefs.fullscreenMenu;
            if (YTKACERewriteBar(bar, YTKACECurrentBarPrefs.fullscreenOrder, YTKACECurrentBarPrefs.fullscreenHidden,
                                 shape)) {
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

// Extras YouTube attaches to a video in lists (search, Home, suggestions):
// - products: a row under the title with a bag icon, "1 product · Earns
//   commission", in the lockup's list of metadata rows, and the product card;
// - AI summaries: the "Summary" box under the video.
// The product card and the summary both come next to the video (field 18) in
// field 33. Field 34 only comes with them and leaves an empty expand arrow.
const uint64_t YTKACELockupVideoField = 18;
const uint64_t YTKACELockupAttachmentField = 33;
const uint64_t YTKACELockupAttachmentTokenField = 34;
const uint64_t YTKACEMetadataRowsField = 514549827;
const uint64_t YTKACEMetadataRowField = 1;

const char *const YTKACEProductMarkers[] = {
    "gstatic.com/shopping", "answer/6342839", "/bag_24pt",
};
// The summary's help link and feedback tag.
const char *const YTKACESummaryMarkers[] = {
    "answer/14089423", "PAfeedback_genai",
};

struct YTKACELockupStrip {
    bool products;
    bool summaries;
};

bool YTKACEHasAny(const std::string &data, const char *const *markers, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (PBContains(data, markers[i])) return true;
    }
    return false;
}

bool YTKACEHasProductMarker(const std::string &data) {
    return YTKACEHasAny(data, YTKACEProductMarkers,
                        sizeof(YTKACEProductMarkers) / sizeof(*YTKACEProductMarkers));
}

bool YTKACEHasSummaryMarker(const std::string &data) {
    return YTKACEHasAny(data, YTKACESummaryMarkers,
                        sizeof(YTKACESummaryMarkers) / sizeof(*YTKACESummaryMarkers));
}

bool YTKACEHasStripMarker(const std::string &data, const YTKACELockupStrip &strip) {
    return (strip.products && YTKACEHasProductMarker(data)) ||
        (strip.summaries && YTKACEHasSummaryMarker(data));
}

// Drops the bag-icon row, and the empty row YouTube puts before it as a gap.
int YTKACEStripProductRows(std::string &rows) {
    std::vector<PBField> fields;
    if (!PBParse(rows, fields)) return 0;
    int removed = 0;
    std::vector<PBField> kept;
    kept.reserve(fields.size());
    for (PBField &field : fields) {
        if (field.number == YTKACEMetadataRowField && field.type == 2 &&
            PBContains(field.bytes, "/bag_24pt")) {
            if (!kept.empty() && kept.back().number == YTKACEMetadataRowField &&
                kept.back().type == 2 && kept.back().bytes.empty()) {
                kept.pop_back();
            }
            removed++;
            continue;
        }
        kept.push_back(std::move(field));
    }
    if (removed != 0) rows = PBSerialize(kept);
    return removed;
}

int YTKACEStripLockups(std::string &message, int depth, const YTKACELockupStrip &strip) {
    if (depth > 40) return 0;
    std::vector<PBField> fields;
    if (!PBParse(message, fields)) return 0;
    bool lockup = false;
    bool attachment = false;
    for (const PBField &field : fields) {
        if (field.type != 2) continue;
        if (field.number == YTKACELockupVideoField) lockup = true;
        if (field.number == YTKACELockupAttachmentField && YTKACEHasStripMarker(field.bytes, strip)) {
            attachment = true;
        }
    }
    attachment = attachment && lockup;
    int removed = 0;
    std::vector<PBField> kept;
    kept.reserve(fields.size());
    for (PBField &field : fields) {
        if (attachment && (field.number == YTKACELockupAttachmentField ||
                           field.number == YTKACELockupAttachmentTokenField)) {
            if (field.number == YTKACELockupAttachmentField) removed++;
            continue;
        }
        if (field.type == 2 && YTKACEHasStripMarker(field.bytes, strip)) {
            if (field.number == YTKACEMetadataRowsField) {
                if (strip.products) removed += YTKACEStripProductRows(field.bytes);
            } else {
                removed += YTKACEStripLockups(field.bytes, depth + 1, strip);
            }
        }
        kept.push_back(std::move(field));
    }
    if (removed != 0) message = PBSerialize(kept);
    return removed;
}

}  // namespace

static bool YTKACEDataHasAny(NSData *data, const char *const *markers, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (memmem(data.bytes, data.length, markers[i], strlen(markers[i])) != NULL) return true;
    }
    return false;
}

static NSData *YTKACEWithoutProducts(NSData *data, NSString *source) {
    if (data.length == 0) return data;
    YTKACELockupStrip strip;
    strip.products = YTKACEFeatureEnabled(@"YTKACE.Preference.Overlay.ProductsHidden") &&
        YTKACEDataHasAny(data, YTKACEProductMarkers,
                         sizeof(YTKACEProductMarkers) / sizeof(*YTKACEProductMarkers));
    strip.summaries = YTKACEFeatureEnabled(@"YTKACE.Preference.Feed.AISummariesHidden") &&
        YTKACEDataHasAny(data, YTKACESummaryMarkers,
                         sizeof(YTKACESummaryMarkers) / sizeof(*YTKACESummaryMarkers));
    if (!strip.products && !strip.summaries) return data;
    std::string message((const char *)data.bytes, data.length);
    int removed = YTKACEStripLockups(message, 0, strip);
    YTKACEDebugLog(@"products", @"%@ removed %d items (products=%d summaries=%d)",
                   source, removed, strip.products, strip.summaries);
    if (removed == 0) return data;
    return [NSData dataWithBytes:message.data() length:message.size()];
}

static NSData *YTKACERewrittenResponse(NSData *data) {
    static const char marker[] = "id.video.like.button";
    if (data.length == 0 || !YTKACEFeatureEnabled(@"YTKACE.Preference.Enabled")) return data;
    data = YTKACEWithoutProducts(data, @"watch");
    NSArray *order = YTKACEPreferenceObject(@"YTKACE.Preference.ActionBar.Order");
    if (![order isKindOfClass:NSArray.class]) order = @[];
    NSMutableSet *hidden = [NSMutableSet set];
    for (NSString *name in YTKACEBarNames()) {
        if (YTKACEFeatureEnabled([NSString stringWithFormat:@"YTKACE.Preference.ActionBar.%@Hidden", name])) {
            [hidden addObject:name];
        }
    }
    NSArray *fullscreenOrder = YTKACEPreferenceObject(@"YTKACE.Preference.Fullscreen.Order");
    NSMutableSet *fullscreenHidden = [NSMutableSet set];
    for (NSString *name in @[@"Like", @"Dislike", @"Save", @"Share", @"Ask"]) {
        if (YTKACEFeatureEnabled([NSString stringWithFormat:@"YTKACE.Preference.Fullscreen.%@Hidden", name])) {
            [fullscreenHidden addObject:name];
        }
    }
    NSArray *fullscreenMenu = YTKACEPreferenceObject(@"YTKACE.Preference.Fullscreen.InMenu");
    YTKACECurrentBarPrefs = {[fullscreenOrder isKindOfClass:NSArray.class] ? fullscreenOrder : @[], fullscreenHidden,
                             [NSSet setWithArray:[fullscreenMenu isKindOfClass:NSArray.class] ? fullscreenMenu : @[]]};
    // With nothing moved or hidden this only notes which buttons exist.
    if (memmem(data.bytes, data.length, marker, sizeof(marker) - 1) == NULL) return data;
    std::string message((const char *)data.bytes, data.length);
    if (!YTKACERewriteMessage(message, 0, order, hidden)) return data;
    return [NSData dataWithBytes:message.data() length:message.size()];
}

static IMP OriginalGetWatchInit;
static IMP OriginalGetWatchMerge;
static IMP OriginalWatchNextInit;
static IMP OriginalSearchInit;
static IMP OriginalBrowseInit;

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

static id YTKACESearchInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Enabled")) data = YTKACEWithoutProducts(data, @"search");
    return ((id (*)(id, SEL, id, id, NSError **))OriginalSearchInit)(receiver, selector, data, registry, error);
}

static id YTKACEBrowseInit(id receiver, SEL selector, NSData *data, id registry, NSError **error) {
    if (YTKACEFeatureEnabled(@"YTKACE.Preference.Enabled")) data = YTKACEWithoutProducts(data, @"browse");
    return ((id (*)(id, SEL, id, id, NSError **))OriginalBrowseInit)(receiver, selector, data, registry, error);
}

__attribute__((constructor)) static void YTKACEInstallActionBarModelHooks(void) {
    YTKACEInstallInstanceHook(@"YTISearchResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)YTKACESearchInit, &OriginalSearchInit);
    YTKACEInstallInstanceHook(@"YTIBrowseResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)YTKACEBrowseInit, &OriginalBrowseInit);
    YTKACEInstallInstanceHook(@"YTIGetWatchResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)YTKACEGetWatchInit, &OriginalGetWatchInit);
    YTKACEInstallInstanceHook(@"YTIGetWatchResponse", @"mergeFromData:extensionRegistry:",
                              (IMP)YTKACEGetWatchMerge, &OriginalGetWatchMerge);
    YTKACEInstallInstanceHook(@"YTIWatchNextResponse", @"initWithData:extensionRegistry:error:",
                              (IMP)YTKACEWatchNextInit, &OriginalWatchNextInit);
}
