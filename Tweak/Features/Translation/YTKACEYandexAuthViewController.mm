#import "YTKACEYandexAuthViewController.h"
#import "YTKACEVOTClient.h"
#import "YTKACEVOTLog.h"
#import "../../Runtime/Localization.h"
#import <WebKit/WebKit.h>

static NSString * const kYandexOAuthURL = @"https://oauth.yandex.ru/authorize?client_id=1666fbe22f3749c581002a4f97b2592d&response_type=token&redirect_uri=https://oauth.yandex.ru/verification_code";

@interface YTKACEYandexAuthViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, assign) BOOL isFinishing;
@end

@implementation YTKACEYandexAuthViewController

+ (void)presentFromViewController:(UIViewController *)viewController
                       completion:(nullable YTKACEYandexAuthCompletion)completion {
    YTKACEYandexAuthViewController *authVC = [[YTKACEYandexAuthViewController alloc] init];
    authVC.completion = completion;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:authVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [viewController presentViewController:nav animated:YES completion:nil];
}

+ (void)openSafariAuth {
    NSURL *url = [NSURL URLWithString:kYandexOAuthURL];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTKACELocalized(@"Yandex Login");
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIBarButtonItem *cancelItem = [[UIBarButtonItem alloc] initWithTitle:YTKACELocalized(@"Cancel")
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(handleCancel)];
    self.navigationItem.leftBarButtonItem = cancelItem;

    _activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activityIndicator.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_activityIndicator];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    _webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _webView.navigationDelegate = self;
    [self.view addSubview:_webView];

    NSURL *url = [NSURL URLWithString:kYandexOAuthURL];
    [_webView loadRequest:[NSURLRequest requestWithURL:url]];
    [_activityIndicator startAnimating];
}

- (void)handleCancel {
    [self dismissViewControllerAnimated:YES completion:^{
        if (self.completion) {
            self.completion(NO, nil, @"Cancelled");
        }
    }];
}

- (void)finishWithToken:(NSString *)rawToken {
    if (self.isFinishing) return;
    self.isFinishing = YES;

    NSString *token = [YTKACEVOTClient cleanOAuthToken:rawToken];
    if (token.length == 0) return;

    YTKACEVOTLog(@"OAuth", @"Extracted Yandex OAuth token from webview. Validating...");
    [self.activityIndicator startAnimating];

    [YTKACEVOTClient validateAndSaveToken:token completion:^(BOOL success, NSString * _Nullable login, NSString * _Nullable errorMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activityIndicator stopAnimating];
            [self dismissViewControllerAnimated:YES completion:^{
                if (self.completion) {
                    self.completion(success, login, errorMessage);
                }
            }];
        });
    }];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *urlStr = url.absoluteString;

    if ([urlStr containsString:@"oauth.yandex.ru/verification_code"]) {
        NSString *fragment = url.fragment ?: @"";
        NSString *full = [NSString stringWithFormat:@"%@#%@", urlStr, fragment];
        NSString *token = [YTKACEVOTClient cleanOAuthToken:full];
        if (token.length > 0) {
            decisionHandler(WKNavigationActionPolicyCancel);
            [self finishWithToken:token];
            return;
        }
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    (void)navigation;
    [self.activityIndicator startAnimating];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    [self.activityIndicator stopAnimating];

    NSString *urlStr = webView.URL.absoluteString;
    if ([urlStr containsString:@"oauth.yandex.ru/verification_code"]) {
        NSString *fragment = webView.URL.fragment ?: @"";
        NSString *full = [NSString stringWithFormat:@"%@#%@", urlStr, fragment];
        NSString *token = [YTKACEVOTClient cleanOAuthToken:full];
        if (token.length > 0) {
            [self finishWithToken:token];
            return;
        }

        [webView evaluateJavaScript:@"window.location.hash" completionHandler:^(id result, NSError *error) {
            (void)error;
            if ([result isKindOfClass:[NSString class]]) {
                NSString *hash = (NSString *)result;
                NSString *t = [YTKACEVOTClient cleanOAuthToken:hash];
                if (t.length > 0) {
                    [self finishWithToken:t];
                    return;
                }
            }
        }];
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)navigation;
    (void)error;
    [self.activityIndicator stopAnimating];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)navigation;
    (void)error;
    [self.activityIndicator stopAnimating];
}

@end
