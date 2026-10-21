#import <UIKit/UIKit.h>

extern int32_t gamealgo_smoke_start(const char *path, int64_t now_ms);

@interface SmokeDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation SmokeDelegate
@end

@interface SmokeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SmokeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.whiteColor;
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [directory stringByAppendingPathComponent:@"session.json"];
    if (!gamealgo_smoke_start(path.UTF8String, (int64_t)(NSDate.date.timeIntervalSince1970 * 1000.0))) {
        abort();
    }
    // A full-screen surrogate ad is presented while Godot would be paused.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIViewController *ad = [[UIViewController alloc] init];
        ad.modalPresentationStyle = UIModalPresentationFullScreen;
        ad.view.backgroundColor = UIColor.orangeColor;
        [root presentViewController:ad animated:NO completion:^{
            [@"ad-visible" writeToFile:[directory stringByAppendingPathComponent:@"ready"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }];
    });
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeDelegate.class));
    }
}
