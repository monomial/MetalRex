#import "RexRenderer.h"
#include "Assets/CharacterLoader.h"
#include "Simulation/CameraMath.h"
#include "Simulation/World.h"
#include "Simulation/Systems/AnimationSystem.h"
#include "Simulation/Systems/ReticleSystem.h"
#include <TargetConditionals.h>
#include <algorithm>
#include <vector>
#include <simd/simd.h>
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>

struct RexVertex {
    simd_float3 position;
};

// Writes a BGRA8 staging buffer as a PNG. Runs on the Metal completion thread.
static void RexRenderer_writePNG(id<MTLBuffer> staging, NSUInteger w, NSUInteger h,
                                  NSUInteger bpr, NSString *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
    CGContextRef ctx = CGBitmapContextCreate(staging.contents, w, h, 8, bpr, cs, bitmapInfo);
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

struct RexUniforms {
    simd_float4x4 mvp;
    simd_float4 color;
};

struct RexTextureUniformsCPU {
    simd_float4x4 mvp; // must match RexTextureUniforms in Rex.metal field-for-field
};

struct SkinnedUniformsCPU {
    simd_float4x4 mvp;
    simd_float4x4 modelRotation; // must match SkinnedMesh.metal's SkinnedUniforms field-for-field
    simd_float4 color;
    simd_float4 lightDir; // xyz: world-space direction toward the light
    float tintStrength;
};

@implementation RexRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLRenderPipelineState> _skinnedPipeline;
    id<MTLDepthStencilState> _depthState;
    id<MTLDepthStencilState> _overlayDepthState;
    id<MTLSamplerState> _sampler;
    id<MTLBuffer> _groundVB;
    LoadedCharacter *_dinoChars[(int)DinoSpecies::Count]; // indexed by DinoSpecies
    simd_float4x4 _overlayProjection;
    float _halfW;
    float _halfH;
    float _aspect;
    NSString *_pendingCapturePath; // --capture-out=: next frame -> PNG

    // Shot tracer effects (renderer-local cosmetics; the sim only exposes
    // ReticleComponent::shotCount, which is diffed per frame to spawn these).
    struct ShotTracer {
        float startX, startY;   // overlay px — gun muzzle anchor
        float endX, endY;       // overlay px — reticle at the moment of the shot
        float age;              // seconds
        int player;
    };
    std::vector<ShotTracer> _tracers;
    uint32_t _lastShotCount[kRexMaxPlayers];
    CFTimeInterval _lastOverlayTime;

    // Textured 2D overlay (GAME OVER / continue panel): unit quad + a
    // pipeline that samples a CoreText-rendered texture instead of a flat
    // color. The panel's content never changes, so the texture is built
    // once and cached rather than regenerated every frame.
    id<MTLRenderPipelineState> _texturePipeline;
    id<MTLBuffer> _texQuadVB;
    id<MTLTexture> _gameOverTexture;
    CGSize _gameOverTextureSize;
    id<MTLTexture> _pressFireTexture;
    CGSize _pressFireTextureSize;
    id<MTLTexture> _scoreTextures[kRexMaxPlayers];
    CGSize _scoreTextureSizes[kRexMaxPlayers];
    NSString *_scoreText[kRexMaxPlayers];
    BOOL _debugHUDVisible;
    id<MTLTexture> _debugLabelsTexture;
    CGSize _debugLabelsTextureSize;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat {
    self = [super init];
    if (!self) return nil;

    _device = device;
    _debugHUDVisible = YES;
    // Extends behind the rail start (z < 0): the camera faces backward off
    // the jeep, so the ground behind the run must exist too.
    const RexVertex verts[] = {
        {{-8.f, kGroundWorldY, -20.f}}, {{ 8.f, kGroundWorldY, -20.f}}, {{-8.f, kGroundWorldY, 80.f}},
        {{ 8.f, kGroundWorldY, -20.f}}, {{ 8.f, kGroundWorldY, 80.f}}, {{-8.f, kGroundWorldY, 80.f}},
    };
    _groundVB = [_device newBufferWithBytes:verts length:sizeof(verts) options:MTLResourceStorageModeShared];

    NSMutableString *source = [NSMutableString string];
    for (NSString *name in @[@"Rex", @"SkinnedMesh"]) {
        NSString *path = [[NSBundle mainBundle] pathForResource:name
                                                          ofType:@"metal"
                                                     inDirectory:@"Shaders"];
        if (!path) {
            NSLog(@"RexRenderer: Shaders/%@.metal missing from bundle", name);
            return nil;
        }
        NSError *readError = nil;
        NSString *chunk = [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding
                                                       error:&readError];
        if (!chunk) {
            NSLog(@"RexRenderer: failed to read %@: %@", path, readError);
            return nil;
        }
        [source appendString:chunk];
        [source appendString:@"\n"];
    }

    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:&error];
    if (!library) {
        NSLog(@"RexRenderer: shader library failed: %@", error);
        return nil;
    }

    MTLRenderPipelineDescriptor *pipelineDescriptor = [MTLRenderPipelineDescriptor new];
    pipelineDescriptor.vertexFunction = [library newFunctionWithName:@"rex_vertex"];
    pipelineDescriptor.fragmentFunction = [library newFunctionWithName:@"rex_fragment"];
    pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat;
    pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    // Alpha blending: every existing draw call passes alpha=1 (opaque, no
    // visual change), but the new fire-flash ring fades via alpha<1 and
    // needs this to actually be respected rather than rendered fully opaque
    // for its whole lifetime.
    pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
    pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!_pipeline) {
        NSLog(@"RexRenderer: pipeline failed: %@", error);
        return nil;
    }

    MTLRenderPipelineDescriptor *textureDescriptor = [MTLRenderPipelineDescriptor new];
    textureDescriptor.vertexFunction = [library newFunctionWithName:@"rex_texture_vertex"];
    textureDescriptor.fragmentFunction = [library newFunctionWithName:@"rex_texture_fragment"];
    textureDescriptor.colorAttachments[0].pixelFormat = pixelFormat;
    textureDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    textureDescriptor.colorAttachments[0].blendingEnabled = YES;
    textureDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    textureDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    textureDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    textureDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    textureDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    textureDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _texturePipeline = [_device newRenderPipelineStateWithDescriptor:textureDescriptor error:&error];
    if (!_texturePipeline) {
        NSLog(@"RexRenderer: texture pipeline failed: %@", error);
        return nil;
    }
    const RexVertex texQuadVerts[] = {
        {{-0.5f, -0.5f, 0.f}}, {{0.5f, -0.5f, 0.f}}, {{-0.5f, 0.5f, 0.f}},
        {{0.5f, -0.5f, 0.f}}, {{0.5f, 0.5f, 0.f}}, {{-0.5f, 0.5f, 0.f}},
    };
    _texQuadVB = [_device newBufferWithBytes:texQuadVerts length:sizeof(texQuadVerts)
                                      options:MTLResourceStorageModeShared];

    MTLRenderPipelineDescriptor *skinnedDescriptor = [MTLRenderPipelineDescriptor new];
    skinnedDescriptor.vertexFunction = [library newFunctionWithName:@"skinned_vertex_main"];
    skinnedDescriptor.fragmentFunction = [library newFunctionWithName:@"skinned_fragment_main"];
    skinnedDescriptor.colorAttachments[0].pixelFormat = pixelFormat;
    skinnedDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    // Metal's [[stage_in]] vertex attributes need an explicit MTLVertexDescriptor
    // describing the interleaved buffer layout — it isn't inferred from the
    // shader struct alone. Must match SkinnedVertex in SkinnedMesh.metal and
    // LoadedCharacter's "72 B/vtx" comment exactly: pos(3f)+nrm(3f)+uv(2f)+
    // color(4f)+jointIdx(4×ushort)+jointWeight(4f).
    MTLVertexDescriptor *skinnedVertexDescriptor = [MTLVertexDescriptor new];
    skinnedVertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;   // position
    skinnedVertexDescriptor.attributes[0].offset = 0;
    skinnedVertexDescriptor.attributes[0].bufferIndex = 0;
    skinnedVertexDescriptor.attributes[1].format = MTLVertexFormatFloat3;   // normal
    skinnedVertexDescriptor.attributes[1].offset = 12;
    skinnedVertexDescriptor.attributes[1].bufferIndex = 0;
    skinnedVertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;   // texcoord
    skinnedVertexDescriptor.attributes[2].offset = 24;
    skinnedVertexDescriptor.attributes[2].bufferIndex = 0;
    skinnedVertexDescriptor.attributes[3].format = MTLVertexFormatFloat4;   // color
    skinnedVertexDescriptor.attributes[3].offset = 32;
    skinnedVertexDescriptor.attributes[3].bufferIndex = 0;
    skinnedVertexDescriptor.attributes[4].format = MTLVertexFormatUShort4; // jointIdx
    skinnedVertexDescriptor.attributes[4].offset = 48;
    skinnedVertexDescriptor.attributes[4].bufferIndex = 0;
    skinnedVertexDescriptor.attributes[5].format = MTLVertexFormatFloat4;   // jointWeight
    skinnedVertexDescriptor.attributes[5].offset = 56;
    skinnedVertexDescriptor.attributes[5].bufferIndex = 0;
    skinnedVertexDescriptor.layouts[0].stride = 72;
    skinnedVertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    skinnedDescriptor.vertexDescriptor = skinnedVertexDescriptor;

    _skinnedPipeline = [_device newRenderPipelineStateWithDescriptor:skinnedDescriptor error:&error];
    if (!_skinnedPipeline) {
        NSLog(@"RexRenderer: skinned pipeline failed: %@", error);
        return nil;
    }

    MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthDescriptor];

    // For screen-space overlay draws (reticle/targets/HUD) that intentionally
    // ignore depth, Metal API validation rejects setDepthStencilState:nil once
    // a real state has been set on the encoder — must pass an explicit
    // depth-test-disabled state instead of nil.
    MTLDepthStencilDescriptor *noDepthDescriptor = [MTLDepthStencilDescriptor new];
    noDepthDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
    noDepthDescriptor.depthWriteEnabled = NO;
    _overlayDepthState = [_device newDepthStencilStateWithDescriptor:noDepthDescriptor];

    MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeRepeat;
    _sampler = [_device newSamplerStateWithDescriptor:samplerDescriptor];

    _overlayProjection = Rex_make_ortho(-640.f, 640.f, -420.f, 420.f, -1.f, 1.f);
    _halfW = 640.f;
    _halfH = 420.f;
    _aspect = 16.f / 9.f;

    // One LoadedCharacter per DinoSpecies, indexed by the enum. Directory
    // names must line up with the species order in Components.h.
    NSArray<NSString*> *speciesDirs = @[@"velociraptor", @"trex"];
    for (int s = 0; s < (int)DinoSpecies::Count; ++s) {
        NSString *dinoDir = [[NSBundle mainBundle] pathForResource:speciesDirs[s]
                                                            ofType:nil
                                                       inDirectory:@"assets/characters/dinos"];
        if (!dinoDir.length) {
            NSLog(@"RexRenderer: %@ asset directory missing", speciesDirs[s]);
            continue;
        }
        NSString *basePath = [dinoDir stringByAppendingPathComponent:@"base.usdz"];
        NSMutableArray<NSString*> *clips = [NSMutableArray arrayWithCapacity:(NSUInteger)CharacterClipSlot::Count];
        for (int i = 0; i < (int)CharacterClipSlot::Count; ++i) {
            NSString *name = [NSString stringWithUTF8String:CharacterClipSlot_name((CharacterClipSlot)i)];
            [clips addObject:[dinoDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"usdz"]]];
        }
        @try {
            try {
                _dinoChars[s] = CharacterLoader_load(basePath, clips, _device);
                AnimationSystem_set_dino_character((DinoSpecies)s, _dinoChars[s]);
            } catch (const std::exception& ex) {
                NSLog(@"RexRenderer: %@ load failed: %s", speciesDirs[s], ex.what());
            }
        } @catch (NSException *exception) {
            NSLog(@"RexRenderer: %@ load failed: %@", speciesDirs[s], exception.reason);
        }
    }

    return self;
}

