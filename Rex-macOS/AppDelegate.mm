#import "AppDelegate.h"
#import "GameViewController.h"

@interface AppDelegate ()
@property (strong) NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Audio engine now lives in RexGameHost (constructed below via
    // GameViewController), so it warms up at the same launch-time moment
    // this used to pre-warm a throwaway instance for.
    NSRect frame = NSMakeRect(0, 0, 960, 720);
    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled
                           |NSWindowStyleMaskClosable
                           |NSWindowStyleMaskMiniaturizable
                           |NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.title = @"MetalRex";
    self.window.releasedWhenClosed = NO;

    GameViewController *vc = [[GameViewController alloc] init];
    self.window.contentViewController = vc;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window orderFrontRegardless];
    [NSApp activate];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
