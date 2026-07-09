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
    LoadedCharacter *_raptor;
    simd_float4x4 _overlayProjection;
    float _halfW;
    float _halfH;
    float _aspect;
    NSString *_pendingCapturePath; // --capture-out=: next frame -> PNG
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat {
    self = [super init];
    if (!self) return nil;

    _device = device;
    const RexVertex verts[] = {
        {{-8.f, kGroundWorldY, 0.f}}, {{ 8.f, kGroundWorldY, 0.f}}, {{-8.f, kGroundWorldY, 80.f}},
        {{ 8.f, kGroundWorldY, 0.f}}, {{ 8.f, kGroundWorldY, 80.f}}, {{-8.f, kGroundWorldY, 80.f}},
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

    // Dev affordance: --dino=trex (etc.) overrides the species, so visual
    // checks can flip between the six converted dinos without a code edit.
    NSString *species = @"velociraptor";
    for (NSString *arg in [NSProcessInfo processInfo].arguments) {
        if ([arg hasPrefix:@"--dino="]) {
            species = [arg substringFromIndex:[@"--dino=" length]];
        }
    }
    NSString *dinoDir = [[NSBundle mainBundle] pathForResource:species
                                                        ofType:nil
                                                   inDirectory:@"assets/characters/dinos"];
    if (dinoDir.length) {
        NSString *basePath = [dinoDir stringByAppendingPathComponent:@"base.usdz"];
        NSMutableArray<NSString*> *clips = [NSMutableArray arrayWithCapacity:(NSUInteger)CharacterClipSlot::Count];
        for (int i = 0; i < (int)CharacterClipSlot::Count; ++i) {
            NSString *name = [NSString stringWithUTF8String:CharacterClipSlot_name((CharacterClipSlot)i)];
            [clips addObject:[dinoDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"usdz"]]];
        }
        @try {
            try {
                _raptor = CharacterLoader_load(basePath, clips, _device);
                AnimationSystem_set_characters(nullptr, _raptor);
            } catch (const std::exception& ex) {
                NSLog(@"RexRenderer: raptor load failed: %s", ex.what());
            }
        } @catch (NSException *exception) {
            NSLog(@"RexRenderer: raptor load failed: %@", exception.reason);
        }
    } else {
        NSLog(@"RexRenderer: velociraptor asset directory missing");
    }

    return self;
}

- (void)dealloc {
    delete _raptor;
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
    if (!_raptor || !_raptor->vertexBuffer || !_raptor->indexBuffer) return;

    [encoder setRenderPipelineState:_skinnedPipeline];
    [encoder setFragmentSamplerState:_sampler atIndex:0];
    [encoder setFragmentTexture:_raptor->diffuseTexture atIndex:0];

    for (EntityID id = 0; id < world->entity_count(); ++id) {
        if (!world->has_component<DinoBehaviorComponent>(id)
            || !world->has_component<AnimationComponent>(id)) {
            continue;
        }
        const DinoBehaviorComponent& dino = world->get_component<DinoBehaviorComponent>(id);
        if (!dino.active || dino.targetIndex >= kM1MaxTargets) continue;
        const TargetComponent& target = world->target(dino.targetIndex);
        if (!target.active) continue;

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
        float meshUpExtent = _raptor->meshZMax - _raptor->meshZMin;
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
            target.worldY - _raptor->meshZMin * scale - target.halfHeight,
            target.worldZ,
            1.f
        };

        SkinnedUniformsCPU uniforms;
        uniforms.mvp = simd_mul(viewProjection, model);
        uniforms.modelRotation = modelRotation;
        uniforms.color = target.wasHit ? (simd_float4){0.96f, 0.78f, 0.24f, 1.f}
                                       : (simd_float4){1.f, 1.f, 1.f, 1.f};
        // Light from the camera's side, raised a bit so top surfaces read
        // brighter than undersides (pure headlight lighting looks flat).
        simd_float3 towardCamera = simd_normalize((simd_float3){
            dx, camera.positionY - target.worldY, dz});
        simd_float3 lightDir = simd_normalize(towardCamera + (simd_float3){0.f, 0.9f, 0.f});
        uniforms.lightDir = (simd_float4){lightDir.x, lightDir.y, lightDir.z, 0.f};
        uniforms.tintStrength = target.wasHit ? 0.25f : 0.f;
        const AnimationComponent& anim = world->get_component<AnimationComponent>(id);

        [encoder setVertexBuffer:_raptor->vertexBuffer offset:0 atIndex:0];
        [encoder setVertexBytes:anim.boneMatrices length:sizeof(anim.boneMatrices) atIndex:1];
        [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:2];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:_raptor->indexCount
                             indexType:_raptor->indexType
                           indexBuffer:_raptor->indexBuffer
                     indexBufferOffset:0];
    }

    [encoder setRenderPipelineState:_pipeline];
}

- (void)_drawReticles:(World *)world encoder:(id<MTLRenderCommandEncoder>)encoder {
    for (int i = 0; i < kRexMaxPlayers; ++i) {
        const ReticleComponent& reticle = world->reticle(i);
        if (!reticle.active) continue;

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

        simd_float4 color = reticle.gyroAvailable
                          ? (simd_float4){0.16f, 0.85f, 0.95f, 1.f}
                          : (simd_float4){0.92f, 0.92f, 0.92f, 1.f};
        [self _drawVertices:lines color:color primitive:MTLPrimitiveTypeLine mvp:_overlayProjection encoder:encoder];

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
}

#if TARGET_OS_OSX
- (void)_drawDebugHUD:(id<MTLRenderCommandEncoder>)encoder {
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
    for (int i = 0; i < 8; ++i) {
        float baseX = -_halfW + 34.f;
        float baseY = _halfH - 32.f - (float)i * 15.f;
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

@end