- (void)dealloc {
    for (int s = 0; s < (int)DinoSpecies::Count; ++s) {
        delete _dinoChars[s];
    }
}

- (void)updateDrawableSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    float aspect = (float)size.width / (float)size.height;
    float halfH = 420.f;
    float halfW = halfH * aspect;
    _overlayProjection = Rex_make_ortho(-halfW, halfW, -halfH, halfH, -1.f, 1.f);
    _halfW = halfW;
    _halfH = halfH;
    _aspect = aspect;
}

- (simd_float3)_screenPointX:(float)x y:(float)y z:(float)z {
    return (simd_float3){(x - 0.5f) * _halfW * 2.f, (y - 0.5f) * _halfH * 2.f, z};
}

- (void)_drawVertices:(const std::vector<RexVertex>&)vertices
                color:(simd_float4)color
             primitive:(MTLPrimitiveType)primitive
                   mvp:(simd_float4x4)mvp
              encoder:(id<MTLRenderCommandEncoder>)encoder {
    if (vertices.empty()) return;
    RexUniforms uniforms;
    uniforms.mvp = mvp;
    uniforms.color = color;
    [encoder setVertexBytes:vertices.data()
                     length:sizeof(RexVertex) * vertices.size()
                    atIndex:0];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder drawPrimitives:primitive vertexStart:0 vertexCount:(NSUInteger)vertices.size()];
}

