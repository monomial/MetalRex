#pragma once
#import <Metal/Metal.h>
#include "Simulation/Components.h"
#include <vector>

static constexpr int kBakedFPS = 30;

// Baked clip: bone matrices at every 1/30s frame.
// Layout: matrices[(frameIdx * jointCount + jointIdx) * 16] — column-major float4x4.
struct BakedClip {
    int frameCount  = 0;
    int jointCount  = 0;
    std::vector<float> matrices;

    float duration() const { return frameCount > 0 ? (float)frameCount / kBakedFPS : 0.f; }

    // Writes up to kMaxBones float4x4 matrices into dst, linearly interpolated.
    // Joints beyond jointCount receive identity.
    void sample(float clipTime, float dst[kMaxBones][16]) const;
};

struct LoadedCharacter {
    id<MTLBuffer>  vertexBuffer; // interleaved: pos(3) nrm(3) uv(2) ji(4×ushort) jw(4) — 56 B/vtx
    id<MTLBuffer>  indexBuffer;
    id<MTLTexture> diffuseTexture; // nil if not available
    NSUInteger     indexCount;
    MTLIndexType   indexType;
    int            jointCount;
    float          meshHeight; // bounding-box Y extent in model units (used for auto-scale)
    float          meshYMin;   // lowest Y vertex (for ground alignment)

    BakedClip clips[(int)AnimClipID::Count];
    bool      clipLoaded[(int)AnimClipID::Count];

    LoadedCharacter()
        : vertexBuffer(nil), indexBuffer(nil), diffuseTexture(nil),
          indexCount(0), indexType(MTLIndexTypeUInt32), jointCount(0),
          meshHeight(0.f), meshYMin(0.f) {
        memset(clipLoaded, 0, sizeof(clipLoaded));
    }
};

// Loads the base mesh (With Skin FBX) and bakes each animation clip (Without Skin FBX).
// clipPaths: NSArray indexed by (int)AnimClipID; nil entries are skipped.
// Returns heap-allocated LoadedCharacter, or nullptr if mesh fails to load.
LoadedCharacter* CharacterLoader_load(NSString* meshPath,
                                      NSArray<NSString*>* clipPaths,
                                      id<MTLDevice> device);
