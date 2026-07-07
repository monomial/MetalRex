#import "BrawlerRenderer.h"
#import <simd/simd.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#include "Simulation/World.h"
#include "Simulation/RoomBounds.h"
#include "Simulation/Difficulty.h"
#include "Simulation/Systems/ScreenShakeSystem.h"
#include "Simulation/Systems/WaveSystem.h"
#include "Assets/CharacterLoader.h"
#include "ParticleSim.h"

typedef struct { simd_float4x4 mvp; simd_float4 color; } DrawUniforms;
typedef struct { simd_float4x4 mvp; } TextureUniforms;
// These two must match ParticleInstance / ParticleUniforms in Brawler.metal.
typedef struct { simd_float3 pos; float size; simd_float4 color; } ParticleInstanceGPU;
typedef struct { simd_float4x4 vp; simd_float3 camRight; simd_float3 camUp; } ParticleUniformsGPU;
// Must match FloorUniforms in Brawler.metal.
typedef struct { simd_float4x4 mvp; simd_float4 baseColor; simd_float4 lineColor;
                 simd_float4 marking; simd_float2 center; simd_float2 size; } FloorUniformsGPU;
// Must match PostUniforms in Brawler.metal.
typedef struct { float hitBlur; float damageFlash; } PostUniformsGPU;

// Per-room palette — indexed by roomIndex, wraps if there are more rooms.
typedef struct {
    simd_float4 floorBase, floorLine, wall;
    MTLClearColor clear;
    simd_float4 marking;
} RoomPalette;
// The last palette (violet) is reserved for the boss room — the delegate
// passes kBossPaletteIndex for it and cycles the others for normal rooms.
static const RoomPalette kRoomPalettes[] = {
    {{0.115f,0.120f,0.125f,1}, {0.185f,0.190f,0.195f,1}, {0.245f,0.285f,0.330f,1}, {0.045,0.050,0.060,1}, {0.86f,0.68f,0.22f,1}}, // downtown street
    {{0.145f,0.135f,0.125f,1}, {0.225f,0.205f,0.180f,1}, {0.430f,0.205f,0.140f,1}, {0.075,0.060,0.050,1}, {0.72f,0.70f,0.62f,1}}, // brick alley
    {{0.125f,0.130f,0.135f,1}, {0.205f,0.215f,0.220f,1}, {0.315f,0.335f,0.350f,1}, {0.055,0.060,0.065,1}, {0.92f,0.74f,0.18f,1}}, // subway platform
    {{0.075f,0.080f,0.090f,1}, {0.145f,0.155f,0.170f,1}, {0.155f,0.180f,0.220f,1}, {0.030,0.035,0.048,1}, {0.18f,0.86f,0.95f,1}}, // rooftop night
    {{0.130f,0.125f,0.115f,1}, {0.215f,0.200f,0.175f,1}, {0.390f,0.300f,0.205f,1}, {0.070,0.060,0.048,1}, {0.95f,0.42f,0.12f,1}}, // industrial yard
    {{0.120f,0.080f,0.145f,1}, {0.215f,0.135f,0.245f,1}, {0.340f,0.215f,0.390f,1}, {0.050,0.030,0.070,1}, {0.88f,0.28f,1.00f,1}}, // boss violet
};
static const int kNumRoomPalettes = sizeof(kRoomPalettes) / sizeof(kRoomPalettes[0]);
// Layout must match SkinnedUniforms in SkinnedMesh.metal.
typedef struct { simd_float4x4 mvp; simd_float4 color; float tintStrength; } SkinnedUniforms;

// Faction tint blend into the character texture. Enemies share the player mesh
// for now, so they get a heavy tint to stay visually distinct.
static const float kPlayerTintStrength = 0.08f;
static const float kEnemyTintStrength  = 0.15f; // subtle — enemies have their own model now

// Auto-scale: characters should be ~150 game units tall.
// Computed from meshHeight at runtime; this is the fallback.
static const float kTargetCharHeight = 150.0f;

// Builds the model matrix for a character at game position (x, y).
// scale:       uniform world scale
// yMin:        lowest Y vertex in model space — shifted to Z=0 so feet touch the floor.
// facingAngle: atan2(vy,vx) of movement direction. Default facing (no rotation) is -Y
//              (toward camera); offset of +π/2 aligns atan2 with the character's front.
// Rx(+90°) rotates the FBX/USDZ Y-up character to the game's Z-up convention.
static simd_float4x4 make_char_model(float x, float y, float scale, float yMin,
                                     float facingAngle, float zOffset) {
    simd_float4x4 Rx = matrix_identity_float4x4;
    Rx.columns[1] = (simd_float4){ 0.f,  0.f, 1.f, 0.f};
    Rx.columns[2] = (simd_float4){ 0.f, -1.f, 0.f, 0.f};
    // Translate model up so feet (yMin) land on Z=0 after rotation.
    simd_float4x4 Tfoot = matrix_identity_float4x4;
    Tfoot.columns[3].y = -yMin;
    // Rotate around game Z-axis to face movement direction.
    float theta = facingAngle + (float)M_PI_2;
    float c = cosf(theta), s = sinf(theta);
    simd_float4x4 Rz = matrix_identity_float4x4;
    Rz.columns[0] = (simd_float4){ c, s, 0.f, 0.f};
    Rz.columns[1] = (simd_float4){-s, c, 0.f, 0.f};
    simd_float4x4 S = matrix_identity_float4x4;
    S.columns[0].x = scale; S.columns[1].y = scale; S.columns[2].z = scale;
    simd_float4x4 T = matrix_identity_float4x4;
    T.columns[3] = (simd_float4){x, y, zOffset, 1.f};
    return simd_mul(T, simd_mul(S, simd_mul(Rz, simd_mul(Rx, Tfoot))));
}

// Triple-buffered bone matrix storage: kMaxBones float4x4 per entity slot, 3 frames.
static const int kMaxAnimEntities = 64;
static const NSUInteger kBoneMatStride = kMaxBones * 16 * sizeof(float); // 4096 B

static const simd_float3 kQuadVerts[6] = {
    {-0.5f,-0.5f,0.f},{ 0.5f,-0.5f,0.f},{-0.5f, 0.5f,0.f},
    { 0.5f,-0.5f,0.f},{ 0.5f, 0.5f,0.f},{-0.5f, 0.5f,0.f},
};

static const simd_float3 kExitArrowVerts[9] = {
    {-14.f,-60.f,0.f},{ 14.f,-60.f,0.f},{-14.f, 22.f,0.f},
    { 14.f,-60.f,0.f},{ 14.f, 22.f,0.f},{-14.f, 22.f,0.f},
    {-36.f, 22.f,0.f},{ 36.f, 22.f,0.f},{  0.f, 60.f,0.f},
};

static const float kEntitySize   = 40.0f;
static const float kCamDist      = 800.0f;  // base camera distance (single player)
static const float kCamDistMax   = 1500.0f; // max zoom-out (players very far apart)
static const float kCamZoomScale = 0.5f;    // extra distance added per unit of player spread
static const float kCamPitch     = 55.0f * ((float)M_PI / 180.0f);
static const float kFOVY         = 70.0f * ((float)M_PI / 180.0f);
static const float kNear         = 1.0f;
static const float kFar          = 3000.0f;
static const float kFinalKillZoomMinEaseBack = 0.5f;

static simd_float4x4 make_perspective(float fovY, float aspect, float n, float f) {
    float t = 1.f / tanf(fovY * .5f);
    simd_float4x4 m = {};
    m.columns[0].x = t / aspect;  m.columns[1].y = t;
    m.columns[2].z = f/(n-f);     m.columns[2].w = -1.f;
    m.columns[3].z = n*f/(n-f);
    return m;
}

static simd_float4x4 make_look_at(simd_float3 eye, simd_float3 tgt, simd_float3 up) {
    simd_float3 f = simd_normalize(tgt-eye);
    simd_float3 r = simd_normalize(simd_cross(f,up));
    simd_float3 u = simd_cross(r,f);
    simd_float4x4 m;
    m.columns[0]=(simd_float4){r.x,u.x,-f.x,0};
    m.columns[1]=(simd_float4){r.y,u.y,-f.y,0};
    m.columns[2]=(simd_float4){r.z,u.z,-f.z,0};
    m.columns[3]=(simd_float4){-simd_dot(r,eye),-simd_dot(u,eye),simd_dot(f,eye),1};
    return m;
}

static simd_float4x4 make_model(float x, float y, float s) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = s; m.columns[1].y = s; m.columns[2].z = s;
    m.columns[3] = (simd_float4){x,y,0.f,1.f};
    return m;
}

// Non-uniform scale — used for floor quad and wall strips.
static simd_float4x4 make_model_rect(float x, float y, float z, float w, float h) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = w; m.columns[1].y = h; m.columns[2].z = 1.f;
    m.columns[3] = (simd_float4){x, y, z, 1.f};
    return m;
}

static simd_float4x4 make_model_line(float x1, float y1, float x2, float y2,
                                     float width, float z) {
    float dx = x2 - x1;
    float dy = y2 - y1;
    float len = sqrtf(dx * dx + dy * dy);
    simd_float4x4 S = matrix_identity_float4x4;
    S.columns[0].x = len;
    S.columns[1].y = width;
    S.columns[2].z = 1.f;
    float a = atan2f(dy, dx);
    float c = cosf(a), s = sinf(a);
    simd_float4x4 R = matrix_identity_float4x4;
    R.columns[0] = (simd_float4){ c, s, 0.f, 0.f};
    R.columns[1] = (simd_float4){-s, c, 0.f, 0.f};
    simd_float4x4 T = matrix_identity_float4x4;
    T.columns[3] = (simd_float4){(x1 + x2) * 0.5f, (y1 + y2) * 0.5f, z, 1.f};
    return simd_mul(T, simd_mul(R, S));
}

