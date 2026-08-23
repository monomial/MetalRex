#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "RexGameHost.h"
#include <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--headless-smoke") == 0) {
            RexGameHost *host = [[RexGameHost alloc] initHeadless];
            for (int i = 0; i < 120; ++i) {
                [host advanceFrame:1.f / 120.f];
            }
            return 0;
        }
        static AppDelegate *delegate = nil;
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