- (void)_appendQuad:(std::vector<RexVertex>&)vertices
             center:(simd_float3)center
              halfW:(float)halfW
              halfH:(float)halfH {
    float l = center.x - halfW;
    float r = center.x + halfW;
    float b = center.y - halfH;
    float t = center.y + halfH;
    float z = center.z;
    vertices.push_back({{l, b, z}});
    vertices.push_back({{r, b, z}});
    vertices.push_back({{l, t, z}});
    vertices.push_back({{r, b, z}});
    vertices.push_back({{r, t, z}});
    vertices.push_back({{l, t, z}});
}

- (simd_float4x4)_worldViewProjection:(const RailCameraState&)camera {
    simd_float3 eye = (simd_float3){camera.positionX, camera.positionY, camera.positionZ};
    simd_float3 lookAt = (simd_float3){camera.lookAtX, camera.lookAtY, camera.lookAtZ};
    simd_float4x4 view = Rex_make_look_at(eye, lookAt, (simd_float3){0.f, 1.f, 0.f});
    simd_float4x4 projection = Rex_make_perspective(camera.fovYRadians, _aspect, camera.nearZ, camera.farZ);
    return simd_mul(projection, view);
}

- (void)_drawM1Targets:(World *)world
                   mvp:(simd_float4x4)mvp
               encoder:(id<MTLRenderCommandEncoder>)encoder {
    std::vector<RexVertex> active;
    std::vector<RexVertex> hit;
    const RailCameraState& camera = world->rail_camera();
    simd_float3 cameraRight = (simd_float3){camera.rightX, camera.rightY, camera.rightZ};
    simd_float3 cameraUp = (simd_float3){camera.upX, camera.upY, camera.upZ};
    for (int i = 0; i < kM1MaxTargets; ++i) {
        bool isDinoTarget = false;
        for (EntityID id = 0; id < world->entity_count(); ++id) {
            if (!world->has_component<DinoBehaviorComponent>(id)) continue;
            const DinoBehaviorComponent& dino = world->get_component<DinoBehaviorComponent>(id);
            if (dino.active && dino.targetIndex == i) {
                isDinoTarget = true;
                break;
            }
        }
        if (isDinoTarget) continue;
        const TargetComponent& target = world->target(i);
        if (!target.active) continue;
        simd_float3 center = (simd_float3){target.worldX, target.worldY, target.worldZ};
        std::vector<RexVertex>& vertices = target.wasHit ? hit : active;
        simd_float3 lb = center - cameraRight * target.halfWidth - cameraUp * target.halfHeight;
        simd_float3 rb = center + cameraRight * target.halfWidth - cameraUp * target.halfHeight;
        simd_float3 lt = center - cameraRight * target.halfWidth + cameraUp * target.halfHeight;
        simd_float3 rt = center + cameraRight * target.halfWidth + cameraUp * target.halfHeight;
        vertices.push_back({lb});
        vertices.push_back({rb});
        vertices.push_back({lt});
        vertices.push_back({rb});
        vertices.push_back({rt});
        vertices.push_back({lt});
    }
    [self _drawVertices:active color:(simd_float4){0.82f, 0.27f, 0.18f, 1.f}
              primitive:MTLPrimitiveTypeTriangle mvp:mvp encoder:encoder];
    [self _drawVertices:hit color:(simd_float4){0.96f, 0.78f, 0.24f, 1.f}
              primitive:MTLPrimitiveTypeTriangle mvp:mvp encoder:encoder];
}

- (void)_drawDinos:(World *)world
               mvp:(simd_float4x4)viewProjection
           encoder:(id<MTLRenderCommandEncoder>)encoder {
    [encoder setRenderPipelineState:_skinnedPipeline];
    [encoder setFragmentSamplerState:_sampler atIndex:0];

    for (EntityID id = 0; id < world->entity_count(); ++id) {
        if (!world->has_component<DinoBehaviorComponent>(id)
            || !world->has_component<AnimationComponent>(id)) {
            continue;
        }
        const DinoBehaviorComponent& dino = world->get_component<DinoBehaviorComponent>(id);
        if (!dino.active || dino.targetIndex >= kM1MaxTargets) continue;
        const TargetComponent& target = world->target(dino.targetIndex);
        if (!target.active) continue;

        LoadedCharacter *character = _dinoChars[(int)dino.species % (int)DinoSpecies::Count];
        if (!character || !character->vertexBuffer || !character->indexBuffer) continue;
        [encoder setFragmentTexture:character->diffuseTexture atIndex:0];

        // The Quaternius dino meshes are authored Z-up (Blender local space:
        // +Z is the dino's up, +Y runs nose-to-tail, X is width — the T-Rex
        // bounds make this unambiguous: Y extent 31 units vs Z 15 vs X 8; no
        // dinosaur is 4x taller than long). The engine is Y-up, so without a
        // pitch correction the dino stands vertically on its nose with the
        // tail as a sky-pointing spike — which is exactly what every earlier
        // "wrong angle / thin / spike" report was. Pitch -90° about X maps
        // mesh +Z (its up) onto world +Y, and mesh -Y (its nose) onto world
        // +Z, so vertical scale/grounding must use the mesh's Z bounds, not
        // its Y bounds.
        float meshUpExtent = character->meshZMax - character->meshZMin;
        float visualHeight = std::max(0.1f, target.halfHeight * 2.0f);
        float scale = (meshUpExtent > 0.0001f) ? visualHeight / meshUpExtent : 1.0f;

        simd_float4x4 pitch = matrix_identity_float4x4;
        pitch.columns[1] = (simd_float4){ 0.f, 0.f, -1.f, 0.f }; // mesh +Y (tail) -> world -Z
        pitch.columns[2] = (simd_float4){ 0.f, 1.f, 0.f, 0.f };  // mesh +Z (up)   -> world +Y

        // Face the camera (yaw about world Y). After the pitch above the
        // mesh's nose points at world +Z, so aiming +Z at the camera is
        // exactly atan2(dx, dz) with no half-turn correction.
        const RailCameraState& camera = world->rail_camera();
        float dx = camera.positionX - target.worldX;
        float dz = camera.positionZ - target.worldZ;
        float yaw = atan2f(dx, dz);
        float cosYaw = cosf(yaw);
        float sinYaw = sinf(yaw);

        simd_float4x4 yawRotation = matrix_identity_float4x4;
        yawRotation.columns[0] = (simd_float4){ cosYaw, 0.f, -sinYaw, 0.f };
        yawRotation.columns[1] = (simd_float4){ 0.f, 1.f, 0.f, 0.f };
        yawRotation.columns[2] = (simd_float4){ sinYaw, 0.f, cosYaw, 0.f };

        simd_float4x4 modelRotation = simd_mul(yawRotation, pitch);

        simd_float4x4 model = modelRotation;
        model.columns[0] *= scale;
        model.columns[1] *= scale;
        model.columns[2] *= scale;
        // After the pitch, a vertex's world height is its mesh-space Z, so
        // ground alignment anchors meshZMin (the feet) at ground level.
        model.columns[3] = (simd_float4){
            target.worldX,
            target.worldY - character->meshZMin * scale - target.halfHeight,
            target.worldZ,
            1.f
        };

        const AnimationComponent& anim = world->get_component<AnimationComponent>(id);

        SkinnedUniformsCPU uniforms;
        uniforms.mvp = simd_mul(viewProjection, model);
        uniforms.modelRotation = modelRotation;
        // Hit flash while hitFlashTime runs; the alpha channel carries
        // deathFade — the shader screen-door-dissolves the corpse as it
        // drops below 1.
        bool hitFlash = dino.hitFlashTime > 0.f;
        uniforms.color = hitFlash ? (simd_float4){0.96f, 0.78f, 0.24f, anim.deathFade}
                                  : (simd_float4){1.f, 1.f, 1.f, anim.deathFade};
        // Light from the camera's side, raised a bit so top surfaces read
        // brighter than undersides (pure headlight lighting looks flat).
        simd_float3 towardCamera = simd_normalize((simd_float3){
            dx, camera.positionY - target.worldY, dz});
        simd_float3 lightDir = simd_normalize(towardCamera + (simd_float3){0.f, 0.9f, 0.f});
        uniforms.lightDir = (simd_float4){lightDir.x, lightDir.y, lightDir.z, 0.f};
        uniforms.tintStrength = hitFlash ? 0.45f : 0.f;

        [encoder setVertexBuffer:character->vertexBuffer offset:0 atIndex:0];
        [encoder setVertexBytes:anim.boneMatrices length:sizeof(anim.boneMatrices) atIndex:1];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:character->indexCount
                             indexType:character->indexType
                           indexBuffer:character->indexBuffer
                     indexBufferOffset:0];
    }

    [encoder setRenderPipelineState:_pipeline];
}

