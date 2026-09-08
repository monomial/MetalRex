#pragma once
#import <MetalKit/MetalKit.h>
class World;

@interface RexRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat;

- (void)updateDrawableSize:(CGSize)size;

- (void)drawWorld:(World*)world
           inView:(MTKView*)view
    commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

// Blits the next presented drawable to a PNG at `path` once the GPU finishes
// that frame. Requires view.framebufferOnly == NO. Used by --capture-out=
// launch-arg driven smoke testing (no interactive display session needed —
// this reads the app's own drawable texture, not the screen).
- (void)captureNextFrameToPath:(NSString*)path;

// Explicit set, alongside the toggle: a recorded clip must not ship with the
// tuning bars over it, and a toggle cannot express "off regardless".
- (void)setDebugHUDVisible:(BOOL)visible;

// Capture requests whose PNG has been requested but not yet written. A frame
// capture holds a full-drawable staging buffer until its write finishes, and
// nothing in the normal render loop waits for that, so a caller recording
// every frame (RexGameHost's clip capture) reads this to stall itself rather
// than retaining an unbounded queue of frames.
- (int)pendingCaptureWrites;

// Shows/hides the macOS-only gyro/stick tuning debug overlay (a no-op on
// tvOS, where that overlay is never compiled in). Visible by default.
- (void)toggleDebugHUD;

@end