// Vertical wall quad standing in Z. alongX: quad x → world X (north/south
// walls); otherwise quad x → world Y (east/west walls). Quad y → world Z.
static simd_float4x4 make_model_wall(float cx, float cy, float length, float height, bool alongX) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = alongX ? (simd_float4){length, 0, 0, 0}
                          : (simd_float4){0, length, 0, 0};
    m.columns[1] = (simd_float4){0, 0, height, 0};
    m.columns[2] = alongX ? (simd_float4){0, 1, 0, 0}
                          : (simd_float4){1, 0, 0, 0};
    m.columns[3] = (simd_float4){cx, cy, height * 0.5f, 1.f};
    return m;
}

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static simd_float4 lighten_color(simd_float4 c, float amount) {
    return (simd_float4){
        c.x + (1.f - c.x) * amount,
        c.y + (1.f - c.y) * amount,
        c.z + (1.f - c.z) * amount,
        c.w
    };
}

static void writePNG(id<MTLBuffer> staging, NSUInteger w, NSUInteger h,
                     NSUInteger bpr, NSString *path);
static void drawCenteredLine(CGContextRef ctx, NSString *text, CGFloat centerX, CGFloat baselineY,
                             CGFloat maxWidth, CGFloat fontSize, CGFloat minFontSize,
                             CGColorRef color);
static id<MTLTexture> makeOverlayTexture(id<MTLDevice> device, CGFloat drawableW, CGFloat drawableH,
                                         NSString *title, NSString *subtitle,
                                         NSString *choiceA, NSString *choiceB,
                                         NSArray<NSString*> *statLines,
                                         CGSize *outSize);
static id<MTLTexture> makeHUDLabelTexture(id<MTLDevice> device, NSString *text, CGSize *outSize);

static NSString *exit_label_for_component(const ExitComponent& exit) {
    if (!exit.cursed) return @"ONWARD";
    switch (exit.curseType) {
        case 0: return @"IRON HORDE  UP enemies  +coins";
        case 1: return @"WAR CHEST  UP enemies  +coins +scrap";
        case 2: return @"BLOODPACT  UP enemies  +coins +heal";
        case 3: return @"GREATER CURSE  UP UP enemies  +coins";
        default: return @"CURSE  UP enemies  +coins";
    }
}

static int exit_label_index(const ExitComponent& exit) {
    return exit.cursed ? (int)(exit.curseType % 4) + 1 : 0;
}

@implementation BrawlerRenderer {
    id<MTLRenderPipelineState> _pipeline;        // flat-color quads
    id<MTLRenderPipelineState> _floorPipeline;   // grid floor
    id<MTLRenderPipelineState> _texturePipeline; // textured 2D overlays
    id<MTLRenderPipelineState> _shadowPipeline;  // alpha-blended blob shadows
    id<MTLRenderPipelineState> _skinnedPipeline; // skinned meshes
    id<MTLDepthStencilState>   _depthState;
    id<MTLDepthStencilState>   _noDepthState;     // for 2D HUD overlay
    id<MTLDepthStencilState>   _shadowDepthState; // test, never write
    id<MTLSamplerState>        _linearSampler;
    id<MTLBuffer>              _quadVB;
    id<MTLBuffer>              _exitArrowVB;
    id<MTLBuffer>              _boneBuf[3];      // triple-buffered bone matrices
    id<MTLTexture>             _whiteTexture;    // 1×1 white fallback when no diffuse
    int                        _frameIdx;
    simd_float4x4              _proj;

    LoadedCharacter* _playerChar;
    LoadedCharacter* _enemyChar;
    float            _facingAngle[kMaxAnimEntities]; // per-entity last known facing (atan2 radians)
    NSString*        _pendingCapturePath;            // --autotest: next frame → PNG

    id<MTLRenderPipelineState> _particlePipeline;    // additive billboards
    id<MTLBuffer>              _particleVB[3];       // triple-buffered instances
    ParticleSim                _particles;
    uint32_t                   _burstSeed;
    CFTimeInterval             _lastParticleTime;    // renderer-local dt for sim + decays

    // Post-process: the scene renders into _sceneColor, then a fullscreen
    // pass applies radial hit blur + damage vignette into the drawable.
    id<MTLRenderPipelineState> _postPipeline;
    id<MTLTexture>             _sceneColor;
    id<MTLTexture>             _sceneDepth;
    MTLPixelFormat             _pixelFormat;
    float                      _hitBlur;     // 0..1, decays fast
    float                      _damageFlash; // 0..1, decays slower
    float                      _finalKillZoomTime;
    float                      _finalKillZoomDuration;
    simd_float3                _finalKillZoomPos;

    BOOL                       _overlayVisible;
    BOOL                       _overlayDirty;
    NSString                  *_overlayTitle;
    NSString                  *_overlaySubtitle;
    NSString                  *_overlayChoiceA;
    NSString                  *_overlayChoiceB;
    NSArray<NSString*>        *_overlayStatLines;
    id<MTLTexture>             _overlayTexture;
    CGSize                     _overlayTextureSize;
    CGSize                     _overlayDrawableSize;
    id<MTLTexture>             _hudRoomTexture;
    CGSize                     _hudRoomTextureSize;
    NSString                  *_hudRoomText;
    id<MTLTexture>             _hudScrapTexture;
    CGSize                     _hudScrapTextureSize;
    NSString                  *_hudScrapText;
    id<MTLTexture>             _hudScoreTexture;
    CGSize                     _hudScoreTextureSize;
    NSString                  *_hudScoreText;
    id<MTLTexture>             _hudComboTexture;
    CGSize                     _hudComboTextureSize;
    NSString                  *_hudComboText;
    id<MTLTexture>             _hudCurseTexture;
    CGSize                     _hudCurseTextureSize;
    NSString                  *_hudCurseText;
    id<MTLTexture>             _exitLabelTexture[5];
    CGSize                     _exitLabelTextureSize[5];
    int                        _lastComboCount;
    float                      _comboPop;
    id<MTLTexture>             _shopPromptTexture;
    CGSize                     _shopPromptTextureSize;
    NSString                  *_shopPromptText;
    BrawlerPerkSummary         _perkSummary[kBrawlerMaxPlayers];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)pfmt {
    self = [super init];
    if (!self) return nil;

    _quadVB   = [device newBufferWithBytes:kQuadVerts length:sizeof(kQuadVerts)
                                   options:MTLResourceStorageModeShared];
    _exitArrowVB = [device newBufferWithBytes:kExitArrowVerts length:sizeof(kExitArrowVerts)
                                      options:MTLResourceStorageModeShared];
    _proj     = matrix_identity_float4x4;
    _frameIdx = 0;
    // Default facing: π/2 = characters face +Y (up the screen) until first movement.
    for (int i = 0; i < kMaxAnimEntities; i++) _facingAngle[i] = (float)M_PI_2;

    NSUInteger boneBufSize = kBoneMatStride * kMaxAnimEntities;
    for (int i = 0; i < 3; i++)
        _boneBuf[i] = [device newBufferWithLength:boneBufSize
                                          options:MTLResourceStorageModeShared];

    // Shaders compile from source at runtime rather than a build-time .metallib:
    // the Codex sandbox that writes most of this code has no Metal toolchain,
    // and its builds must stay green. Both shader files are bundled as plain
    // resources (see project.yml) and concatenated into one library, matching
    // how newDefaultLibrary used to merge every compiled .metal file into one.
    NSError *err = nil;
    id<MTLLibrary> lib = nil;
    {
        NSMutableString *src = [NSMutableString string];
        for (NSString *name in @[@"Brawler", @"SkinnedMesh"]) {
            NSString *path = [[NSBundle mainBundle] pathForResource:name
                                                              ofType:@"metal"
                                                         inDirectory:@"Shaders"];
            if (!path) {
                NSLog(@"BrawlerRenderer: Shaders/%@.metal missing from bundle", name);
                return nil;
            }
            NSError *readErr = nil;
            NSString *chunk = [NSString stringWithContentsOfFile:path
                                                          encoding:NSUTF8StringEncoding
                                                             error:&readErr];
            if (!chunk) {
                NSLog(@"BrawlerRenderer: failed to read %@: %@", path, readErr);
                return nil;
            }
            [src appendString:chunk];
            [src appendString:@"\n"];
        }
        lib = [device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            NSLog(@"BrawlerRenderer: shader library failed: %@", err);
            return nil;
        }
    }

    // Flat-color quad pipeline
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"vertex_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fragment_main"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride    = sizeof(simd_float3);
        pd.vertexDescriptor = vd;
        _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_pipeline) { NSLog(@"Flat pipeline: %@", err); return nil; }
    }

    _pixelFormat = pfmt;

    // Post-process pipeline — fullscreen triangle, no vertex buffers.
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"post_vertex"];
        pd.fragmentFunction = [lib newFunctionWithName:@"post_fragment"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        _postPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_postPipeline) NSLog(@"Post pipeline: %@", err);
    }

    // Floor pipeline — same vertex layout as flat, grid fragment shader.
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"floor_vertex"];
        pd.fragmentFunction = [lib newFunctionWithName:@"floor_fragment"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride    = sizeof(simd_float3);
        pd.vertexDescriptor = vd;
        _floorPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_floorPipeline) NSLog(@"Floor pipeline: %@", err);
    }

    // Textured overlay pipeline — alpha-blended CoreGraphics panel texture.
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"texture_vertex"];
        pd.fragmentFunction = [lib newFunctionWithName:@"texture_fragment"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        pd.colorAttachments[0].blendingEnabled             = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride    = sizeof(simd_float3);
        pd.vertexDescriptor = vd;
        _texturePipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_texturePipeline) NSLog(@"Texture pipeline: %@", err);
    }

    // Particle pipeline — instanced billboards, additive blending.
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"particle_vertex"];
        pd.fragmentFunction = [lib newFunctionWithName:@"particle_fragment"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        pd.colorAttachments[0].blendingEnabled           = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne; // additive
        pd.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride    = sizeof(simd_float3);
        pd.vertexDescriptor = vd;
        _particlePipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_particlePipeline) NSLog(@"Particle pipeline: %@", err);

        for (int i = 0; i < 3; i++)
            _particleVB[i] = [device newBufferWithLength:ParticleSim::kCapacity
                                                          * sizeof(ParticleInstanceGPU)
                                                 options:MTLResourceStorageModeShared];
        _burstSeed        = 0x1234567u;
        _lastParticleTime = CACurrentMediaTime();
    }

    // Blob shadow pipeline — same vertex layout, alpha blending enabled.
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"shadow_vertex"];
        pd.fragmentFunction = [lib newFunctionWithName:@"shadow_fragment"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        pd.colorAttachments[0].blendingEnabled             = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0;
        vd.layouts[0].stride    = sizeof(simd_float3);
        pd.vertexDescriptor = vd;
        _shadowPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_shadowPipeline) NSLog(@"Shadow pipeline: %@", err);
    }

    // Skinned mesh pipeline
    {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction   = [lib newFunctionWithName:@"skinned_vertex_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"skinned_fragment_main"];
        pd.colorAttachments[0].pixelFormat = pfmt;
        pd.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;

        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        // Must match CharacterLoader.mm skinnedVertexDescriptor() layout
        vd.attributes[0].format = MTLVertexFormatFloat3;   // position
        vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0;
        vd.attributes[1].format = MTLVertexFormatFloat3;   // normal
        vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0;
        vd.attributes[2].format = MTLVertexFormatFloat2;   // texcoord
        vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0;
        vd.attributes[3].format = MTLVertexFormatUShort4;  // joint indices
        vd.attributes[3].offset = 32; vd.attributes[3].bufferIndex = 0;
        vd.attributes[4].format = MTLVertexFormatFloat4;   // joint weights
        vd.attributes[4].offset = 40; vd.attributes[4].bufferIndex = 0;
        vd.layouts[0].stride    = 56;
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        pd.vertexDescriptor = vd;

        _skinnedPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!_skinnedPipeline)
            NSLog(@"Skinned pipeline failed (skinned_vertex_main not found?): %@", err);
    }

    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled    = YES;
    _depthState = [device newDepthStencilStateWithDescriptor:dd];

    MTLDepthStencilDescriptor *dd2 = [MTLDepthStencilDescriptor new];
    dd2.depthCompareFunction = MTLCompareFunctionAlways;
    dd2.depthWriteEnabled    = NO;
    _noDepthState = [device newDepthStencilStateWithDescriptor:dd2];

    // Shadows: depth-test against the scene but never write — overlapping
    // blobs must not z-fight each other.
    MTLDepthStencilDescriptor *dd3 = [MTLDepthStencilDescriptor new];
    dd3.depthCompareFunction = MTLCompareFunctionLess;
    dd3.depthWriteEnabled    = NO;
    _shadowDepthState = [device newDepthStencilStateWithDescriptor:dd3];

    // Linear sampler for character textures
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter     = MTLSamplerMinMagFilterLinear;
    sd.magFilter     = MTLSamplerMinMagFilterLinear;
    sd.mipFilter     = MTLSamplerMipFilterLinear;
    sd.sAddressMode  = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode  = MTLSamplerAddressModeClampToEdge;
    _linearSampler   = [device newSamplerStateWithDescriptor:sd];

    // 1×1 white fallback texture — used when character has no diffuse texture
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:1 height:1
                                                                              mipmapped:NO];
    _whiteTexture = [device newTextureWithDescriptor:td];
    uint32_t white = 0xFFFFFFFF;
    [_whiteTexture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:4];

    return self;
}

