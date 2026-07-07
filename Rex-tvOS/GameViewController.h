#import <UIKit/UIKit.h>

@interface GameViewController : UIViewController
- (void)pauseRendering;
- (void)resumeRendering;
- (void)releaseGPUResources;
@end
