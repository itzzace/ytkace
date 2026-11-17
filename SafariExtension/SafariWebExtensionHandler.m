#import <Foundation/Foundation.h>

// Safari needs a native handler even though all the work happens in content.js.
@interface SafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SafariWebExtensionHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSExtensionItem *response = [NSExtensionItem new];
    response.userInfo = @{@"message": @{}};
    [context completeRequestReturningItems:@[response] completionHandler:nil];
}

@end
