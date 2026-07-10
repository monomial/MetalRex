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

// Shows/hides the macOS-only gyro/stick tuning debug overlay (a no-op on
// tvOS, where that overlay is never compiled in). Visible by default.
- (void)toggleDebugHUD;

@end
