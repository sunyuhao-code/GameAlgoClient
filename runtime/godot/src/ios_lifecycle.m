#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern int32_t gamealgo_godot_lifecycle_update(int32_t foreground, int64_t now_ms,
    const char *timestamp, const char *local, const char *next_event_id);

@interface GameAlgoGodotLifecycle : NSObject
@property(nonatomic) BOOL foreground;
@property(nonatomic, strong) NSTimer *heartbeat;
@property(nonatomic, strong) NSTimer *retry;
- (void)report;
- (void)stop;
@end

@implementation GameAlgoGodotLifecycle
- (instancetype)init {
    self = [super init];
    if (self) {
        _foreground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(foreground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        // Do not observe resign-active: ads, Control Center and permission
        // dialogs may make the app inactive without putting it in background.
        __weak GameAlgoGodotLifecycle *weakSelf = self;
        _heartbeat = [NSTimer timerWithTimeInterval:10.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            GameAlgoGodotLifecycle *observer = weakSelf;
            if (observer.foreground) [observer report];
        }];
        [NSRunLoop.mainRunLoop addTimer:_heartbeat forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)foreground:(NSNotification *)notification {
    self.foreground = YES;
    [self report];
}

- (void)background:(NSNotification *)notification {
    self.foreground = NO;
    // Synchronous queue+marker commit, followed by the existing native flush
    // with its bounded iOS background execution task. No Godot frame required.
    [self report];
}

- (void)report {
    [self.retry invalidate];
    self.retry = nil;
    NSDate *now = NSDate.date;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    NSString *utc = [formatter stringFromDate:now];
    formatter.timeZone = NSTimeZone.localTimeZone;
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSxxx";
    NSString *local = [formatter stringFromDate:now];
    NSString *eventId = NSUUID.UUID.UUIDString.lowercaseString;
    int32_t accepted = gamealgo_godot_lifecycle_update(self.foreground ? 1 : 0,
        (int64_t)(now.timeIntervalSince1970 * 1000.0), utc.UTF8String, local.UTF8String, eventId.UTF8String);
    if (!accepted) {
        __weak GameAlgoGodotLifecycle *weakSelf = self;
        self.retry = [NSTimer timerWithTimeInterval:0.1 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf report];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.retry forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.heartbeat invalidate];
    [self.retry invalidate];
    self.heartbeat = nil;
    self.retry = nil;
}
@end

static GameAlgoGodotLifecycle *observer;

int32_t gamealgo_godot_lifecycle_install(void) {
    void (^install)(void) = ^{
        if (!observer) observer = [[GameAlgoGodotLifecycle alloc] init];
        // Reconfiguration replaces the Rust backend but not the observer.
        observer.foreground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
        [observer report];
    };
    if (NSThread.isMainThread) install();
    else dispatch_sync(dispatch_get_main_queue(), install);
    return 1;
}

void gamealgo_godot_lifecycle_uninstall(void) {
    void (^uninstall)(void) = ^{
        [observer stop];
        observer = nil;
    };
    if (NSThread.isMainThread) uninstall();
    else dispatch_sync(dispatch_get_main_queue(), uninstall);
}
