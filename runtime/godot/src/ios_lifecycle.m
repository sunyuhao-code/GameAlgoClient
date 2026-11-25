#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern int32_t gamealgo_godot_lifecycle_update(int32_t foreground, int64_t now_ms,
    const char *timestamp, const char *local, const char *next_event_id);

extern void gamealgo_godot_duration_sample(int32_t foreground, int64_t now_ms, const char *timestamp, const char *local);

static NSString *GameAlgoTimestamp(NSDate *date, BOOL local) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = local ? NSTimeZone.localTimeZone : [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = local ? @"yyyy-MM-dd'T'HH:mm:ss.SSSxxx" : @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
    return [formatter stringFromDate:date];
}

@interface GameAlgoGodotLifecycle : NSObject
@property(nonatomic) BOOL foreground;
@property(nonatomic, strong) NSTimer *heartbeat;
@property(nonatomic, strong) NSTimer *retry;
@property(nonatomic) NSTimeInterval lastCheckpoint;
- (void)report;
- (void)stop;
@end

@implementation GameAlgoGodotLifecycle
- (instancetype)init {
    self = [super init];
    if (self) {
        _foreground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
        _lastCheckpoint = NSDate.date.timeIntervalSince1970;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(foreground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [center addObserver:self selector:@selector(background:) name:UIApplicationWillTerminateNotification object:nil];
        if (@available(iOS 13.0, *)) {
            [center addObserver:self selector:@selector(sceneBackground:) name:UISceneDidEnterBackgroundNotification object:nil];
            [center addObserver:self selector:@selector(foreground:) name:UISceneWillEnterForegroundNotification object:nil];
        }
        // Do not observe resign-active: ads, Control Center and permission
        // dialogs may make the app inactive without putting it in background.
        __weak GameAlgoGodotLifecycle *weakSelf = self;
        _heartbeat = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            GameAlgoGodotLifecycle *observer = weakSelf;
            if (!observer) return;
            NSDate *date = NSDate.date;
            NSTimeInterval now = date.timeIntervalSince1970;
            BOOL foreground = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
            gamealgo_godot_duration_sample(foreground ? 1 : 0, (int64_t)(now * 1000.0),
                GameAlgoTimestamp(date, NO).UTF8String, GameAlgoTimestamp(date, YES).UTF8String);
            if (now - observer.lastCheckpoint >= 10.0) {
                observer.lastCheckpoint = now;
                observer.foreground = foreground;
                [observer report];
            }
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

- (void)sceneBackground:(NSNotification *)notification API_AVAILABLE(ios(13.0)) {
    if (![notification.object isKindOfClass:UIScene.class]) return;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene != notification.object &&
            (scene.activationState == UISceneActivationStateForegroundActive ||
             scene.activationState == UISceneActivationStateForegroundInactive)) return;
    }
    [self background:notification];
}

- (void)report {
    [self.retry invalidate];
    self.retry = nil;
    NSDate *now = NSDate.date;
    NSString *utc = GameAlgoTimestamp(now, NO);
    NSString *local = GameAlgoTimestamp(now, YES);
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

static NSMutableSet<NSNumber *> *GameAlgoActiveBackgroundTasks(void) {
    static NSMutableSet<NSNumber *> *tasks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tasks = [NSMutableSet new];
    });
    return tasks;
}

void gamealgo_godot_end_background_task(uintptr_t identifier) {
    UIBackgroundTaskIdentifier taskId = (UIBackgroundTaskIdentifier)identifier;
    if (taskId == UIBackgroundTaskInvalid) return;
    BOOL shouldEnd = NO;
    NSMutableSet<NSNumber *> *tasks = GameAlgoActiveBackgroundTasks();
    @synchronized(tasks) {
        NSNumber *key = @(taskId);
        if ([tasks containsObject:key]) {
            [tasks removeObject:key];
            shouldEnd = YES;
        }
    }
    if (shouldEnd) {
        [UIApplication.sharedApplication endBackgroundTask:taskId];
    }
}

uintptr_t gamealgo_godot_begin_background_task(void) {
    NSMutableSet<NSNumber *> *tasks = GameAlgoActiveBackgroundTasks();
    __block UIBackgroundTaskIdentifier taskId = UIBackgroundTaskInvalid;
    @synchronized(tasks) {
        taskId = [UIApplication.sharedApplication
            beginBackgroundTaskWithName:@"GameAlgo event flush"
                      expirationHandler:^{
                          gamealgo_godot_end_background_task((uintptr_t)taskId);
                      }];
        if (taskId == UIBackgroundTaskInvalid) {
            return 0;
        }
        [tasks addObject:@(taskId)];
    }
    return (uintptr_t)taskId;
}

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
