#import "RexRenderer.h"
#include "Simulation/World.h"
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
    id<MTLBuffer> _groundVB;
    simd_float4x4 _projection;
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
    _projection = make_ortho(-640.f, 640.f, -420.f, 420.f, -1.f, 1.f);

    return self;
}

- (void)updateDrawableSize:(CGSize)size {
    if (size.width <= 0 || size.height <= 0) return;
    float aspect = (float)size.width / (float)size.height;
    float halfH = 420.f;
    float halfW = halfH * aspect;
    _projection = make_ortho(-halfW, halfW, -halfH, halfH, -1.f, 1.f);
}

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
    [encoder endEncoding];

    [commandBuffer presentDrawable:view.currentDrawable];
}

@end