- (void)setOverlayVisible:(BOOL)visible
                    title:(NSString*)title
                 subtitle:(NSString*)subtitle
                  choiceA:(NSString*)choiceA
                  choiceB:(NSString*)choiceB {
    [self setOverlayVisible:visible
                      title:title
                   subtitle:subtitle
                    choiceA:choiceA
                    choiceB:choiceB
                  statLines:nil];
}

- (void)setOverlayVisible:(BOOL)visible
                    title:(NSString*)title
                 subtitle:(NSString*)subtitle
                  choiceA:(NSString*)choiceA
                  choiceB:(NSString*)choiceB
                statLines:(NSArray<NSString*>*)statLines {
    title = title ?: @"";
    subtitle = subtitle ?: @"";
    choiceA = choiceA ?: @"";
    choiceB = choiceB ?: @"";
    NSArray<NSString*> *lines = statLines ?: @[];
    if (lines.count > 9)
        lines = [lines subarrayWithRange:NSMakeRange(0, 9)];
    BOOL changed = _overlayVisible != visible ||
                   ![_overlayTitle isEqualToString:title] ||
                   ![_overlaySubtitle isEqualToString:subtitle] ||
                   ![_overlayChoiceA isEqualToString:choiceA] ||
                   ![_overlayChoiceB isEqualToString:choiceB] ||
                   ![_overlayStatLines isEqualToArray:lines];
    _overlayVisible = visible;
    _overlayTitle = [title copy];
    _overlaySubtitle = [subtitle copy];
    _overlayChoiceA = [choiceA copy];
    _overlayChoiceB = [choiceB copy];
    _overlayStatLines = [lines copy];
    if (changed) _overlayDirty = YES;
}

- (void)setPerkSummary:(BrawlerPerkSummary)summary
             forPlayer:(int)playerIndex {
    if (playerIndex < 0 || playerIndex >= kBrawlerMaxPlayers) return;
    _perkSummary[playerIndex] = summary;
}

- (void)setPlayerCharacter:(LoadedCharacter*)player enemyCharacter:(LoadedCharacter*)enemy {
    _playerChar = player;
    _enemyChar  = enemy;
}

- (void)updateDrawableSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    _proj = make_perspective(kFOVY, (float)size.width/(float)size.height, kNear, kFar);

    // (Re)allocate the offscreen scene targets for the post pass.
    id<MTLDevice> device = _quadVB.device;
    MTLTextureDescriptor *cd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:_pixelFormat
                                     width:(NSUInteger)size.width
                                    height:(NSUInteger)size.height
                                 mipmapped:NO];
    cd.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    cd.storageMode = MTLStorageModePrivate;
    _sceneColor = [device newTextureWithDescriptor:cd];

    MTLTextureDescriptor *dd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                     width:(NSUInteger)size.width
                                    height:(NSUInteger)size.height
                                 mipmapped:NO];
    dd.usage       = MTLTextureUsageRenderTarget;
    dd.storageMode = MTLStorageModePrivate;
    _sceneDepth = [device newTextureWithDescriptor:dd];
}

// Effect triggers — called by BrawlerGameDelegate off combat events.
- (void)triggerHitBlur:(float)strength {
    if (strength > _hitBlur) _hitBlur = fminf(strength, 1.f);
}

- (void)triggerDamageFlash {
    _damageFlash = 1.f;
}

- (void)beginFinalKillZoomAt:(simd_float3)pos duration:(float)seconds {
    _finalKillZoomPos = pos;
    _finalKillZoomDuration = fmaxf(seconds, 0.001f);
    _finalKillZoomTime = _finalKillZoomDuration;
}

