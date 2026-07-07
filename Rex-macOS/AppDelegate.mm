#import "AppDelegate.h"
#import "GameViewController.h"
#import "Audio/AudioEngine.h"

@interface AppDelegate ()
@property (strong) NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // T7: initialize audio engine at startup to avoid ~100ms hitch on first hit.
    [[[AudioEngine alloc] init] startupInit];

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
