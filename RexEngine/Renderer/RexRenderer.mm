#import "RexRenderer.h"
#include "Simulation/World.h"
#include "Simulation/Systems/ReticleSystem.h"
#include <TargetConditionals.h>
#include <algorithm>
#include <vector>
#include <simd/simd.h>

struct RexVertex {
    simd_float3 position;
};

struct RexUniforms {
    simd_float4x4 mvp;
    simd_float4 color;
};

static simd_float4x4 make_ortho(float left, float right, float bottom, float top, float nearZ, float farZ) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = 2.f / (right - left);
    m.columns[1].y = 2.f / (top - bottom);
    m.columns[2].z = 1.f / (farZ - nearZ);
    m.columns[3].x = -(right + left) / (right - left);
    m.columns[3].y = -(top + bottom) / (top - bottom);
    m.columns[3].z = -nearZ / (farZ - nearZ);
    return m;
}

@implementation RexRenderer {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthState;
    id<MTLDepthStencilState> _overlayDepthState;
    id<MTLBuffer> _groundVB;
    simd_float4x4 _projection;
    float _halfW;
    float _halfH;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixelFormat {
    self = [super init];
    if (!self) return nil;

    _device = device;
    const RexVertex verts[] = {
        {{-600.f, -380.f, 0.f}}, {{ 600.f, -380.f, 0.f}}, {{-600.f,  380.f, 0.f}},
        {{ 600.f, -380.f, 0.f}}, {{ 600.f,  380.f, 0.f}}, {{-600.f,  380.f, 0.f}},
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
    _pipeline = [_device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!_pipeline) {
        NSLog(@"RexRenderer: pipeline failed: %@", error);
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

    _projection = make_ortho(-640.f, 640.f, -420.f, 420.f, -1.f, 1.f);
    _halfW = 640.f;
    _halfH = 420.f;

    return self;
}

- (void)updateDrawableSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    float aspect = (float)size.width / (float)size.height;
    float halfH = 420.f;
    float halfW = halfH * aspect;
    _projection = make_ortho(-halfW, halfW, -halfH, halfH, -1.f, 1.f);
    _halfW = halfW;
    _halfH = halfH;
}

- (simd_float3)_screenPointX:(float)x y:(float)y z:(float)z {
    return (simd_float3){(x - 0.5f) * _halfW * 2.f, (y - 0.5f) * _halfH * 2.f, z};
}

- (void)_drawVertices:(const std::vector<RexVertex>&)vertices
                color:(simd_float4)color
             primitive:(MTLPrimitiveType)primitive
              encoder:(id<MTLRenderCommandEncoder>)encoder {
    if (vertices.empty()) return;
    RexUniforms uniforms;
    uniforms.mvp = _projection;
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

- (void)_drawM1Targets:(World *)world encoder:(id<MTLRenderCommandEncoder>)encoder {
    std::vector<RexVertex> active;
    std::vector<RexVertex> hit;
    for (int i = 0; i < kM1MaxTargets; ++i) {
        const TargetComponent& target = world->target(i);
        if (!target.active) continue;
        simd_float3 center = [self _screenPointX:target.screenX y:target.screenY z:0.02f];
        float w = target.screenHalfW * _halfW * 2.f;
        float h = target.screenHalfH * _halfH * 2.f;
        [self _appendQuad:(target.wasHit ? hit : active) center:center halfW:w halfH:h];
    }
    [self _drawVertices:active color:(simd_float4){0.82f, 0.27f, 0.18f, 1.f}
              primitive:MTLPrimitiveTypeTriangle encoder:encoder];
    [self _drawVertices:hit color:(simd_float4){0.96f, 0.78f, 0.24f, 1.f}
              primitive:MTLPrimitiveTypeTriangle encoder:encoder];
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
        [self _drawVertices:lines color:color primitive:MTLPrimitiveTypeLine encoder:encoder];
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
                  primitive:MTLPrimitiveTypeTriangle encoder:encoder];

        std::vector<RexVertex> bar;
        [self _appendQuad:bar center:(simd_float3){baseX + width * 0.5f, baseY, 0.07f}
                    halfW:width * 0.5f halfH:4.f];
        [self _drawVertices:bar color:colors[i] primitive:MTLPrimitiveTypeTriangle encoder:encoder];
    }
}
#endif

- (void)drawWorld:(World*)world
           inView:(MTKView*)view
    commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    (void)world;
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    if (!pass || !view.currentDrawable) return;

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
    uniforms.mvp = _projection;
    uniforms.color = (simd_float4){0.48f, 0.49f, 0.48f, 1.f};
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

    [encoder setDepthStencilState:_overlayDepthState];
    if (world) {
        [self _drawM1Targets:world encoder:encoder];
        [self _drawReticles:world encoder:encoder];
    }
#if TARGET_OS_OSX
    [self _drawDebugHUD:encoder];
#endif
    [encoder endEncoding];

    [commandBuffer presentDrawable:view.currentDrawable];
}

@end