// Appends a solid quad along the segment (x0,y0)->(x1,y1) with the given
// half-width, as two triangles, into `out` (overlay pixel space).
static void appendSegmentQuad(std::vector<RexVertex>& out,
                              float x0, float y0, float x1, float y1,
                              float halfWidth, float z) {
    float dx = x1 - x0;
    float dy = y1 - y0;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.0001f) return;
    float nx = -dy / len * halfWidth;
    float ny =  dx / len * halfWidth;
    out.push_back({{x0 + nx, y0 + ny, z}});
    out.push_back({{x0 - nx, y0 - ny, z}});
    out.push_back({{x1 + nx, y1 + ny, z}});
    out.push_back({{x0 - nx, y0 - ny, z}});
    out.push_back({{x1 - nx, y1 - ny, z}});
    out.push_back({{x1 + nx, y1 + ny, z}});
}

// Where each player's gun sits on screen (normalized x; y is the bottom
// edge): P1 left of center, P2 right, like two shooters in the jeep bed.
static const float kGunAnchorX[kRexMaxPlayers] = {0.36f, 0.64f, 0.30f, 0.70f};

// Per-player reticle/HUD colors (arcade style — each player instantly knows
// which sight/health row is theirs): P1 warm pink/red, P2 cyan, then
// green/amber for 3P/4P if that ever ships. Shared by _drawReticles: and
// _drawHUD: so a player's crosshair and health row read as the same color.
static const simd_float4 kReticleColors[kRexMaxPlayers] = {
    {1.00f, 0.42f, 0.55f, 1.f},
    {0.16f, 0.85f, 0.95f, 1.f},
    {0.45f, 0.95f, 0.45f, 1.f},
    {0.98f, 0.80f, 0.30f, 1.f},
};

// Fixed canvas size baked by Rex_makeScoreTexture — shared with _drawHUD's
// corner layout math so the two stay in sync without a magic number in both.
static const float kScoreTexW = 300.f;
static const float kScoreTexH = 110.f;

// Builds an mvp that places the unit quad ([-0.5,0.5] in both axes, see
// _texQuadVB) centered at (x,y) with the given pixel width/height, in
// _overlayProjection's pixel space (ported from MetalBrawler's
// make_model_rect / BrawlerRenderer.mm).
static simd_float4x4 Rex_make_model_rect(simd_float4x4 overlayProjection,
                                         float x, float y, float z, float w, float h) {
    simd_float4x4 model = matrix_identity_float4x4;
    model.columns[0].x = w;
    model.columns[1].y = h;
    model.columns[3] = (simd_float4){x, y, z, 1.f};
    return simd_mul(overlayProjection, model);
}

// Centers a single line of text at (centerX, baselineY) in a CoreGraphics
// bitmap context, shrinking the font until it fits maxWidth. Ported from
// MetalBrawler's BrawlerRenderer.mm drawCenteredLine.
static void Rex_drawCenteredLine(CGContextRef ctx, NSString *text, CGFloat centerX, CGFloat baselineY,
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
    CGContextSetTextPosition(ctx, centerX - (CGFloat)width * 0.5, baselineY);
    CTLineDraw(line, ctx);

    if (line) CFRelease(line);
    if (attr) CFRelease(attr);
    if (font) CFRelease(font);
}

// Builds the (static-content, cached-by-caller) GAME OVER / continue panel
// texture. Ported from MetalBrawler's makeOverlayTexture, trimmed to the
// title+subtitle case since MetalRex has no choice/stat-line HUD states yet.
static id<MTLTexture> Rex_makeGameOverTexture(id<MTLDevice> device, CGSize *outSize) {
    NSUInteger w = 560, h = 220;
    NSUInteger bpr = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * h];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bpr, cs, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    CGContextSetRGBFillColor(ctx, 0.0, 0.0, 0.0, 0.78);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetRGBStrokeColor(ctx, 0.90, 0.20, 0.16, 0.9);
    CGContextSetLineWidth(ctx, 3.0);
    CGContextStrokeRect(ctx, CGRectMake(1.5, 1.5, w - 3, h - 3));

    CGColorRef red = CGColorCreateGenericRGB(0.94, 0.24, 0.20, 1);
    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    Rex_drawCenteredLine(ctx, @"GAME OVER", w * 0.5, h * 0.60, w - 48.f, 64.f, 32.f, red);
    Rex_drawCenteredLine(ctx, @"PRESS FIRE TO CONTINUE", w * 0.5, h * 0.28, w - 48.f, 30.f, 16.f, white);
    CGColorRelease(red);
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

// Compact "PRESS FIRE" label for a sitting-out player's HUD row — same
// technique as Rex_makeGameOverTexture, sized to fit inside a health-bar-sized
// slot instead of a full-screen panel. Content never changes, so callers
// should cache the result rather than rebuilding it per frame.
static id<MTLTexture> Rex_makePressFireTexture(id<MTLDevice> device, CGSize *outSize) {
    NSUInteger w = 240, h = 26;
    NSUInteger bpr = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * h];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bpr, cs, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    CGColorRef white = CGColorCreateGenericRGB(0.92, 0.94, 0.96, 1);
    Rex_drawCenteredLine(ctx, @"PRESS FIRE", w * 0.5, h * 0.28, w - 12.f, 18.f, 10.f, white);
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

