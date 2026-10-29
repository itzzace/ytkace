// macOS regression test: node Tests/test_queue_membership.js
// Requires Node.js and the Xcode command-line tools (Foundation and clang++).
// Compile the actual queue functions with UI/network dependencies stubbed.
const fs = require('fs');
const cp = require('child_process');
const path = require('path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Tweak/Features/Queue/QueueHooks.mm'), 'utf8');
function extract(name) {
 const re = new RegExp('static [^;{}]+\\b' + name + '\\([^;{}]*\\)\\s*\\{', 'g');
 const m = re.exec(source); if (!m) throw Error('Missing definition: ' + name);
 let depth = 1, end = re.lastIndex;
 while (depth && end < source.length) {const c = source[end++]; if(c === '{') depth++; if(c === '}') depth--;}
 return source.slice(m.index, end);
}
const harness = String.raw`#import <Foundation/Foundation.h>
static NSMutableArray<NSDictionary *> *items;
static NSString *playing;
static BOOL YTKACEQueuePanelInjected = YES;
static NSMutableArray *YTKACEQueue(void) { return items; }
static NSString *YTKACEQueueCurrentVideoID(void) { return playing; }
static void YTKACEQueueSave(void) {}
static void YTKACEQueueFetchTitle(NSString *s) {}
static NSString *YTKACELocalized(NSString *s) { return s; }
static void YTKACEShowNotice(NSString *s) {}
static void YTKACEQueueAppendToController(NSDictionary *e, NSUInteger i) {}
static void YTKACEQueueRebuildWatchPage(void) {}
static void YTKACEQueueRefreshPanel(void) {}
` + extract('YTKACEQueueIndexOfVideo') + '\n' + extract('YTKACEQueueEnsureCurrent') + '\n' + extract('YTKACEQueueAdd') + String.raw`
static int failures = 0;
static void check(BOOL ok, NSString *label) { printf("%s %s\n", ok ? "PASS" : "FAIL", label.UTF8String); if(!ok) failures++; }
int main() { @autoreleasepool {
 items = [NSMutableArray array]; playing = @"current0000";
 YTKACEQueueEnsureCurrent(); check(items.count == 0, @"refresh leaves empty queue empty");
 YTKACEQueueAdd(@"chosen00001", @"Chosen", NO);
 check(items.count == 2 && [items[0][@"videoId"] isEqual:playing], @"first user add anchors currently playing video");
 for(int i = 0; i < 25; i++) {playing = [NSString stringWithFormat:@"other%06d", i]; YTKACEQueueEnsureCurrent();}
 check(items.count == 2, [NSString stringWithFormat:@"25 unrelated refreshes do not grow queue (count=%lu)", (unsigned long)items.count]);
 items = [@[@{@"videoId": @"current0000"}, @{@"videoId": @"chosen00001"}] mutableCopy];
 playing = @"current0000";
 YTKACEQueueAdd(@"chosen00002", @"Last", NO);
 YTKACEQueueAdd(@"chosen00003", @"Next", YES);
 check(items.count == 4 && [items[1][@"videoId"] isEqual:@"chosen00003"] && [items[3][@"videoId"] isEqual:@"chosen00002"], @"play next and play last preserve requested order");
 YTKACEQueueAdd(@"chosen00002", @"Move next", YES);
 check(items.count == 4 && [items[1][@"videoId"] isEqual:@"chosen00002"], @"requeue moves chosen video without duplication");
 playing = @"unrelated00"; YTKACEQueueAdd(@"chosen00004", @"Chosen", NO);
 check(items.count == 5 && YTKACEQueueIndexOfVideo(@"unrelated00") == NSNotFound, @"adding to existing queue does not import unrelated current video");
 return failures ? 1 : 0;
}}
`;
const work = fs.mkdtempSync(path.join(process.env.TMPDIR || '/tmp', 'ytkace-queue-test-'));
try {
const file = path.join(work, 'queue-test.mm'); fs.writeFileSync(file, harness);
cp.execFileSync('xcrun', ['clang++','-fobjc-arc','-framework','Foundation',file,'-o',path.join(work,'queue-test')], {stdio:'pipe'});
const result = cp.spawnSync(path.join(work, 'queue-test'), [], {encoding:'utf8'});
process.stdout.write(result.stdout); process.stderr.write(result.stderr);
process.exitCode = result.status ?? 1;
} finally {
 fs.rmSync(work, {recursive:true, force:true});
}