- (void)drawWorld:(World*)world inView:(MTKView*)view commandBuffer:(id<MTLCommandBuffer>)cmd {
    MTLRenderPassDescriptor *viewRPD = view.currentRenderPassDescriptor;
    if (!viewRPD || !view.currentDrawable) return;

    // Renderer-local wall-clock dt: drives the particle sim and the post-FX
    // decays — both keep moving during hit-stop and pause.
    CFTimeInterval now = CACurrentMediaTime();
    float pdt = fminf((float)(now - _lastParticleTime), 0.1f);
    _lastParticleTime = now;
    _hitBlur     *= expf(-pdt / 0.06f);  // sharp: gone ~0.15s after a hit
    _damageFlash *= expf(-pdt / 0.14f);  // softer: ~0.35s red bleed
    if (_comboCount > _lastComboCount) _comboPop = 0.18f;
    _lastComboCount = _comboCount;
    if (_comboPop > 0.f) _comboPop = fmaxf(0.f, _comboPop - pdt);
    if (_finalKillZoomTime > 0.f)
        _finalKillZoomTime = fmaxf(0.f, _finalKillZoomTime - pdt);
    if (_hitBlur     < 0.01f) _hitBlur     = 0.f;
    if (_damageFlash < 0.01f) _damageFlash = 0.f;

    // Lazily match the offscreen scene targets to the drawable size.
    if (!_sceneColor ||
        _sceneColor.width  != view.currentDrawable.texture.width ||
        _sceneColor.height != view.currentDrawable.texture.height)
        [self updateDrawableSize:CGSizeMake(view.currentDrawable.texture.width,
                                            view.currentDrawable.texture.height)];
    CGSize drawableSize = CGSizeMake(view.currentDrawable.texture.width,
                                     view.currentDrawable.texture.height);
    if (!CGSizeEqualToSize(drawableSize, _overlayDrawableSize)) {
        _overlayDrawableSize = drawableSize;
        _overlayDirty = YES;
    }

    // Multi-player camera: track centroid of all alive players.
    // Zoom out proportionally to player spread so everyone stays in frame.
    float pMinX =  1e9f, pMaxX = -1e9f;
    float pMinY =  1e9f, pMaxY = -1e9f;
    int   pCount = 0;
    for (EntityID id = 0; id < world->entity_count(); ++id) {
        if (!world->player_tags().present(id)) continue;
        if (!world->has_component<PositionComponent>(id)) continue;
        if (world->has_component<AnimationComponent>(id) &&
            world->get_component<AnimationComponent>(id).dying) continue;
        auto& p = world->get_component<PositionComponent>(id);
        pMinX = fminf(pMinX, p.x); pMaxX = fmaxf(pMaxX, p.x);
        pMinY = fminf(pMinY, p.y); pMaxY = fmaxf(pMaxY, p.y);
        pCount++;
    }
    if (pCount == 0) { pMinX = pMaxX = kCameraDefaultTargetX;
                       pMinY = pMaxY = kCameraDefaultTargetY; }

    float centX   = (pMinX + pMaxX) * 0.5f;
    float centY   = (pMinY + pMaxY) * 0.5f;
    float spread  = fmaxf(pMaxX - pMinX, pMaxY - pMinY);
    float camDist = clampf(kCamDist + spread * kCamZoomScale, kCamDist, kCamDistMax);
    if (_finalKillZoomTime > 0.f) {
        float elapsed = _finalKillZoomDuration - _finalKillZoomTime;
        float easeBack = fmaxf(kFinalKillZoomMinEaseBack, 0.25f * _finalKillZoomDuration);
        float zoom = 1.f;
        if (_finalKillZoomTime < easeBack) {
            float t = _finalKillZoomTime / easeBack;
            zoom = t * t * (3.f - 2.f * t);
        } else if (elapsed < 0.35f) {
            float t = elapsed / 0.35f;
            zoom = t * t * (3.f - 2.f * t);
        }
        centX = centX + (_finalKillZoomPos.x - centX) * 0.4f * zoom;
        centY = centY + (_finalKillZoomPos.y - centY) * 0.4f * zoom;
        camDist *= (1.f - 0.35f * zoom);
    }

    // Clamp camera target so the view frustum stays within room bounds.
    // Padding scales with camDist so walls stay out of frame at any zoom level.
    float padScale = camDist / kCamDist;
    float kCamPadX = 320.f * padScale;
    float kCamPadY = 220.f * padScale;
    simd_float3 target;
    target.x = clampf(centX, kRoomMinX + kCamPadX, kRoomMaxX - kCamPadX);
    target.y = clampf(centY, kRoomMinY + kCamPadY, kRoomMaxY - kCamPadY);
    target.z = 0;

    simd_float3 eye = { target.x,
                        target.y - camDist * cosf(kCamPitch),
                        camDist   * sinf(kCamPitch) };

    // Screen shake: offset eye and target together so the view direction is
    // preserved and the whole frame jolts. Decays in ScreenShakeSystem.
    simd_float2 shake = ScreenShakeSystem_offset(*world);
    eye.x    += shake.x; eye.y    += shake.y;
    target.x += shake.x; target.y += shake.y;

    simd_float4x4 vp = simd_mul(_proj, make_look_at(eye, target, (simd_float3){0,0,1}));

    int paletteIndex = (_roomIndex + 1 >= _totalRooms && _totalRooms > 0)
                     ? (kNumRoomPalettes - 1)
                     : ((_roomIndex % (kNumRoomPalettes - 1)) + (kNumRoomPalettes - 1))
                        % (kNumRoomPalettes - 1);
    const RoomPalette& pal = kRoomPalettes[paletteIndex];

    // Scene pass — renders into the offscreen texture for the post pass.
    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture     = _sceneColor;
    rpd.colorAttachments[0].clearColor  = pal.clear;
    rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.depthAttachment.texture     = _sceneDepth;
    rpd.depthAttachment.clearDepth  = 1.0;
    rpd.depthAttachment.loadAction  = MTLLoadActionClear;
    rpd.depthAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
    [enc setDepthStencilState:_depthState];
    [enc setVertexBuffer:_quadVB offset:0 atIndex:0];

    // Floor — grid shader at Z=-1 so entities render on top.
    {
        FloorUniformsGPU fu;
        fu.mvp       = simd_mul(vp, make_model_rect(kRoomCenterX, kRoomCenterY, -1.f,
                                                    kRoomWidth, kRoomHeight));
        fu.baseColor = pal.floorBase;
        fu.lineColor = pal.floorLine;
        fu.marking   = pal.marking;
        fu.center    = (simd_float2){kRoomCenterX, kRoomCenterY};
        fu.size      = (simd_float2){kRoomWidth, kRoomHeight};
        [enc setRenderPipelineState:_floorPipeline ?: _pipeline];
        [enc setVertexBytes:&fu length:sizeof(fu) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    [enc setRenderPipelineState:_pipeline];

    // Walls: standing quads along the far and side edges give the arena
    // height; the near edge stays a flat strip so it never occludes play.
    {
        static const float kWallHeight = 80.f;
        static const float kWallThick  = 20.f;
        static const float kTrimHeight = 6.f;

        DrawUniforms u;
        u.color = pal.wall;
        simd_float4 trimColor = lighten_color(pal.wall, 0.34f);

        // Far (top) wall + side walls — vertical.
        u.mvp = simd_mul(vp, make_model_wall(kRoomCenterX, kRoomMaxY, kRoomWidth, kWallHeight, true));
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        u.mvp = simd_mul(vp, make_model_wall(kRoomMinX, kRoomCenterY, kRoomHeight, kWallHeight, false));
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        u.mvp = simd_mul(vp, make_model_wall(kRoomMaxX, kRoomCenterY, kRoomHeight, kWallHeight, false));
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

        u.color = trimColor;
        u.mvp = simd_mul(vp, make_model_wall(kRoomCenterX, kRoomMaxY - 1.f, kRoomWidth, kTrimHeight, true));
        u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        u.mvp = simd_mul(vp, make_model_wall(kRoomMinX + 1.f, kRoomCenterY, kRoomHeight, kTrimHeight, false));
        u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        u.mvp = simd_mul(vp, make_model_wall(kRoomMaxX - 1.f, kRoomCenterY, kRoomHeight, kTrimHeight, false));
        u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

        // Near (bottom) edge — flat strip.
        u.color = pal.wall;
        u.mvp = simd_mul(vp, make_model_rect(kRoomCenterX, kRoomMinY + kWallThick * 0.5f, 0.f,
                                             kRoomWidth, kWallThick));
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

        for (EntityID oid = 0; oid < world->entity_count(); ++oid) {
            if (!world->obstacles().present(oid)) continue;
            if (!world->has_component<PositionComponent>(oid)) continue;
            const auto& pos = world->get_component<PositionComponent>(oid);
            const auto& obs = world->get_component<ObstacleComponent>(oid);
            float w = obs.halfW * 2.f;
            float h = obs.halfH * 2.f;

            u.color = pal.wall;
            u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y + obs.halfH, w, kWallHeight, true));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y - obs.halfH, w, kWallHeight, true));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x - obs.halfW, pos.y, h, kWallHeight, false));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x + obs.halfW, pos.y, h, kWallHeight, false));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

            u.color = trimColor;
            u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y + obs.halfH - 1.f, w, kTrimHeight, true));
            u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y - obs.halfH + 1.f, w, kTrimHeight, true));
            u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x - obs.halfW + 1.f, pos.y, h, kTrimHeight, false));
            u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x + obs.halfW - 1.f, pos.y, h, kTrimHeight, false));
            u.mvp.columns[3].z = kWallHeight - kTrimHeight * 0.5f + 1.f;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }

    // Blob shadows — soft dark circles grounding each character, drawn flat
    // just above the floor before any entity so meshes render over them.
    if (_shadowPipeline) {
        static const float kShadowSize  = 95.f;
        static const float kShadowAlpha = 0.45f;
        [enc setRenderPipelineState:_shadowPipeline];
        [enc setDepthStencilState:_shadowDepthState];
        [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
        for (EntityID eid = 0; eid < world->entity_count(); ++eid) {
            if (!world->has_component<PositionComponent>(eid)) continue;
            if (!world->has_component<AnimationComponent>(eid)) continue;
            auto& pos = world->get_component<PositionComponent>(eid);
            float size = kShadowSize;
            if (world->has_component<EnemyArchetypeComponent>(eid))
                size *= enemy_archetype_def(
                    world->get_component<EnemyArchetypeComponent>(eid).type).scale;
            else if (world->has_component<BossTagComponent>(eid))
                size *= 2.f;
            float fade = world->get_component<AnimationComponent>(eid).deathFade;
            DrawUniforms u;
            u.mvp   = simd_mul(vp, make_model_rect(pos.x, pos.y, -0.5f, size, size));
            u.color = (simd_float4){0, 0, 0, kShadowAlpha * fade};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }

    _frameIdx = (_frameIdx + 1) % 3;

    // Telegraph lines are extra floor passes; holders can still render as meshes.
    for (EntityID eid = 0; eid < world->entity_count(); ++eid) {
        if (!world->telegraph_lines().present(eid)) continue;
        if (!world->has_component<PositionComponent>(eid)) continue;
        const auto& pos = world->get_component<PositionComponent>(eid);
        const auto& line = world->get_component<TelegraphLineComponent>(eid);
        float pulse = 0.475f + 0.125f * sinf((float)CACurrentMediaTime() * 8.f + (float)eid);
        [enc setRenderPipelineState:_pipeline];
        [enc setDepthStencilState:_depthState];
        [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
        DrawUniforms u;
        u.mvp = simd_mul(vp, make_model_line(pos.x, pos.y, line.x2, line.y2,
                                             line.width, 2.0f));
        u.color = (simd_float4){1.0f, 0.35f, 0.15f, pulse};
        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }

    for (EntityID eid = 0; eid < world->entity_count(); ++eid) {
        if (!world->has_component<PositionComponent>(eid)) continue;
        auto& pos = world->get_component<PositionComponent>(eid);

        // Lava lobs: airborne orb plus persistent landing target ring.
        if (world->lava_lobs().present(eid)) {
            const auto& lob = world->get_component<LavaLobComponent>(eid);
            float t = clampf(lob.elapsed / lob.duration, 0.f, 1.f);
            float pulse = 0.85f + 0.15f * sinf((float)CACurrentMediaTime() * 12.f + (float)eid);
            float arcZ = 20.f + sinf(t * (float)M_PI) * 220.f;
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_rect(lob.destX, lob.destY, 2.f,
                                                 lob.poolRadius * 2.f * pulse,
                                                 lob.poolRadius * 2.f * pulse));
            u.color = (simd_float4){1.0f, 0.30f, 0.10f, 0.42f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

            u.mvp = simd_mul(vp, make_model_rect(lob.destX, lob.destY, 2.2f,
                                                 lob.poolRadius * 1.2f,
                                                 lob.poolRadius * 1.2f));
            u.color = (simd_float4){0.16f, 0.04f, 0.02f, 0.65f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, arcZ,
                                                 18.f * pulse, 18.f * pulse));
            u.color = (simd_float4){1.0f, 0.55f, 0.12f, 1.f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        // Hazards (lava snakes): pulsing molten quad on the floor, no mesh.
        if (world->hazards().present(eid)) {
            const auto& hz = world->get_component<HazardComponent>(eid);
            float pulse = 0.8f + 0.2f * sinf((float)CACurrentMediaTime() * 9.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp   = simd_mul(vp, make_model_rect(pos.x, pos.y, 1.f,
                                                   hz.radius * 1.6f, hz.radius * 1.6f));
            u.color = (simd_float4){1.0f * pulse, 0.42f * pulse, 0.10f * pulse, 1.f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        // Spawn markers: pulsing warm floor quad, plus a light pillar for sky drops.
        if (world->spawn_markers().present(eid)) {
            const auto& sm = world->get_component<SpawnMarkerComponent>(eid);
            float pulse = 1.0f + 0.2f * sinf((float)CACurrentMediaTime() * 8.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 2.f,
                                                 72.f * pulse, 72.f * pulse));
            u.color = (simd_float4){1.0f, 0.54f, 0.12f, 0.82f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 2.2f,
                                                 42.f * pulse, 42.f * pulse));
            u.color = (simd_float4){0.18f, 0.10f, 0.05f, 0.72f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

            if (sm.style == SpawnStyleSkyDrop) {
                u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y, 18.f, 220.f, true));
                u.color = (simd_float4){1.0f, 0.72f, 0.24f, 0.38f};
                [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
            continue;
        }

        // Heart pickups: pulsing rose-pink quad, no mesh.
        if (world->heart_pickups().present(eid)) {
            float pulse = 1.0f + 0.15f * sinf((float)CACurrentMediaTime() * 8.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp   = simd_mul(vp, make_model_rect(pos.x, pos.y, 16.f,
                                                   26.f * pulse, 26.f * pulse));
            u.color = (simd_float4){1.0f, 0.35f, 0.5f, 1.f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        if (world->scrap_pickups().present(eid)) {
            float pulse = 1.0f + 0.12f * sinf((float)CACurrentMediaTime() * 7.f + (float)eid);
            float bob = 3.f * sinf((float)CACurrentMediaTime() * 5.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 14.f + bob,
                                                 14.f * pulse, 14.f * pulse));
            u.color = (simd_float4){1.0f, 0.85f, 0.25f, 1.f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        if (world->boxes().present(eid)) {
            static const float kCrateSize = 50.f;
            static const float kCrateHalf = kCrateSize * 0.5f;
            static const float kCrateH = 44.f;
            static const simd_float4 kCrateTop   = {0.60f, 0.43f, 0.24f, 1.f};
            static const simd_float4 kCrateMid   = {0.50f, 0.34f, 0.18f, 1.f};
            static const simd_float4 kCrateDark  = {0.40f, 0.27f, 0.14f, 1.f};
            static const simd_float4 kCrateBrace = {0.28f, 0.18f, 0.09f, 1.f};
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y + kCrateHalf, kCrateSize, kCrateH, true));
            u.color = kCrateMid;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x, pos.y - kCrateHalf, kCrateSize, kCrateH, true));
            u.color = kCrateMid;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x - kCrateHalf, pos.y, kCrateSize, kCrateH, false));
            u.color = kCrateDark;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_wall(pos.x + kCrateHalf, pos.y, kCrateSize, kCrateH, false));
            u.color = kCrateDark;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, kCrateH, kCrateSize, kCrateSize));
            u.color = kCrateTop;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.color = kCrateBrace;
            u.mvp = simd_mul(vp, make_model_line(pos.x - 21.f, pos.y - 21.f, pos.x + 21.f, pos.y + 21.f,
                                                 5.f, kCrateH + 0.8f));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_line(pos.x - 21.f, pos.y + 21.f, pos.x + 21.f, pos.y - 21.f,
                                                 5.f, kCrateH + 0.8f));
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        if (world->shop_items().present(eid)) {
            const ShopItemComponent& item = world->get_component<ShopItemComponent>(eid);
            static const simd_float4 kPerkColors[kBrawlerPerkTypeCount] = {
                {0.95f, 0.12f, 0.16f, 1.f}, {0.00f, 0.85f, 0.95f, 1.f},
                {0.15f, 0.90f, 0.30f, 1.f}, {1.00f, 0.75f, 0.18f, 1.f},
                {1.00f, 0.42f, 0.12f, 1.f}, {0.20f, 0.45f, 1.00f, 1.f},
                {1.00f, 0.92f, 0.10f, 1.f}, {0.92f, 0.92f, 0.92f, 1.f},
                {0.20f, 0.52f, 1.00f, 1.f}, {0.20f, 0.52f, 1.00f, 1.f},
                {0.20f, 0.52f, 1.00f, 1.f}, {0.20f, 0.52f, 1.00f, 1.f},
                {1.00f, 0.72f, 0.16f, 1.f}, {1.00f, 0.72f, 0.16f, 1.f},
                {1.00f, 0.72f, 0.16f, 1.f}, {0.35f, 0.70f, 1.00f, 1.f},
            };
            float pulse = 0.75f + 0.20f * sinf((float)CACurrentMediaTime() * 5.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 10.f, 62.f, 42.f));
            u.color = (simd_float4){0.42f, 0.42f, 0.45f, 1.f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 16.f, 42.f, 42.f));
            u.color = kPerkColors[item.perkID % kBrawlerPerkTypeCount];
            u.color.w = pulse;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        // Exit arrow: flat cyan ground marker pointing toward the top-edge exit.
        if (world->exits().present(eid)) {
            const ExitComponent& exit = world->get_component<ExitComponent>(eid);
            float pulse = 1.0f + 0.18f * sinf((float)CACurrentMediaTime() * 6.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_exitArrowVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 2.5f,
                                                 pulse, pulse));
            u.color = exit.cursed
                    ? (simd_float4){0.82f * pulse, 0.12f * pulse, 0.95f * pulse, 0.95f}
                    : (simd_float4){0.12f * pulse, 0.92f * pulse, 1.0f * pulse, 0.95f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:9];
            continue;
        }

        // Enemy projectile: small pulsing orange-hot quad, no mesh.
        if (world->projectiles().present(eid)) {
            float pulse = 0.85f + 0.15f * sinf((float)CACurrentMediaTime() * 18.f + (float)eid);
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp = simd_mul(vp, make_model_rect(pos.x, pos.y, 18.f,
                                                 16.f * pulse, 16.f * pulse));
            u.color = (simd_float4){1.0f, 0.6f, 0.2f, 1.f};
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            continue;
        }

        simd_float4 color = {1,1,1,1};
        FactionComponent::Type faction = FactionComponent::Player;
        bool isShopkeeper = world->shopkeepers().present(eid);
        if (world->has_component<FactionComponent>(eid)) {
            faction = world->get_component<FactionComponent>(eid).type;
            switch (faction) {
                case FactionComponent::Player: color = {0.3f,0.7f,1.0f,1.f}; break; // blue tint
                case FactionComponent::Enemy:  color = {1.0f,0.4f,0.3f,1.f}; break; // orange-red tint
            }
        }
        if (isShopkeeper) color = {1.0f, 0.8f, 0.3f, 1.f};

        // Update facing angle from velocity when the entity is actually moving.
        if (eid < kMaxAnimEntities && world->has_component<VelocityComponent>(eid)) {
            auto& vel = world->get_component<VelocityComponent>(eid);
            float speed = sqrtf(vel.vx * vel.vx + vel.vy * vel.vy);
            if (speed > 5.f)
                _facingAngle[eid] = atan2f(vel.vy, vel.vx);
        }

        LoadedCharacter* charData = isShopkeeper ? _enemyChar
                                : (faction == FactionComponent::Player) ? _playerChar : _enemyChar;
        bool hasMesh = charData && charData->indexCount > 0 && _skinnedPipeline
                       && world->has_component<AnimationComponent>(eid);

        if (hasMesh) {
            auto& anim = world->get_component<AnimationComponent>(eid);
            color.w = anim.deathFade; // 1 normally; < 1 = corpse dissolve
            NSUInteger boneOffset = (NSUInteger)eid * kBoneMatStride;
            memcpy((uint8_t*)_boneBuf[_frameIdx].contents + boneOffset,
                   anim.boneMatrices, kBoneMatStride);

            // Auto-scale from mesh bounding box so character is kTargetCharHeight game units.
            float scale = (charData->meshHeight > 0.01f)
                        ? kTargetCharHeight / charData->meshHeight
                        : 1.0f;
            if (world->has_component<EnemyArchetypeComponent>(eid))
                scale *= enemy_archetype_def(
                    world->get_component<EnemyArchetypeComponent>(eid).type).scale;
            else if (world->has_component<BossTagComponent>(eid))
                scale *= 2.0f;

            [enc setRenderPipelineState:_skinnedPipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:charData->vertexBuffer offset:0 atIndex:0];
            [enc setVertexBuffer:_boneBuf[_frameIdx] offset:boneOffset atIndex:1];
            SkinnedUniforms su;
            float facing = (eid < kMaxAnimEntities) ? _facingAngle[eid] : (float)M_PI_2;
            float zOffset = 0.f;
            if (world->has_component<SpawnAnimComponent>(eid)) {
                const auto& spawn = world->get_component<SpawnAnimComponent>(eid);
                float t = clampf(spawn.progress, 0.f, 1.f);
                if (spawn.style == SpawnStyleGroundRise) {
                    float eased = 1.f - (1.f - t) * (1.f - t);
                    zOffset = -kTargetCharHeight * scale * (1.f - eased);
                } else {
                    zOffset = 600.f * (1.f - t * t);
                }
            }
            if (world->has_component<LeaperComponent>(eid)) {
                const auto& leap = world->get_component<LeaperComponent>(eid);
                if (leap.state == 2) {
                    float t = clampf(leap.timer / Difficulty_leap_duration(world->difficulty()), 0.f, 1.f);
                    zOffset += sinf(t * (float)M_PI) * 130.f;
                }
            }
            if (world->has_component<BossChargeComponent>(eid)) {
                const auto& boss = world->get_component<BossChargeComponent>(eid);
                if (boss.state == BossChargeComponent::Leap) {
                    float t = clampf(boss.timer / boss.leapDuration, 0.f, 1.f);
                    zOffset += sinf(t * (float)M_PI) * 150.f;
                }
            }
            su.mvp   = simd_mul(vp, make_char_model(pos.x, pos.y, scale,
                                                    charData->meshYMin, facing, zOffset));
            su.color = color;
            su.tintStrength = isShopkeeper ? 0.55f
                            : (faction == FactionComponent::Enemy) ? kEnemyTintStrength
                                                                   : kPlayerTintStrength;
            if (faction == FactionComponent::Enemy &&
                world->has_component<EnemyAttackCooldownComponent>(eid) &&
                world->get_component<EnemyAttackCooldownComponent>(eid).windup > 0.f) {
                float flash = 0.15f + 0.5f * (0.5f + 0.5f *
                              sinf(world->get_component<EnemyAttackCooldownComponent>(eid).windup * 40.f));
                su.color.x = su.color.x + (1.f - su.color.x) * flash;
                su.color.y = su.color.y + (1.f - su.color.y) * flash;
                su.color.z = su.color.z + (1.f - su.color.z) * flash;
                su.tintStrength = flash;
            }
            if (world->has_component<BossChargeComponent>(eid) &&
                world->get_component<BossChargeComponent>(eid).enraged) {
                su.color = (simd_float4){1.0f, 0.10f, 0.06f, su.color.w};
                su.tintStrength = fmaxf(su.tintStrength, 0.5f);
            }
            if (world->has_component<DownedComponent>(eid)) {
                su.color = (simd_float4){0.22f, 0.24f, 0.27f, su.color.w};
                su.tintStrength = 0.85f;
            }
            if (world->has_component<ChargeAttackComponent>(eid) &&
                world->get_component<ChargeAttackComponent>(eid).charging) {
                su.color = (simd_float4){0.35f, 0.70f, 1.0f, su.color.w};
                su.tintStrength = fmaxf(su.tintStrength, 0.72f);
            }
            [enc setVertexBytes:&su length:sizeof(su) atIndex:2];

            id<MTLTexture> tex = charData->diffuseTexture ? charData->diffuseTexture : _whiteTexture;
            [enc setFragmentBytes:&su length:sizeof(su) atIndex:2];
            [enc setFragmentTexture:tex atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];

            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:charData->indexCount
                             indexType:charData->indexType
                           indexBuffer:charData->indexBuffer
                     indexBufferOffset:0];
        } else {
            [enc setRenderPipelineState:_pipeline];
            [enc setDepthStencilState:_depthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            DrawUniforms u;
            u.mvp   = simd_mul(vp, make_model(pos.x, pos.y, kEntitySize));
            u.color = color;
            [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }
    // -----------------------------------------------------------------------
    // Particles — additive camera-facing billboards (hit sparks, telegraphs).
    // Advanced with renderer-local wall-clock dt: bursts keep moving during
    // hit-stop and pause, which reads as energy rather than freezing.
    // -----------------------------------------------------------------------
    {
        _particles.update(pdt * world->time_scale());

        if (_particlePipeline && _particles.count > 0) {
            ParticleInstanceGPU *dst =
                (ParticleInstanceGPU *)_particleVB[_frameIdx].contents;
            for (int i = 0; i < _particles.count; ++i) {
                const ParticleSim::Particle& p = _particles.particles[i];
                float fade = p.lifeMax > 0.f ? p.life / p.lifeMax : 0.f;
                dst[i].pos   = (simd_float3){p.x, p.y, p.z};
                dst[i].size  = p.size;
                dst[i].color = (simd_float4){p.r, p.g, p.b, fade};
            }

            simd_float3 f        = simd_normalize(target - eye);
            simd_float3 camRight = simd_normalize(simd_cross(f, (simd_float3){0, 0, 1}));
            simd_float3 camUp    = simd_cross(camRight, f);
            ParticleUniformsGPU pu = { vp, camRight, camUp };

            [enc setRenderPipelineState:_particlePipeline];
            [enc setDepthStencilState:_shadowDepthState]; // test, never write
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            [enc setVertexBuffer:_particleVB[_frameIdx] offset:0 atIndex:1];
            [enc setVertexBytes:&pu length:sizeof(pu) atIndex:2];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
                  instanceCount:(NSUInteger)_particles.count];
        }
    }

    // -----------------------------------------------------------------------
    // Post pass — fullscreen radial hit blur + damage vignette from the scene
    // texture into the drawable. The HUD is drawn after, unaffected by FX.
    // -----------------------------------------------------------------------
    [enc endEncoding];

    viewRPD.colorAttachments[0].loadAction  = MTLLoadActionClear;
    viewRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
    enc = [cmd renderCommandEncoderWithDescriptor:viewRPD];

    {
        PostUniformsGPU pu = { _hitBlur, _damageFlash };
        [enc setRenderPipelineState:_postPipeline];
        [enc setDepthStencilState:_noDepthState];
        [enc setFragmentTexture:_sceneColor atIndex:0];
        [enc setFragmentSamplerState:_linearSampler atIndex:0];
        [enc setFragmentBytes:&pu length:sizeof(pu) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }

    // -----------------------------------------------------------------------
    // World-anchored health bars — project above each character's head,
    // draw as 2D ortho overlay (no depth test, drawn on top of everything).
    // -----------------------------------------------------------------------
    {
        CGSize ds = view.drawableSize;
        float W = (float)ds.width, H = (float)ds.height;

        // Ortho: pixel (0,0) = top-left → NDC (-1,+1)
        simd_float4x4 ortho = matrix_identity_float4x4;
        ortho.columns[0].x =  2.f / W;
        ortho.columns[1].y = -2.f / H;
        ortho.columns[3]   = (simd_float4){-1.f, 1.f, 0.f, 1.f};

        [enc setRenderPipelineState:_pipeline];
        [enc setDepthStencilState:_noDepthState];
        [enc setVertexBuffer:_quadVB offset:0 atIndex:0];

        static const float kBarW     = 80.f;  // pixels
        static const float kBarH     = 10.f;  // pixels
        static const float kBarGap   = 8.f;   // pixels above projected head
        static const float kSpecialBarH = 5.f; // pixels

        for (EntityID id = 0; id < world->entity_count(); ++id) {
            if (!world->has_component<HealthComponent>(id)) continue;
            if (!world->has_component<PositionComponent>(id)) continue;
            // Skip dying — bar is at 0 and just adds clutter during death anim.
            if (world->has_component<AnimationComponent>(id) &&
                world->get_component<AnimationComponent>(id).dying) continue;

            const auto& pos = world->get_component<PositionComponent>(id);
            const auto& hp  = world->get_component<HealthComponent>(id);

            // Project the above-head world position to screen pixels.
            simd_float4 clip = simd_mul(vp, (simd_float4){pos.x, pos.y, kTargetCharHeight, 1.f});
            if (clip.w <= 0.f) continue; // behind camera
            float ndcX  = clip.x / clip.w;
            float ndcY  = clip.y / clip.w;
            float scrX  = (ndcX + 1.f) * 0.5f * W;
            float scrY  = (1.f - ndcY) * 0.5f * H - kBarGap; // shift up by gap

            DrawUniforms u;

            bool isPlayer = world->player_tags().present(id);
            if (isPlayer) {
                static const float kHeartW = 12.f;
                static const float kHeartH = 10.f;
                static const float kHeartGap = 4.f;
                int hearts = (hp.max + 1) / 2;
                if (hearts < 1) hearts = 1;
                if (hearts > 12) hearts = 12;
                float rowW = hearts * kHeartW + (hearts - 1) * kHeartGap;
                float left = scrX - rowW * 0.5f;
                for (int h = 0; h < hearts; ++h) {
                    float cx = left + kHeartW * 0.5f + h * (kHeartW + kHeartGap);
                    u.color = (simd_float4){0.10f, 0.04f, 0.05f, 1.f};
                    u.mvp = simd_mul(ortho, make_model_rect(cx, scrY, 0.f, kHeartW, kHeartH));
                    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

                    int hpForHeart = hp.current - h * 2;
                    float fill = hpForHeart >= 2 ? 1.f : (hpForHeart == 1 ? 0.5f : 0.f);
                    if (fill > 0.f) {
                        float fw = kHeartW * fill;
                        u.color = (simd_float4){0.95f, 0.12f, 0.20f, 1.f};
                        u.mvp = simd_mul(ortho, make_model_rect(cx - kHeartW * 0.5f + fw * 0.5f,
                                                                scrY, 0.f, fw, kHeartH));
                        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                    }
                }
            } else {
                u.color = {0.08f, 0.08f, 0.10f, 1.f};
                u.mvp   = simd_mul(ortho, make_model_rect(scrX, scrY, 0.f, kBarW, kBarH));
                [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

                float fill = (hp.max > 0) ? (float)hp.current / hp.max : 0.f;
                if (fill < 0.f) fill = 0.f;
                float fw = kBarW * fill;
                if (fw > 1.f) {
                    u.color = (simd_float4){1.00f, 0.35f, 0.20f, 1.f};
                    u.mvp   = simd_mul(ortho, make_model_rect(scrX - kBarW * 0.5f + fw * 0.5f,
                                                              scrY, 0.f, fw, kBarH));
                    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                }
            }

            if (world->player_tags().present(id) &&
                world->has_component<SpecialMeterComponent>(id)) {
                float meterY = scrY + kBarH + kSpecialBarH + 2.f;
                u.color = {0.08f, 0.08f, 0.10f, 1.f};
                u.mvp   = simd_mul(ortho, make_model_rect(scrX, meterY, 0.f, kBarW, kSpecialBarH));
                [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

                float mfill = world->get_component<SpecialMeterComponent>(id).charge;
                if (mfill < 0.f) mfill = 0.f;
                if (mfill > 1.f) mfill = 1.f;
                float mw = kBarW * mfill;
                if (mw > 1.f) {
                    u.color = (simd_float4){1.0f, 0.8f, 0.2f, 1.f};
                    u.mvp   = simd_mul(ortho, make_model_rect(scrX - kBarW * 0.5f + mw * 0.5f,
                                                              meterY, 0.f, mw, kSpecialBarH));
                    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                }

                const PlayerTagComponent& tag = world->get_component<PlayerTagComponent>(id);
                int slot = (tag.playerIndex < kBrawlerMaxPlayers) ? tag.playerIndex : 0;
                static const simd_float4 kPerkColors[kBrawlerPerkTypeCount] = {
                    {0.95f, 0.12f, 0.16f, 1.f}, // damage
                    {0.00f, 0.85f, 0.95f, 1.f}, // speed
                    {0.15f, 0.90f, 0.30f, 1.f}, // max HP
                    {1.00f, 0.75f, 0.18f, 1.f}, // life
                    {1.00f, 0.42f, 0.12f, 1.f}, // knockback
                    {0.20f, 0.45f, 1.00f, 1.f}, // dodge
                    {1.00f, 0.92f, 0.10f, 1.f}, // special charge
                    {0.92f, 0.92f, 0.92f, 1.f}, // second wind
                    {0.20f, 0.52f, 1.00f, 1.f}, // heavy hitter
                    {0.20f, 0.52f, 1.00f, 1.f}, // toughness
                    {0.20f, 0.52f, 1.00f, 1.f}, // lifesteal
                    {0.20f, 0.52f, 1.00f, 1.f}, // thorns
                    {1.00f, 0.72f, 0.16f, 1.f}, // whirlwind
                    {1.00f, 0.72f, 0.16f, 1.f}, // adrenaline
                    {1.00f, 0.72f, 0.16f, 1.f}, // vampire
                    {0.35f, 0.70f, 1.00f, 1.f}, // evasion
                };
                if (world->has_component<DodgeChargesComponent>(id)) {
                    const DodgeChargesComponent& dodgeCharges =
                        world->get_component<DodgeChargesComponent>(id);
                    static const float kDodgePipW = 10.f;
                    static const float kDodgePipH = 5.f;
                    static const float kDodgePipGap = 4.f;
                    int maxCharges = dodgeCharges.maxCharges;
                    if (maxCharges < 0) maxCharges = 0;
                    if (maxCharges > 5) maxCharges = 5;
                    float rowW = maxCharges * kDodgePipW + (maxCharges - 1) * kDodgePipGap;
                    float left = scrX - rowW * 0.5f;
                    float dodgeY = meterY + kSpecialBarH + 6.f;
                    for (int c = 0; c < maxCharges; ++c) {
                        float pipX = left + kDodgePipW * 0.5f + c * (kDodgePipW + kDodgePipGap);
                        u.color = c < dodgeCharges.charges
                            ? (simd_float4){0.28f, 0.70f, 1.00f, 1.f}
                            : (simd_float4){0.08f, 0.12f, 0.16f, 0.85f};
                        u.mvp = simd_mul(ortho, make_model_rect(pipX, dodgeY, 0.f,
                                                                kDodgePipW, kDodgePipH));
                        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                    }
                }
                int pipIndex = 0;
                float pipY = meterY + kSpecialBarH + 16.f;
                for (int type = 0; type < kBrawlerPerkTypeCount; ++type) {
                    for (uint8_t n = 0; n < _perkSummary[slot].counts[type] && pipIndex < 14; ++n, ++pipIndex) {
                        float pipX = scrX - kBarW * 0.5f + 4.f + pipIndex * 6.f;
                        u.color = kPerkColors[type];
                        u.mvp = simd_mul(ortho, make_model_rect(pipX, pipY, 0.f, 4.f, 4.f));
                        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                    }
                }
            }

            if (world->has_component<DownedComponent>(id)) {
                const DownedComponent& downed = world->get_component<DownedComponent>(id);
                if (downed.reviveProgress > 0.f) {
                    static const float kReviveW = 70.f;
                    static const float kReviveH = 5.f;
                    float reviveY = scrY - 13.f;
                    u.color = {0.08f, 0.07f, 0.04f, 1.f};
                    u.mvp = simd_mul(ortho, make_model_rect(scrX, reviveY, 0.f, kReviveW, kReviveH));
                    [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

                    float pct = clampf(downed.reviveProgress / 2.5f, 0.f, 1.f);
                    float rw = kReviveW * pct;
                    if (rw > 1.f) {
                        u.color = {1.0f, 0.75f, 0.18f, 1.f};
                        u.mvp = simd_mul(ortho, make_model_rect(scrX - kReviveW * 0.5f + rw * 0.5f,
                                                                reviveY, 0.f, rw, kReviveH));
                        [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                    }
                }
            }
        }

        for (EntityID id = 0; id < world->entity_count(); ++id) {
            if (!world->exits().present(id)) continue;
            if (!world->has_component<PositionComponent>(id)) continue;
            const auto& pos = world->get_component<PositionComponent>(id);
            const ExitComponent& exit = world->get_component<ExitComponent>(id);
            int labelIndex = exit_label_index(exit);
            NSString *label = exit_label_for_component(exit);
            if (!_exitLabelTexture[labelIndex]) {
                _exitLabelTexture[labelIndex] = makeHUDLabelTexture(view.device, label,
                                                                    &_exitLabelTextureSize[labelIndex]);
            }
            if (!_exitLabelTexture[labelIndex] || !_texturePipeline) continue;
            simd_float4 clip = simd_mul(vp, (simd_float4){pos.x, pos.y, 90.f, 1.f});
            if (clip.w <= 0.f) continue;
            float ndcX = clip.x / clip.w;
            float ndcY = clip.y / clip.w;
            float scrX = (ndcX + 1.f) * 0.5f * W;
            float scrY = (1.f - ndcY) * 0.5f * H - 22.f;

            [enc setRenderPipelineState:_texturePipeline];
            [enc setDepthStencilState:_noDepthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            TextureUniforms tu;
            tu.mvp = simd_mul(ortho, make_model_rect(scrX, scrY, 0.f,
                                                     (float)_exitLabelTextureSize[labelIndex].width,
                                                     (float)_exitLabelTextureSize[labelIndex].height));
            [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
            [enc setFragmentTexture:_exitLabelTexture[labelIndex] atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

        NSString *roomText = [NSString stringWithFormat:@"ROOM %d / %d",
                              _roomIndex + 1, MAX(_totalRooms, _roomIndex + 1)];
        if (!_hudRoomTexture || ![_hudRoomText isEqualToString:roomText]) {
            _hudRoomText = [roomText copy];
            _hudRoomTexture = makeHUDLabelTexture(view.device, _hudRoomText, &_hudRoomTextureSize);
        }
        if (_hudRoomTexture && _texturePipeline) {
            [enc setRenderPipelineState:_texturePipeline];
            [enc setDepthStencilState:_noDepthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            TextureUniforms tu;
            tu.mvp = simd_mul(ortho, make_model_rect(W * 0.5f, 30.f, 0.f,
                                                     (float)_hudRoomTextureSize.width,
                                                     (float)_hudRoomTextureSize.height));
            [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
            [enc setFragmentTexture:_hudRoomTexture atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

        if (_curseMult > 1.0001f) {
            NSString *curseText = [NSString stringWithFormat:@"CURSE x%.2f", _curseMult];
            if (!_hudCurseTexture || ![_hudCurseText isEqualToString:curseText]) {
                _hudCurseText = [curseText copy];
                _hudCurseTexture = makeHUDLabelTexture(view.device, _hudCurseText, &_hudCurseTextureSize);
            }
            if (_hudCurseTexture && _texturePipeline) {
                [enc setRenderPipelineState:_texturePipeline];
                [enc setDepthStencilState:_noDepthState];
                [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
                TextureUniforms tu;
                tu.mvp = simd_mul(ortho, make_model_rect(W * 0.5f, 58.f, 0.f,
                                                         (float)_hudCurseTextureSize.width,
                                                         (float)_hudCurseTextureSize.height));
                [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
                [enc setFragmentTexture:_hudCurseTexture atIndex:0];
                [enc setFragmentSamplerState:_linearSampler atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }

        NSString *scrapText = [NSString stringWithFormat:@"SCRAP %d", _scrapCount];
        if (!_hudScrapTexture || ![_hudScrapText isEqualToString:scrapText]) {
            _hudScrapText = [scrapText copy];
            _hudScrapTexture = makeHUDLabelTexture(view.device, _hudScrapText, &_hudScrapTextureSize);
        }
        if (_hudScrapTexture && _texturePipeline) {
            [enc setRenderPipelineState:_texturePipeline];
            [enc setDepthStencilState:_noDepthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            TextureUniforms tu;
            tu.mvp = simd_mul(ortho, make_model_rect(W * 0.5f + 205.f, 30.f, 0.f,
                                                     (float)_hudScrapTextureSize.width,
                                                     (float)_hudScrapTextureSize.height));
            [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
            [enc setFragmentTexture:_hudScrapTexture atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

        NSString *scoreText = [NSString stringWithFormat:@"SCORE %d", _scoreValue];
        if (!_hudScoreTexture || ![_hudScoreText isEqualToString:scoreText]) {
            _hudScoreText = [scoreText copy];
            _hudScoreTexture = makeHUDLabelTexture(view.device, _hudScoreText, &_hudScoreTextureSize);
        }
        if (_hudScoreTexture && _texturePipeline) {
            [enc setRenderPipelineState:_texturePipeline];
            [enc setDepthStencilState:_noDepthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            TextureUniforms tu;
            tu.mvp = simd_mul(ortho, make_model_rect(W - 96.f, 30.f, 0.f,
                                                     (float)_hudScoreTextureSize.width,
                                                     (float)_hudScoreTextureSize.height));
            [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
            [enc setFragmentTexture:_hudScoreTexture atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }

        if (_comboCount >= 2) {
            NSString *comboText = [NSString stringWithFormat:@"COMBO x%d", _comboCount];
            if (!_hudComboTexture || ![_hudComboText isEqualToString:comboText]) {
                _hudComboText = [comboText copy];
                _hudComboTexture = makeHUDLabelTexture(view.device, _hudComboText, &_hudComboTextureSize);
            }
            if (_hudComboTexture && _texturePipeline) {
                float scale = 1.f + 0.18f * (_comboPop / 0.18f);
                [enc setRenderPipelineState:_texturePipeline];
                [enc setDepthStencilState:_noDepthState];
                [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
                TextureUniforms tu;
                tu.mvp = simd_mul(ortho, make_model_rect(W * 0.5f, 68.f, 0.f,
                                                         (float)_hudComboTextureSize.width * scale,
                                                         (float)_hudComboTextureSize.height * scale));
                [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
                [enc setFragmentTexture:_hudComboTexture atIndex:0];
                [enc setFragmentSamplerState:_linearSampler atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }

        NSString *promptText = _shopPrompt ?: @"";
        if (promptText.length > 0) {
            if (!_shopPromptTexture || ![_shopPromptText isEqualToString:promptText]) {
                _shopPromptText = [promptText copy];
                _shopPromptTexture = makeHUDLabelTexture(view.device, _shopPromptText, &_shopPromptTextureSize);
            }
            if (_shopPromptTexture && _texturePipeline) {
                [enc setRenderPipelineState:_texturePipeline];
                [enc setDepthStencilState:_noDepthState];
                [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
                TextureUniforms tu;
                tu.mvp = simd_mul(ortho, make_model_rect(W * 0.5f, H - 42.f, 0.f,
                                                         (float)_shopPromptTextureSize.width,
                                                         (float)_shopPromptTextureSize.height));
                [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
                [enc setFragmentTexture:_shopPromptTexture atIndex:0];
                [enc setFragmentSamplerState:_linearSampler atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }

        // Lives dots — row of small red squares, top-left corner.
        {
            static const float kDotSize   = 22.f;
            static const float kDotGap    = 8.f;
            static const float kDotMargin = 20.f;
            float dotY = kDotMargin + kDotSize * 0.5f;
            for (int i = 0; i < _livesRemaining; ++i) {
                float dotX = kDotMargin + kDotSize * 0.5f + i * (kDotSize + kDotGap);
                DrawUniforms u;
                u.color = (simd_float4){0.90f, 0.20f, 0.20f, 1.f};
                u.mvp   = simd_mul(ortho, make_model_rect(dotX, dotY, 0.f, kDotSize, kDotSize));
                [enc setVertexBytes:&u length:sizeof(u) atIndex:1];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
        }
    }

    // Shared phase/menu overlay — generated as a CoreGraphics texture and
    // drawn inside the Metal frame so the visual smoke harness captures it.
    if (_overlayVisible && _texturePipeline) {
        if (_overlayDirty || !_overlayTexture) {
            _overlayTexture = makeOverlayTexture(view.device,
                                                (CGFloat)view.currentDrawable.texture.width,
                                                (CGFloat)view.currentDrawable.texture.height,
                                                _overlayTitle, _overlaySubtitle,
                                                _overlayChoiceA, _overlayChoiceB,
                                                _overlayStatLines,
                                                &_overlayTextureSize);
            _overlayDirty = NO;
        }
        if (_overlayTexture) {
            CGSize ds = view.drawableSize;
            float W = (float)ds.width, H = (float)ds.height;
            simd_float4x4 ortho = matrix_identity_float4x4;
            ortho.columns[0].x =  2.f / W;
            ortho.columns[1].y = -2.f / H;
            ortho.columns[3]   = (simd_float4){-1.f, 1.f, 0.f, 1.f};

            float panelW = (float)_overlayTextureSize.width;
            float panelH = (float)_overlayTextureSize.height;
            TextureUniforms tu;
            tu.mvp = simd_mul(ortho, make_model_rect(W * 0.5f, H * 0.54f, 0.f, panelW, panelH));
            [enc setRenderPipelineState:_texturePipeline];
            [enc setDepthStencilState:_noDepthState];
            [enc setVertexBuffer:_quadVB offset:0 atIndex:0];
            [enc setVertexBytes:&tu length:sizeof(tu) atIndex:1];
            [enc setFragmentTexture:_overlayTexture atIndex:0];
            [enc setFragmentSamplerState:_linearSampler atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        }
    }

    [enc endEncoding];

    // --autotest screenshot: blit the drawable into a CPU-readable buffer and
    // write a PNG once the GPU finishes the frame.
    if (_pendingCapturePath) {
        NSString *path = _pendingCapturePath;
        _pendingCapturePath = nil;

        id<MTLTexture> tex = view.currentDrawable.texture;
        if (tex.framebufferOnly) {
            NSLog(@"BrawlerRenderer: capture skipped — view.framebufferOnly must be NO");
        } else {
            NSUInteger w   = tex.width, h = tex.height;
            NSUInteger bpr = ((w * 4 + 255) / 256) * 256; // blit requires 256-byte row alignment
            id<MTLBuffer> staging = [tex.device newBufferWithLength:bpr * h
                                                            options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1)
                         toBuffer:staging destinationOffset:0
            destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
            [blit endEncoding];

            [cmd addCompletedHandler:^(id<MTLCommandBuffer> _) {
                writePNG(staging, w, h, bpr, path);
            }];
        }
    }

    [cmd presentDrawable:view.currentDrawable];
}

static void drawCenteredLine(CGContextRef ctx, NSString *text, CGFloat centerX, CGFloat baselineY,
                             CGFloat maxWidth, CGFloat fontSize, CGFloat minFontSize,
                             CGColorRef color) {
    if (text.length == 0) return;
    CGFloat size = fontSize;
    CTFontRef font = NULL;
    CFAttributedStringRef attr = NULL;
    CTLineRef line = NULL;

    while (size >= minFontSize) {
        if (line) CFRelease(line);
        if (attr) CFRelease(attr);
        if (font) CFRelease(font);
        font = CTFontCreateWithName(CFSTR("HelveticaNeue-Bold"), size, NULL);
        NSDictionary *attrs = @{
            (__bridge id)kCTFontAttributeName: (__bridge id)font,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color,
        };
        attr = CFAttributedStringCreate(kCFAllocatorDefault, (__bridge CFStringRef)text,
                                        (__bridge CFDictionaryRef)attrs);
        line = CTLineCreateWithAttributedString(attr);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
        if (width <= maxWidth || size <= minFontSize) break;
        size -= 2.f;
    }

    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CGContextSetTextPosition(ctx, centerX - (CGFloat)width * 0.5f, baselineY);
    CTLineDraw(line, ctx);

    if (line) CFRelease(line);
    if (attr) CFRelease(attr);
    if (font) CFRelease(font);
}

static id<MTLTexture> makeOverlayTexture(id<MTLDevice> device, CGFloat drawableW, CGFloat drawableH,
                                         NSString *title, NSString *subtitle,
                                         NSString *choiceA, NSString *choiceB,
                                         NSArray<NSString*> *statLines,
                                         CGSize *outSize) {
    BOOL hasChoices = choiceA.length > 0 || choiceB.length > 0;
    BOOL hasStats = statLines.count > 0;
    CGFloat panelW = hasChoices ? 980.f : 760.f;
    CGFloat panelH = hasChoices ? 340.f : (hasStats ? 430.f : 260.f);
    panelW = MIN(panelW, drawableW - 64.f);
    panelH = MIN(panelH, drawableH - 64.f);
    panelW = MAX(panelW, 360.f);
    panelH = MAX(panelH, hasStats ? 300.f : 170.f);

    NSUInteger w = (NSUInteger)ceil(panelW);
    NSUInteger h = (NSUInteger)ceil(panelH);
    NSUInteger bpr = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * h];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bpr, cs, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.74);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.10);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeRect(ctx, CGRectMake(1, 1, w - 2, h - 2));

    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    CGFloat maxTextW = panelW - 96.f;
    CGFloat titleSize = hasChoices ? 58.f : 64.f;
    CGFloat choiceSize = 46.f;
    CGFloat subtitleSize = 40.f;

    drawCenteredLine(ctx, title, panelW * 0.5f, hasStats ? panelH * 0.78f : panelH * 0.70f, maxTextW,
                     titleSize, 34.f, white);
    if (subtitle.length > 0)
        drawCenteredLine(ctx, subtitle, panelW * 0.5f, hasStats ? panelH * 0.63f : panelH * 0.38f,
                         maxTextW, subtitleSize, 26.f, white);
    if (hasStats) {
        CGColorRef softWhite = CGColorCreateGenericRGB(0.92, 0.94, 0.98, 1);
        CGFloat y = panelH * (subtitle.length > 0 ? 0.50f : 0.58f);
        for (NSString *line in statLines) {
            drawCenteredLine(ctx, line, panelW * 0.5f, y, maxTextW, 28.f, 18.f, softWhite);
            y -= 38.f;
        }
        CGColorRelease(softWhite);
    }
    if (hasChoices) {
        drawCenteredLine(ctx, choiceA, panelW * 0.5f, panelH * 0.40f,
                         maxTextW, choiceSize, 28.f, white);
        drawCenteredLine(ctx, choiceB, panelW * 0.5f, panelH * 0.22f,
                         maxTextW, choiceSize, 28.f, white);
    }
    CGColorRelease(white);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
           mipmapLevel:0
             withBytes:pixels.bytes
           bytesPerRow:bpr];
    if (outSize) *outSize = CGSizeMake(w, h);
    return tex;
}

static id<MTLTexture> makeHUDLabelTexture(id<MTLDevice> device, NSString *text, CGSize *outSize) {
    CGFloat wFloat = fmax(190.f, fmin(520.f, 24.f + (CGFloat)text.length * 9.0f));
    CGFloat hFloat = 38.f;
    NSUInteger w = (NSUInteger)ceil(wFloat);
    NSUInteger h = (NSUInteger)ceil(hFloat);
    NSUInteger bpr = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * h];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bpr, cs, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.44);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetRGBStrokeColor(ctx, 1.0, 1.0, 1.0, 0.10);
    CGContextStrokeRect(ctx, CGRectMake(0.5, 0.5, w - 1, h - 1));

    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    drawCenteredLine(ctx, text, wFloat * 0.5f, 12.f, wFloat - 18.f, 22.f, 16.f, white);
    CGColorRelease(white);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
           mipmapLevel:0
             withBytes:pixels.bytes
           bytesPerRow:bpr];
    if (outSize) *outSize = CGSizeMake(w, h);
    return tex;
}

// Write a BGRA8 staging buffer as a PNG. Runs on the Metal completion thread.
static void writePNG(id<MTLBuffer> staging, NSUInteger w, NSUInteger h,
                     NSUInteger bpr, NSString *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(staging.contents, w, h, 8, bpr, cs, bitmapInfo); // BGRA, ignore alpha
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (img) {
        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
        if (dst) {
            CGImageDestinationAddImage(dst, img, NULL);
            CGImageDestinationFinalize(dst);
            CFRelease(dst);
        }
        CGImageRelease(img);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

- (void)captureNextFrameToPath:(NSString*)path {
    _pendingCapturePath = [path copy];
}

- (void)spawnBurstAt:(simd_float3)pos
               count:(int)count
               speed:(float)speed
                size:(float)size
               color:(simd_float4)color {
    _burstSeed = _burstSeed * 1664525u + 1013904223u;
    _particles.spawn_burst(pos.x, pos.y, pos.z, count, speed, size,
                           color.x, color.y, color.z, _burstSeed);
}

@end
