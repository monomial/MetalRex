#import <MetalKit/MetalKit.h>
class World;
struct LoadedCharacter;

static constexpr int kBrawlerMaxPlayers = 4;
static constexpr int kBrawlerPerkTypeCount = 17;

struct BrawlerPerkSummary {
    uint8_t counts[kBrawlerPerkTypeCount];
};

// Shared Metal renderer — used by macOS, iOS, and tvOS GameViewControllers.
// Draws colored ground-plane quads for entities without loaded characters;
// draws lit skinned meshes for entities whose faction has a LoadedCharacter.
@interface BrawlerRenderer : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat;

- (void)updateDrawableSize:(CGSize)size;

// Supply loaded character meshes for skinned rendering. Either may be nil (falls back to quads).
- (void)setPlayerCharacter:(LoadedCharacter*)player
               enemyCharacter:(LoadedCharacter*)enemy;

// Lives shown in HUD. Set each frame before drawWorld:.
@property (nonatomic) int livesRemaining;

// 0-based room number — selects the room color palette. Set at room load.
@property (nonatomic) int roomIndex;
@property (nonatomic) int totalRooms;
@property (nonatomic) int scrapCount;
@property (nonatomic) int comboCount;
@property (nonatomic) int scoreValue;
@property (nonatomic, copy) NSString *shopPrompt;
@property (nonatomic) float curseMult;

// Shared phase overlay rendered into the Metal drawable, so macOS/iOS/tvOS
// present the same text and the smoke harness can capture it.
- (void)setOverlayVisible:(BOOL)visible
                    title:(NSString*)title
                 subtitle:(NSString*)subtitle
                  choiceA:(NSString*)choiceA
                  choiceB:(NSString*)choiceB;

- (void)setOverlayVisible:(BOOL)visible
                    title:(NSString*)title
                 subtitle:(NSString*)subtitle
                  choiceA:(NSString*)choiceA
                  choiceB:(NSString*)choiceB
                statLines:(NSArray<NSString*>*)statLines;

- (void)setPerkSummary:(BrawlerPerkSummary)summary
             forPlayer:(int)playerIndex;

// Call once per frame after World::update(). Encodes draw calls into cmd.
- (void)drawWorld:(World*)world
            inView:(MTKView*)view
     commandBuffer:(id<MTLCommandBuffer>)cmd;

// Write the next rendered frame to a PNG at path (async, off-main). Used by
// the --autotest smoke mode. Requires view.framebufferOnly == NO.
- (void)captureNextFrameToPath:(NSString*)path;

// Post-FX triggers: brief radial blur on a landed hit (strength 0..1) and a
// red edge vignette when the player takes damage. Both decay automatically.
- (void)triggerHitBlur:(float)strength;
- (void)triggerDamageFlash;
- (void)beginFinalKillZoomAt:(simd_float3)pos duration:(float)seconds;

// Spawn a radial particle burst (hit sparks, telegraphs, clears) at a world
// position. Rendered as additive camera-facing billboards next frame.
- (void)spawnBurstAt:(simd_float3)pos
               count:(int)count
               speed:(float)speed
                size:(float)size
               color:(simd_float4)color;

@end