#if TARGET_OS_OSX
static void Rex_drawLeftLine(CGContextRef ctx, NSString *text, CGFloat x, CGFloat baselineY,
                             CGFloat fontSize, CGColorRef color) {
    CTFontRef font = CTFontCreateWithName(CFSTR("HelveticaNeue-Bold"), fontSize, NULL);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)color,
    };
    CFAttributedStringRef attr = CFAttributedStringCreate(kCFAllocatorDefault, (__bridge CFStringRef)text,
                                                           (__bridge CFDictionaryRef)attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attr);
    CGContextSetTextPosition(ctx, x, baselineY);
    CTLineDraw(line, ctx);
    CFRelease(line);
    CFRelease(attr);
    CFRelease(font);
}

// One label per debug tuning bar (see _drawDebugHUD), left-aligned and
// colored to match its bar so the association is obvious without counting
// rows. Row height matches the bars' own 15px spacing exactly (8 rows *
// 15px), so this renders at native size right next to them with no
// scaling. Built once and cached — the labels/keys never change, only the
// bar widths do.
static id<MTLTexture> Rex_makeDebugLabelsTexture(id<MTLDevice> device,
                                                 NSArray<NSString*> *labels,
                                                 const simd_float4 *colors,
                                                 CGSize *outSize) {
    NSUInteger w = 170;
    CGFloat rowHeight = 15.f;
    NSUInteger h = (NSUInteger)(rowHeight * (CGFloat)labels.count);
    NSUInteger bpr = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * h];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bpr, cs, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    for (NSUInteger i = 0; i < labels.count; ++i) {
        simd_float4 c = colors[i];
        CGColorRef color = CGColorCreateGenericRGB(c.x, c.y, c.z, 1);
        CGFloat baselineY = (CGFloat)h - rowHeight * ((CGFloat)i + 1.f) + 4.f;
        Rex_drawLeftLine(ctx, labels[i], 4.f, baselineY, 7.f, color);
        CGColorRelease(color);
    }
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
#endif

// Arcade-style corner score readout (Jurassic Park arcade reference: big
// glowing score number, "STREAK X#" underneath, in the player's own color).
// Bigger canvas than the old single-line strip since this is now a
// prominent corner element, not a slim row under the health bar.
static id<MTLTexture> Rex_makeScoreTexture(id<MTLDevice> device, NSString *scoreLine,
                                           NSString *streakLine, simd_float4 tint,
                                           CGSize *outSize) {
    NSUInteger w = (NSUInteger)kScoreTexW, h = (NSUInteger)kScoreTexH;
    NSUInteger bpr = w * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bpr * h];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big;
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, bpr, cs, bitmapInfo);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }

    CGContextSetRGBFillColor(ctx, 0.02, 0.02, 0.025, 0.55);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGColorRef scoreColor = CGColorCreateGenericRGB(tint.x, tint.y, tint.z, 1);
    CGColorRef streakColor = CGColorCreateGenericRGB(0.90, 0.92, 0.95, 1);
    Rex_drawCenteredLine(ctx, scoreLine, w * 0.5, h * 0.74, w - 20.f, 30.f, 16.f, scoreColor);
    Rex_drawCenteredLine(ctx, streakLine, w * 0.5, h * 0.10, w - 20.f, 16.f, 10.f, streakColor);
    CGColorRelease(scoreColor);
    CGColorRelease(streakColor);
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

