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
- (void)saveCheckpoint:(NSString *)name {
    NSString *root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *destination = [root stringByAppendingPathComponent:name];
    NSFileManager *files = NSFileManager.defaultManager;
    [files createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *file in @[@"session.json", @"session.journal"]) {
        NSString *source = [root stringByAppendingPathComponent:file];
        if ([files fileExistsAtPath:source]) {
            if (![files copyItemAtPath:source toPath:[destination stringByAppendingPathComponent:file] error:nil]) abort();
        }
    }
}

- (void)runLifecycleCommand:(NSString *)action scene:(UIScene *)scene {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSString *root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [action writeToFile:[root stringByAppendingPathComponent:@"last-command"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if ([action isEqualToString:@"lifecycle"]) {
        // Deliver Scene-only edges without UIApplication changing state. Copy
        // durable bytes synchronously before any timer or network task runs.
        [center postNotificationName:UISceneDidEnterBackgroundNotification object:scene];
        [self saveCheckpoint:@"scene-only"];
        [center postNotificationName:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [self saveCheckpoint:@"app-duplicate"];
        [center postNotificationName:UISceneWillEnterForegroundNotification object:scene];
        [center postNotificationName:UIApplicationWillTerminateNotification object:UIApplication.sharedApplication];
        [center postNotificationName:UIApplicationWillTerminateNotification object:UIApplication.sharedApplication];
        [self saveCheckpoint:@"rapid-terminate"];
        [center postNotificationName:UISceneWillEnterForegroundNotification object:scene];
        [self saveCheckpoint:@"scene-resume"];
    } else if ([action isEqualToString:@"terminate"]) {
        [center postNotificationName:UIApplicationWillTerminateNotification object:UIApplication.sharedApplication];
        [self saveCheckpoint:@"terminate-only"];
    }
}

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
    // Test-only commands run on UIKit's main run loop; production SDK exports
    // and game lifecycle delegates remain unchanged.
    NSString *commandPath = [directory stringByAppendingPathComponent:@"command"];
    __weak SmokeSceneDelegate *weakSelf = self;
    NSTimer *commands = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        NSString *action = [NSString stringWithContentsOfFile:commandPath encoding:NSUTF8StringEncoding error:nil];
        if (!action.length) return;
        [NSFileManager.defaultManager removeItemAtPath:commandPath error:nil];
        SmokeSceneDelegate *delegate = weakSelf;
        [delegate runLifecycleCommand:action scene:delegate.window.windowScene];
    }];
    [NSRunLoop.mainRunLoop addTimer:commands forMode:NSRunLoopCommonModes];
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
