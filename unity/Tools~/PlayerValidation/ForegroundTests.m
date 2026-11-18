#import <XCTest/XCTest.h>

@interface GamePropelForegroundTests : XCTestCase
@end

@implementation GamePropelForegroundTests
- (void)testActivateExistingProbe {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.gamepropel.unityplayersdk"];
    [app activate];
    XCTAssertEqual(app.state, XCUIApplicationStateRunningForeground);
}
@end