- (void)_drawReticles:(World *)world encoder:(id<MTLRenderCommandEncoder>)encoder {
    // Frame dt for the tracer animation (cosmetic only, so wall-clock is fine).
    CFTimeInterval now = CACurrentMediaTime();
    float frameDt = (_lastOverlayTime > 0.0) ? (float)(now - _lastOverlayTime) : (1.f / 60.f);
    frameDt = std::min(frameDt, 0.05f);
    _lastOverlayTime = now;

    for (int i = 0; i < kRexMaxPlayers; ++i) {
        const ReticleComponent& reticle = world->reticle(i);
        if (!reticle.active) continue;
        // Premise 8: a depleted player's reticle is hidden while they're
        // sitting out (cabinet norm), not just unresponsive to input.
        if (world->player_health(i).sittingOut) continue;

        simd_float3 c = [self _screenPointX:reticle.x y:reticle.y z:0.05f];
        float gap = 5.f;
        float len = 22.f;
        std::vector<RexVertex> lines;
        lines.push_back({{c.x - len, c.y, c.z}});
        lines.push_back({{c.x - gap, c.y, c.z}});
        lines.push_back({{c.x + gap, c.y, c.z}});
        lines.push_back({{c.x + len, c.y, c.z}});
        lines.push_back({{c.x, c.y - len, c.z}});
        lines.push_back({{c.x, c.y - gap, c.z}});
        lines.push_back({{c.x, c.y + gap, c.z}});
        lines.push_back({{c.x, c.y + len, c.z}});

        simd_float4 color = kReticleColors[i];

        // Laser pointer: a thin beam from this player's gun muzzle (bottom
        // edge of the screen) to their reticle, arcade-style. Drawn first so
        // the crosshair renders on top of it.
        simd_float3 muzzle = [self _screenPointX:kGunAnchorX[i] y:0.02f z:0.04f];
        {
            std::vector<RexVertex> beam;
            appendSegmentQuad(beam, muzzle.x, muzzle.y, c.x, c.y, 1.5f, 0.04f);
            simd_float4 beamColor = {color.x, color.y, color.z, 0.30f};
            [self _drawVertices:beam color:beamColor
                      primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
        }

        // New shots since last frame -> spawn tracers along the beam path.
        uint32_t shots = reticle.shotCount;
        if (shots != _lastShotCount[i]) {
            uint32_t newShots = shots - _lastShotCount[i];
            _lastShotCount[i] = shots;
            for (uint32_t s = 0; s < newShots && s < 3; ++s) {
                _tracers.push_back({muzzle.x, muzzle.y, c.x, c.y, 0.f, i});
            }
        }

        [self _drawVertices:lines color:color primitive:MTLPrimitiveTypeLine mvp:_overlayProjection encoder:encoder];

        // Steady ring around the crosshair (the arcade reference sight is a
        // circle with a cross inside it), in the same per-player color.
        {
            const float radius = 30.f;
            const int kSegments = 28;
            std::vector<RexVertex> ring;
            for (int s = 0; s < kSegments; ++s) {
                float a0 = (float)s / kSegments * 2.f * (float)M_PI;
                float a1 = (float)(s + 1) / kSegments * 2.f * (float)M_PI;
                ring.push_back({{c.x + cosf(a0) * radius, c.y + sinf(a0) * radius, c.z}});
                ring.push_back({{c.x + cosf(a1) * radius, c.y + sinf(a1) * radius, c.z}});
            }
            [self _drawVertices:ring color:color primitive:MTLPrimitiveTypeLine mvp:_overlayProjection encoder:encoder];
        }

        // Fire flash: a ring that expands and fades over kFireFlashDuration.
        // Previously firing had zero visual feedback at the moment of the
        // shot itself — only a successful hit changed anything on screen.
        if (reticle.fireFlashTime > 0.f) {
            float t = 1.f - (reticle.fireFlashTime / kFireFlashDuration); // 0 -> 1
            float radius = 10.f + t * 26.f;
            float alpha = 1.f - t;
            const int kSegments = 12;
            std::vector<RexVertex> ring;
            for (int s = 0; s < kSegments; ++s) {
                float a0 = (float)s / kSegments * 2.f * (float)M_PI;
                float a1 = (float)(s + 1) / kSegments * 2.f * (float)M_PI;
                ring.push_back({{c.x + cosf(a0) * radius, c.y + sinf(a0) * radius, c.z}});
                ring.push_back({{c.x + cosf(a1) * radius, c.y + sinf(a1) * radius, c.z}});
            }
            simd_float4 flashColor = {1.f, 0.92f, 0.55f, alpha};
            [self _drawVertices:ring color:flashColor primitive:MTLPrimitiveTypeLine mvp:_overlayProjection encoder:encoder];
        }
    }

    // Advance + draw shot tracers: a bright round streaking from the muzzle
    // to where the reticle was when the trigger was pulled — red glow with a
    // white-hot core, plus a brief muzzle flash at the gun end.
    constexpr float kTracerDuration = 0.11f;
    std::vector<RexVertex> glow;
    std::vector<RexVertex> core;
    std::vector<RexVertex> flash;
    for (auto& tracer : _tracers) {
        tracer.age += frameDt;
        float t = tracer.age / kTracerDuration;
        if (t > 1.f) continue;
        float headT = t;
        float tailT = std::max(0.f, t - 0.30f);
        float hx = tracer.startX + (tracer.endX - tracer.startX) * headT;
        float hy = tracer.startY + (tracer.endY - tracer.startY) * headT;
        float tx = tracer.startX + (tracer.endX - tracer.startX) * tailT;
        float ty = tracer.startY + (tracer.endY - tracer.startY) * tailT;
        appendSegmentQuad(glow, tx, ty, hx, hy, 4.5f, 0.045f);
        appendSegmentQuad(core, tx, ty, hx, hy, 1.5f, 0.05f);

        if (tracer.age < 0.045f) {
            // Muzzle flash: a small X burst at the gun end of the beam.
            float r = 10.f;
            appendSegmentQuad(flash, tracer.startX - r, tracer.startY - r,
                              tracer.startX + r, tracer.startY + r, 2.5f, 0.05f);
            appendSegmentQuad(flash, tracer.startX - r, tracer.startY + r,
                              tracer.startX + r, tracer.startY - r, 2.5f, 0.05f);
        }
    }
    _tracers.erase(std::remove_if(_tracers.begin(), _tracers.end(),
                                  [](const ShotTracer& tracer) {
                                      return tracer.age >= kTracerDuration;
                                  }),
                   _tracers.end());
    if (!glow.empty()) {
        [self _drawVertices:glow color:(simd_float4){1.f, 0.28f, 0.20f, 0.55f}
                  primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
        [self _drawVertices:core color:(simd_float4){1.f, 0.98f, 0.92f, 0.95f}
                  primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
    }
    if (!flash.empty()) {
        [self _drawVertices:flash color:(simd_float4){1.f, 0.85f, 0.45f, 0.9f}
                  primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
    }
}

// Per-player health bar (bottom corner — see _drawHUD's layout math), a
// full-screen hit-flash tint, and — while PlayerHealthState::gameOver is
// set — the GAME OVER / continue panel. Always drawn (not gated to macOS
// like the tuning debug HUD): this is real gameplay feedback, not a
// dev-only overlay.
// Draws one player's health row (a bordered bar, colored fill by health
// fraction, tinted with that player's reticle color) centered at (centerX,
// barY) in overlay-pixel space.
- (void)_drawHealthBarForPlayer:(int)playerIndex
                         health:(const PlayerHealthState &)health
                        centerX:(float)centerX
                           barY:(float)barY
                      barWidth:(float)barWidth
                     barHeight:(float)barHeight
                        encoder:(id<MTLRenderCommandEncoder>)encoder {
    simd_float4 playerColor = kReticleColors[playerIndex];
    float fraction = health.maxHealth > 0
                    ? std::clamp((float)health.health / (float)health.maxHealth, 0.f, 1.f)
                    : 0.f;

    std::vector<RexVertex> bg;
    [self _appendQuad:bg center:(simd_float3){centerX, barY, 0.05f}
                halfW:barWidth * 0.5f + 3.f halfH:barHeight * 0.5f + 3.f];
    [self _drawVertices:bg color:(simd_float4){0.05f, 0.05f, 0.06f, 0.85f}
              primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];

    if (fraction > 0.f) {
        simd_float4 fillColor = fraction > 0.5f
                               ? (simd_float4){0.30f, 0.85f, 0.35f, 1.f}
                               : (fraction > 0.25f ? (simd_float4){0.95f, 0.75f, 0.20f, 1.f}
                                                    : (simd_float4){0.90f, 0.25f, 0.20f, 1.f});
        float fillWidth = barWidth * fraction;
        std::vector<RexVertex> fill;
        [self _appendQuad:fill center:(simd_float3){centerX - barWidth * 0.5f + fillWidth * 0.5f, barY, 0.06f}
                    halfW:fillWidth * 0.5f halfH:barHeight * 0.5f];
        [self _drawVertices:fill color:fillColor primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
    }

    // Player-color tick to the left of the bar, same purpose as the reticle
    // color: at-a-glance "this row is yours."
    std::vector<RexVertex> tick;
    [self _appendQuad:tick center:(simd_float3){centerX - barWidth * 0.5f - 12.f, barY, 0.06f} halfW:4.f halfH:barHeight * 0.5f];
    [self _drawVertices:tick color:playerColor primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
}

// Corner-anchored score readout (see Rex_makeScoreTexture) — centerX/centerY
// is the texture's own center, so callers place it flush into a screen
// corner by offsetting from _halfW/_halfH by half the texture size + margin.
// Accuracy dropped from the persistent HUD to match the arcade reference
// (score + streak only); ScoringSystem still tracks it, this is a rendering
// choice only.
- (void)_drawScoreForPlayer:(int)playerIndex
                      score:(const PlayerScoreState &)score
                    centerX:(float)centerX
                    centerY:(float)centerY
                    encoder:(id<MTLRenderCommandEncoder>)encoder {
    static NSNumberFormatter *sGroupingFormatter;
    if (!sGroupingFormatter) {
        sGroupingFormatter = [[NSNumberFormatter alloc] init];
        sGroupingFormatter.numberStyle = NSNumberFormatterDecimalStyle;
        sGroupingFormatter.usesGroupingSeparator = YES;
    }
    NSString *scoreLine = [NSString stringWithFormat:@"P%d  %@", playerIndex + 1,
                                    [sGroupingFormatter stringFromNumber:@(score.score)]];
    NSString *streakLine = [NSString stringWithFormat:@"STREAK X%d", score.currentStreak];
    NSString *text = [scoreLine stringByAppendingFormat:@"|%@", streakLine];
    if (!_scoreText[playerIndex] || ![_scoreText[playerIndex] isEqualToString:text]) {
        _scoreText[playerIndex] = [text copy];
        _scoreTextures[playerIndex] = Rex_makeScoreTexture(_device, scoreLine, streakLine,
                                                           kReticleColors[playerIndex],
                                                           &_scoreTextureSizes[playerIndex]);
    }
    if (_scoreTextures[playerIndex] && _texturePipeline) {
        RexTextureUniformsCPU uniforms;
        uniforms.mvp = Rex_make_model_rect(_overlayProjection, centerX, centerY, 0.07f,
                                           (float)_scoreTextureSizes[playerIndex].width,
                                           (float)_scoreTextureSizes[playerIndex].height);
        [encoder setRenderPipelineState:_texturePipeline];
        [encoder setVertexBuffer:_texQuadVB offset:0 atIndex:0];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder setFragmentTexture:_scoreTextures[playerIndex] atIndex:0];
        [encoder setFragmentSamplerState:_sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [encoder setRenderPipelineState:_pipeline];
    }
}

// Draws a sitting-out player's row: a dim empty bar plus a small cached
// "PRESS FIRE" label, still tinted with their reticle color's tick so it's
// clear which player needs to continue.
- (void)_drawSittingOutRowForPlayer:(int)playerIndex
                             centerX:(float)centerX
                                barY:(float)barY
                            barWidth:(float)barWidth
                           barHeight:(float)barHeight
                             encoder:(id<MTLRenderCommandEncoder>)encoder {
    simd_float4 playerColor = kReticleColors[playerIndex];

    std::vector<RexVertex> bg;
    [self _appendQuad:bg center:(simd_float3){centerX, barY, 0.05f}
                halfW:barWidth * 0.5f + 3.f halfH:barHeight * 0.5f + 3.f];
    [self _drawVertices:bg color:(simd_float4){0.05f, 0.05f, 0.06f, 0.55f}
              primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];

    std::vector<RexVertex> tick;
    [self _appendQuad:tick center:(simd_float3){centerX - barWidth * 0.5f - 12.f, barY, 0.06f} halfW:4.f halfH:barHeight * 0.5f];
    [self _drawVertices:tick color:(simd_float4){playerColor.x, playerColor.y, playerColor.z, 0.5f}
              primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];

    if (!_pressFireTexture) {
        _pressFireTexture = Rex_makePressFireTexture(_device, &_pressFireTextureSize);
    }
    if (_pressFireTexture && _texturePipeline) {
        RexTextureUniformsCPU uniforms;
        uniforms.mvp = Rex_make_model_rect(_overlayProjection, centerX, barY, 0.07f,
                                           (float)_pressFireTextureSize.width,
                                           (float)_pressFireTextureSize.height);
        [encoder setRenderPipelineState:_texturePipeline];
        [encoder setVertexBuffer:_texQuadVB offset:0 atIndex:0];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder setFragmentTexture:_pressFireTexture atIndex:0];
        [encoder setFragmentSamplerState:_sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [encoder setRenderPipelineState:_pipeline];
    }
}

// One health row per active player (Premise 6/8: per-player health, cabinet-
// style sit-out), a full-screen hit-flash tint if any active player was just
// hit, and — only once every active player is simultaneously sitting out —
// the shared GAME OVER / continue panel.
- (void)_drawHUD:(World *)world encoder:(id<MTLRenderCommandEncoder>)encoder {
    int activePlayers[kRexMaxPlayers];
    int activeCount = 0;
    for (int i = 0; i < kRexMaxPlayers; ++i) {
        if (world->reticle(i).active) activePlayers[activeCount++] = i;
    }

    // Jurassic-Park-arcade-style corners: even player index owns the left
    // side, odd owns the right — score up top, health down at the bottom,
    // per the reference layout (P1 left, P2 right). A 3rd/4th player, if
    // that ever ships, stacks further in on whichever side its index lands
    // on rather than sharing a row with player 0/1.
    float margin = 26.f;
    float barWidth = 260.f;
    float barHeight = 20.f;
    float rowGap = 30.f;

    float maxHitFlash = 0.f;
    for (int slot = 0; slot < activeCount; ++slot) {
        int player = activePlayers[slot];
        const PlayerHealthState& health = world->player_health(player);
        bool leftSide = (player % 2) == 0;
        int stackIndex = player / 2; // 0 = outermost row on that side

        float scoreCenterX = leftSide ? (-_halfW + margin + kScoreTexW * 0.5f)
                                       : ( _halfW - margin - kScoreTexW * 0.5f);
        float scoreCenterY = _halfH - margin - kScoreTexH * 0.5f
                            - (float)stackIndex * (kScoreTexH + rowGap);

        float healthCenterX = leftSide ? (-_halfW + margin + barWidth * 0.5f)
                                        : ( _halfW - margin - barWidth * 0.5f);
        float healthCenterY = -_halfH + margin + barHeight * 0.5f
                             + (float)stackIndex * (barHeight + rowGap);

        if (health.sittingOut) {
            [self _drawSittingOutRowForPlayer:player centerX:healthCenterX barY:healthCenterY
                                      barWidth:barWidth barHeight:barHeight encoder:encoder];
        } else {
            [self _drawHealthBarForPlayer:player health:health centerX:healthCenterX barY:healthCenterY
                                   barWidth:barWidth barHeight:barHeight encoder:encoder];
        }
        [self _drawScoreForPlayer:player score:world->score(player)
                          centerX:scoreCenterX centerY:scoreCenterY encoder:encoder];
        maxHitFlash = std::max(maxHitFlash, health.hitFlashTime);
    }

    if (maxHitFlash > 0.f) {
        float alpha = std::clamp(maxHitFlash / 0.35f, 0.f, 1.f) * 0.35f;
        std::vector<RexVertex> vignette;
        [self _appendQuad:vignette center:(simd_float3){0.f, 0.f, 0.02f} halfW:_halfW halfH:_halfH];
        [self _drawVertices:vignette color:(simd_float4){0.85f, 0.05f, 0.05f, alpha}
                  primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
    }

    bool allSittingOut = !world->any_player_active_and_not_sitting_out();
    if (allSittingOut && activeCount > 0) {
        if (!_gameOverTexture) {
            _gameOverTexture = Rex_makeGameOverTexture(_device, &_gameOverTextureSize);
        }
        std::vector<RexVertex> backdrop;
        [self _appendQuad:backdrop center:(simd_float3){0.f, 0.f, 0.08f} halfW:_halfW halfH:_halfH];
        [self _drawVertices:backdrop color:(simd_float4){0.f, 0.f, 0.f, 0.35f}
                  primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];

        if (_gameOverTexture && _texturePipeline) {
            RexTextureUniformsCPU uniforms;
            uniforms.mvp = Rex_make_model_rect(_overlayProjection, 0.f, 0.f, 0.09f,
                                               (float)_gameOverTextureSize.width,
                                               (float)_gameOverTextureSize.height);
            [encoder setRenderPipelineState:_texturePipeline];
            [encoder setVertexBuffer:_texQuadVB offset:0 atIndex:0];
            [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
            [encoder setFragmentTexture:_gameOverTexture atIndex:0];
            [encoder setFragmentSamplerState:_sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [encoder setRenderPipelineState:_pipeline];
        }
    }
}

#if TARGET_OS_OSX
- (void)_drawDebugHUD:(id<MTLRenderCommandEncoder>)encoder {
    if (!_debugHUDVisible) return;
    ReticleTuning tuning = ReticleSystem_tuning();
    const float values[] = {
        tuning.stickSensitivityH / 2.0f,
        tuning.stickSensitivityV / 2.0f,
        tuning.gyroSensitivityH / 1.4f,
        tuning.gyroSensitivityV / 1.4f,
        tuning.stillnessSmoothingAlpha,
        tuning.fallbackFrictionScale,
        tuning.fallbackMagnetStrength,
        tuning.fallbackMagnetRadius / 0.3f,
    };
    const simd_float4 colors[] = {
        {0.25f, 0.62f, 1.0f, 1.f},
        {0.25f, 0.62f, 1.0f, 1.f},
        {0.20f, 0.92f, 0.68f, 1.f},
        {0.20f, 0.92f, 0.68f, 1.f},
        {0.92f, 0.82f, 0.25f, 1.f},
        {0.93f, 0.52f, 0.24f, 1.f},
        {0.84f, 0.42f, 0.95f, 1.f},
        {0.84f, 0.42f, 0.95f, 1.f},
    };
    // Starts below the P1 corner score readout (see kScoreTexH) rather than
    // under _halfH directly — the two used to collide once the score box
    // grew from a slim top-center strip to the taller arcade-style corner
    // panel.
    for (int i = 0; i < 8; ++i) {
        float baseX = -_halfW + 34.f;
        float baseY = _halfH - 26.f - kScoreTexH - 24.f - (float)i * 15.f;
        float width = 120.f * std::min(1.f, std::max(0.f, values[i]));
        std::vector<RexVertex> bg;
        [self _appendQuad:bg center:(simd_float3){baseX + 60.f, baseY, 0.06f} halfW:60.f halfH:4.f];
        [self _drawVertices:bg color:(simd_float4){0.08f, 0.09f, 0.10f, 0.9f}
                  primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];

        std::vector<RexVertex> bar;
        [self _appendQuad:bar center:(simd_float3){baseX + width * 0.5f, baseY, 0.07f}
                    halfW:width * 0.5f halfH:4.f];
        [self _drawVertices:bar color:colors[i] primitive:MTLPrimitiveTypeTriangle mvp:_overlayProjection encoder:encoder];
    }

    if (!_debugLabelsTexture) {
        NSArray<NSString*> *labels = @[
            @"STICK H  =/-", @"STICK V  =/-",
            @"GYRO H  ]/[",  @"GYRO V  ]/[",
            @"SMOOTH  '/;",  @"FRICTION  P/O",
            @"MAGNET STR  M/N", @"MAGNET RAD  ./,",
        ];
        _debugLabelsTexture = Rex_makeDebugLabelsTexture(_device, labels, colors, &_debugLabelsTextureSize);
    }
    if (_debugLabelsTexture && _texturePipeline) {
        float labelsX = -_halfW + 34.f + 120.f + 10.f + (float)_debugLabelsTextureSize.width * 0.5f;
        float topBaseY = _halfH - 26.f - kScoreTexH - 24.f;
        float labelsY = topBaseY - (float)_debugLabelsTextureSize.height * 0.5f + 7.5f;
        RexTextureUniformsCPU uniforms;
        uniforms.mvp = Rex_make_model_rect(_overlayProjection, labelsX, labelsY, 0.07f,
                                           (float)_debugLabelsTextureSize.width,
                                           (float)_debugLabelsTextureSize.height);
        [encoder setRenderPipelineState:_texturePipeline];
        [encoder setVertexBuffer:_texQuadVB offset:0 atIndex:0];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
        [encoder setFragmentTexture:_debugLabelsTexture atIndex:0];
        [encoder setFragmentSamplerState:_sampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [encoder setRenderPipelineState:_pipeline];
    }
}
#endif

- (void)drawWorld:(World*)world
           inView:(MTKView*)view
    commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass || !view.currentDrawable) return;
    if (world) world->rail_camera().aspect = _aspect;

    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.36, 0.39, 0.42, 1.0);
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setDepthStencilState:_depthState];
    [encoder setVertexBuffer:_groundVB offset:0 atIndex:0];
    RexUniforms uniforms;
    simd_float4x4 worldMVP = world ? [self _worldViewProjection:world->rail_camera()]
                                   : Rex_make_perspective(1.04719758f, _aspect, 0.1f, 120.f);
    uniforms.mvp = worldMVP;
    uniforms.color = (simd_float4){0.48f, 0.49f, 0.48f, 1.f};
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    if (world) {
        [self _drawM1Targets:world mvp:worldMVP encoder:encoder];
        [self _drawDinos:world mvp:worldMVP encoder:encoder];
    }

    [encoder setDepthStencilState:_overlayDepthState];
    if (world) {
        [self _drawReticles:world encoder:encoder];
        [self _drawHUD:world encoder:encoder];
    }
#if TARGET_OS_OSX
    [self _drawDebugHUD:encoder];
#endif
    [encoder endEncoding];

    if (_pendingCapturePath) {
        NSString *path = _pendingCapturePath;
        _pendingCapturePath = nil;

        id<MTLTexture> tex = view.currentDrawable.texture;
        if (tex.framebufferOnly) {
            NSLog(@"RexRenderer: capture skipped — view.framebufferOnly must be NO");
        } else {
            NSUInteger w = tex.width, h = tex.height;
            NSUInteger bpr = ((w * 4 + 255) / 256) * 256; // blit requires 256-byte row alignment
            id<MTLBuffer> staging = [tex.device newBufferWithLength:bpr * h
                                                            options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(w, h, 1)
                         toBuffer:staging destinationOffset:0
            destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
            [blit endEncoding];

            [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _) {
                RexRenderer_writePNG(staging, w, h, bpr, path);
            }];
        }
    }

    [commandBuffer presentDrawable:view.currentDrawable];
}

- (void)captureNextFrameToPath:(NSString*)path {
    _pendingCapturePath = [path copy];
}

- (void)toggleDebugHUD {
    _debugHUDVisible = !_debugHUDVisible;
}

@end
