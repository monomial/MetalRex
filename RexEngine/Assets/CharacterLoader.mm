#import "CharacterLoader.h"
#import <ModelIO/ModelIO.h>
#import <MetalKit/MetalKit.h>
#include <simd/simd.h>
#include <algorithm>
#include <cfloat>
#include <cstring>

static MDLVertexDescriptor* makeSkinnedMDLVD() {
    MDLVertexDescriptor *vd = [[MDLVertexDescriptor alloc] init];
    vd.attributes[0] = [[MDLVertexAttribute alloc]
        initWithName:MDLVertexAttributePosition
              format:MDLVertexFormatFloat3 offset:0 bufferIndex:0];
    vd.attributes[1] = [[MDLVertexAttribute alloc]
        initWithName:MDLVertexAttributeNormal
              format:MDLVertexFormatFloat3 offset:12 bufferIndex:0];
    vd.attributes[2] = [[MDLVertexAttribute alloc]
        initWithName:MDLVertexAttributeTextureCoordinate
              format:MDLVertexFormatFloat2 offset:24 bufferIndex:0];
    vd.attributes[3] = [[MDLVertexAttribute alloc]
        initWithName:MDLVertexAttributeColor
              format:MDLVertexFormatFloat4 offset:32 bufferIndex:0];
    vd.attributes[4] = [[MDLVertexAttribute alloc]
        initWithName:MDLVertexAttributeJointIndices
              format:MDLVertexFormatUShort4 offset:48 bufferIndex:0];
    vd.attributes[5] = [[MDLVertexAttribute alloc]
        initWithName:MDLVertexAttributeJointWeights
              format:MDLVertexFormatFloat4 offset:56 bufferIndex:0];
    vd.layouts[0].stride = 72;
    return vd;
}

const char* CharacterClipSlot_name(CharacterClipSlot slot) {
    switch (slot) {
        case CharacterClipSlot::Idle:   return "idle";
        case CharacterClipSlot::Walk:   return "walk";
        case CharacterClipSlot::Run:    return "run";
        case CharacterClipSlot::Attack: return "attack";
        case CharacterClipSlot::Jump:   return "jump";
        case CharacterClipSlot::Death:  return "death";
        case CharacterClipSlot::Count:  return "count";
    }
    return "unknown";
}

CharacterClipSlot CharacterClipSlot_from_name(NSString* name) {
    NSString *lower = [name lowercaseString];
    for (int i = 0; i < (int)CharacterClipSlot::Count; ++i) {
        CharacterClipSlot slot = (CharacterClipSlot)i;
        if ([lower isEqualToString:[NSString stringWithUTF8String:CharacterClipSlot_name(slot)]]) {
            return slot;
        }
    }
    @throw [NSException exceptionWithName:@"CharacterClipSlotValidation"
                                   reason:[NSString stringWithFormat:@"unknown clip slot %@", name]
                                 userInfo:nil];
}

void CharacterClipTable_validate_required(const bool loaded[(int)CharacterClipSlot::Count],
                                          NSString* speciesName) {
    for (int i = 0; i < (int)CharacterClipSlot::Count; ++i) {
        if (!loaded[i]) {
            NSString *reason = [NSString stringWithFormat:
                @"CharacterLoader: %@ missing required %@ clip",
                speciesName.length ? speciesName : @"species",
                [NSString stringWithUTF8String:CharacterClipSlot_name((CharacterClipSlot)i)]];
            throw std::runtime_error([reason UTF8String]);
        }
    }
}

static void walkAsset(MDLAsset *asset, void(^block)(MDLObject*)) {
    NSMutableArray<MDLObject*> *stack = [NSMutableArray array];
    for (MDLObject *top in asset) [stack addObject:top];
    while (stack.count) {
        MDLObject *o = stack.lastObject;
        [stack removeLastObject];
        block(o);
        for (MDLObject *c in o.children.objects) [stack addObject:c];
    }
}

static MDLSkeleton* findSkeleton(MDLAsset *asset) {
    __block MDLSkeleton *found = nil;
    walkAsset(asset, ^(MDLObject *o) {
        if (!found && [o isKindOfClass:[MDLSkeleton class]]) found = (MDLSkeleton*)o;
    });
    return found;
}

static MDLPackedJointAnimation* findAnim(MDLAsset *asset) {
    __block MDLPackedJointAnimation *found = nil;
    walkAsset(asset, ^(MDLObject *o) {
        if (found) return;
        // MDLAnimationBindComponent is a class conforming to MDLComponent
        id comp = [o componentConformingToProtocol:@protocol(MDLComponent)];
        if ([comp isKindOfClass:[MDLAnimationBindComponent class]]) {
            id ja = ((MDLAnimationBindComponent*)comp).jointAnimation;
            if ([ja isKindOfClass:[MDLPackedJointAnimation class]]) { found = ja; return; }
        }
        // Also check if the object itself is a PackedJointAnimation
        if ([o isKindOfClass:[MDLPackedJointAnimation class]])
            found = (MDLPackedJointAnimation*)o;
    });
    return found;
}

static bool assetHasVertexColor(NSURL *meshURL) {
    MDLAsset *asset = [[MDLAsset alloc] initWithURL:meshURL];
    __block bool found = false;
    walkAsset(asset, ^(MDLObject *o) {
        if (found || ![o isKindOfClass:[MDLMesh class]]) return;
        MDLMesh *mesh = (MDLMesh *)o;
        for (MDLVertexAttribute *attr in mesh.vertexDescriptor.attributes) {
            if ([attr.name isEqualToString:MDLVertexAttributeColor]) {
                found = true;
                return;
            }
        }
    });
    return found;
}

static void fillWhiteVertexColorIfMissing(MTKMesh *mesh, NSArray<MDLMesh*> *mdlMeshes, bool hasAuthoredColor) {
    if (hasAuthoredColor || !mesh.vertexBuffers.count || !mdlMeshes.count) return;
    id<MTLBuffer> buffer = mesh.vertexBuffers[0].buffer;
    if (!buffer.contents) return;
    NSUInteger vertexCount = mdlMeshes[0].vertexCount;
    uint8_t *bytes = (uint8_t *)buffer.contents + mesh.vertexBuffers[0].offset;
    for (NSUInteger i = 0; i < vertexCount; ++i) {
        float *color = (float *)(bytes + i * 72 + 32);
        color[0] = 1.f;
        color[1] = 1.f;
        color[2] = 1.f;
        color[3] = 1.f;
    }
}

// UsdSkel meshes carry a geometry bind transform: the matrix mapping mesh
// space into skeleton space. Blender puts the mesh-object vs armature-object
// scale difference here (Quaternius dinos: Velociraptor 3.52x, Trex 0.333x —
// they authored each species' mesh and armature at different object scales).
// Skinning is only correct as boneMat * geomBind * vertex; ignoring geomBind
// skinned the raptor's vertices 3.5x too small relative to its joint spacing
// (body parts scattered along the skeleton — the "tail spike"), and the
// T-Rex's 3x too large (overlapping/blobby). Baking it into the vertex data
// once at load keeps the shader unchanged.
static matrix_double4x4 meshGeometryBindTransform(MDLAsset *asset) {
    __block matrix_double4x4 g = matrix_identity_double4x4;
    walkAsset(asset, ^(MDLObject *o) {
        if (![o isKindOfClass:[MDLMesh class]]) return;
        id comp = [o componentConformingToProtocol:@protocol(MDLComponent)];
        if ([comp isKindOfClass:[MDLAnimationBindComponent class]]) {
            g = ((MDLAnimationBindComponent *)comp).geometryBindTransform;
        }
    });
    return g;
}

static void applyGeometryBindTransform(MTKMesh *mesh, NSArray<MDLMesh*> *mdlMeshes,
                                       matrix_double4x4 gd) {
    if (!mesh.vertexBuffers.count || !mdlMeshes.count) return;
    id<MTLBuffer> buffer = mesh.vertexBuffers[0].buffer;
    if (!buffer.contents) return;

    simd_float4x4 g;
    for (int c = 0; c < 4; c++)
        g.columns[c] = (simd_float4){(float)gd.columns[c][0], (float)gd.columns[c][1],
                                     (float)gd.columns[c][2], (float)gd.columns[c][3]};
    // Normals transform by the inverse-transpose of the linear part.
    simd_float4x4 linear = g;
    linear.columns[3] = (simd_float4){0.f, 0.f, 0.f, 1.f};
    simd_float4x4 normalMat = simd_transpose(simd_inverse(linear));

    NSUInteger vertexCount = mdlMeshes[0].vertexCount;
    uint8_t *bytes = (uint8_t *)buffer.contents + mesh.vertexBuffers[0].offset;
    for (NSUInteger i = 0; i < vertexCount; ++i) {
        float *pos = (float *)(bytes + i * 72);
        float *nrm = (float *)(bytes + i * 72 + 12);
        simd_float4 p = simd_mul(g, (simd_float4){pos[0], pos[1], pos[2], 1.f});
        simd_float4 n = simd_mul(normalMat, (simd_float4){nrm[0], nrm[1], nrm[2], 0.f});
        simd_float3 n3 = simd_normalize((simd_float3){n.x, n.y, n.z});
        pos[0] = p.x; pos[1] = p.y; pos[2] = p.z;
        nrm[0] = n3.x; nrm[1] = n3.y; nrm[2] = n3.z;
    }
}

// Overwrites the Z (up-axis) bounds with the actual posed extent: CPU-skins
// every vertex with frame 0 of the Idle clip, exactly as the GPU will
// (boneMat * position, weighted). The renderer auto-scales each species by
// its measured height, so if that height comes from the bind-pose bounding
// box it silently absorbs a per-species fudge factor — a species whose idle
// stance stands taller or lower than its bind pose (or whose animation
// carries root translation) renders at the wrong size relative to others,
// which defeats cross-species scale comparisons.
static void measureIdlePoseBounds(MTKMesh *mesh, NSArray<MDLMesh*> *mdlMeshes,
                                  LoadedCharacter *result) {
    const BakedClip &idle = result->clips[(int)CharacterClipSlot::Idle];
    if (!result->clipLoaded[(int)CharacterClipSlot::Idle] || idle.frameCount == 0) return;
    if (!mesh.vertexBuffers.count || !mdlMeshes.count) return;
    id<MTLBuffer> buffer = mesh.vertexBuffers[0].buffer;
    if (!buffer.contents) return;
    NSUInteger vertexCount = mdlMeshes[0].vertexCount;
    if (!vertexCount) return;

    simd_float4x4 bones[kMaxBones];
    int jLim = idle.jointCount < kMaxBones ? idle.jointCount : kMaxBones;
    for (int j = 0; j < kMaxBones; j++) bones[j] = matrix_identity_float4x4;
    for (int j = 0; j < jLim; j++) {
        const float *m = idle.matrices.data() + j * 16; // frame 0
        for (int c = 0; c < 4; c++)
            bones[j].columns[c] = (simd_float4){m[c*4+0], m[c*4+1], m[c*4+2], m[c*4+3]};
    }

    const uint8_t *bytes = (const uint8_t *)buffer.contents + mesh.vertexBuffers[0].offset;
    float zMin = FLT_MAX, zMax = -FLT_MAX;
    for (NSUInteger i = 0; i < vertexCount; ++i) {
        const float *pos = (const float *)(bytes + i * 72);
        const uint16_t *ji = (const uint16_t *)(bytes + i * 72 + 48);
        const float *jw = (const float *)(bytes + i * 72 + 56);
        simd_float4 p = {pos[0], pos[1], pos[2], 1.f};
        simd_float4 skinned = {0.f, 0.f, 0.f, 0.f};
        float total = 0.f;
        for (int k = 0; k < 4; k++) {
            if (jw[k] > 0.001f && ji[k] < kMaxBones) {
                skinned += jw[k] * simd_mul(bones[ji[k]], p);
                total += jw[k];
            }
        }
        if (total < 0.001f) continue;
        float z = skinned.z / total;
        zMin = std::min(zMin, z);
        zMax = std::max(zMax, z);
    }
    if (zMin > zMax) return;
    result->meshZMin = zMin;
    result->meshZMax = zMax;
    NSLog(@"CharacterLoader: idle-pose Z bounds %.2f–%.2f (posed height %.2f)",
          zMin, zMax, zMax - zMin);
}

// Post-transform bounds, measured from the actual vertex buffer (the MDLMesh
// bounding box describes the pre-geomBind data).
static void measureVertexBounds(MTKMesh *mesh, NSArray<MDLMesh*> *mdlMeshes,
                                LoadedCharacter *result) {
    if (!mesh.vertexBuffers.count || !mdlMeshes.count) return;
    id<MTLBuffer> buffer = mesh.vertexBuffers[0].buffer;
    if (!buffer.contents) return;
    NSUInteger vertexCount = mdlMeshes[0].vertexCount;
    if (!vertexCount) return;
    uint8_t *bytes = (uint8_t *)buffer.contents + mesh.vertexBuffers[0].offset;
    simd_float3 mn = { FLT_MAX,  FLT_MAX,  FLT_MAX};
    simd_float3 mx = {-FLT_MAX, -FLT_MAX, -FLT_MAX};
    for (NSUInteger i = 0; i < vertexCount; ++i) {
        const float *pos = (const float *)(bytes + i * 72);
        mn = simd_min(mn, (simd_float3){pos[0], pos[1], pos[2]});
        mx = simd_max(mx, (simd_float3){pos[0], pos[1], pos[2]});
    }
    result->meshHeight = mx.y - mn.y;
    result->meshYMin   = mn.y;
    result->meshZMin   = mn.z;
    result->meshZMax   = mx.z;
    NSLog(@"CharacterLoader: mesh bounds X %.2f–%.2f  Y %.2f–%.2f  Z %.2f–%.2f",
          mn.x, mx.x, mn.y, mx.y, mn.z, mx.z);
}

static id<MTLTexture> makeWhiteFallbackTexture(id<MTLDevice> device) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                   width:1
                                                                                  height:1
                                                                               mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    const uint8_t white[4] = {255, 255, 255, 255};
    [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
               mipmapLevel:0
                 withBytes:white
               bytesPerRow:4];
    return texture;
}

static simd_float4x4 buildTRS(simd_float3 t, simd_quatf r, simd_float3 s) {
    simd_float4x4 T = matrix_identity_float4x4;
    T.columns[3] = (simd_float4){t.x, t.y, t.z, 1.f};
    simd_float4x4 R = simd_matrix4x4(r);
    simd_float4x4 S = matrix_identity_float4x4;
    S.columns[0].x = s.x; S.columns[1].y = s.y; S.columns[2].z = s.z;
    return simd_mul(T, simd_mul(R, S));
}

static void storeMat(float *dst, simd_float4x4 m) {
    for (int c = 0; c < 4; c++) {
        dst[c*4+0] = m.columns[c].x; dst[c*4+1] = m.columns[c].y;
        dst[c*4+2] = m.columns[c].z; dst[c*4+3] = m.columns[c].w;
    }
}

void BakedClip::sample(float clipTime, float dst[kMaxBones][16]) const {
    for (int b = 0; b < kMaxBones; b++) {
        memset(dst[b], 0, 64);
        dst[b][0] = dst[b][5] = dst[b][10] = dst[b][15] = 1.f;
    }
    if (frameCount == 0 || jointCount == 0) return;

    float fF = clipTime * kBakedFPS;
    int f0 = (int)fF;
    if (f0 < 0) f0 = 0;
    if (f0 >= frameCount) f0 = frameCount - 1;
    int f1 = (f0 + 1 < frameCount) ? f0 + 1 : f0;
    float a = fF - (float)f0;

    int jLim = jointCount < kMaxBones ? jointCount : kMaxBones;
    for (int j = 0; j < jLim; j++) {
        const float *m0 = matrices.data() + (f0 * jointCount + j) * 16;
        const float *m1 = matrices.data() + (f1 * jointCount + j) * 16;
        for (int k = 0; k < 16; k++)
            dst[j][k] = m0[k] + a * (m1[k] - m0[k]);
    }
}

LoadedCharacter* CharacterLoader_load(NSString* meshPath,
                                       NSArray<NSString*>* clipPaths,
                                       id<MTLDevice> device) {
    NSURL *meshURL = [NSURL fileURLWithPath:meshPath];
    bool hasAuthoredColor = assetHasVertexColor(meshURL);
    MDLVertexDescriptor *mdlVD = makeSkinnedMDLVD();
    MTKMeshBufferAllocator *alloc = [[MTKMeshBufferAllocator alloc] initWithDevice:device];

    [meshURL startAccessingSecurityScopedResource];
    MDLAsset *meshAsset = [[MDLAsset alloc] initWithURL:meshURL
                                        vertexDescriptor:mdlVD
                                         bufferAllocator:alloc];
    [meshAsset loadTextures];

    NSError *err = nil;
    NSArray<MDLMesh*> *mdlMeshes = nil;
    NSArray<MTKMesh*> *mtlMeshes = [MTKMesh newMeshesFromAsset:meshAsset
                                                         device:device
                                                   sourceMeshes:&mdlMeshes
                                                          error:&err];
    if (!mtlMeshes.count) {
        NSLog(@"CharacterLoader: mesh load failed (%@): %@", meshPath.lastPathComponent, err);
        return nullptr;
    }

    MTKMesh *mtlMesh = mtlMeshes[0];
    if (!mtlMesh.submeshes.count) {
        NSLog(@"CharacterLoader: no submeshes in %@", meshPath.lastPathComponent);
        return nullptr;
    }

    auto *result = new LoadedCharacter();
    MTKSubmesh *sub = mtlMesh.submeshes[0];
    result->vertexBuffer = mtlMesh.vertexBuffers[0].buffer;
    result->indexBuffer  = sub.indexBuffer.buffer;
    result->indexCount   = sub.indexCount;
    result->indexType    = sub.indexType;
    fillWhiteVertexColorIfMissing(mtlMesh, mdlMeshes, hasAuthoredColor);
    NSLog(@"CharacterLoader: vertex color %@", hasAuthoredColor ? @"authored" : @"default white");

    matrix_double4x4 geomBind = meshGeometryBindTransform(meshAsset);
    NSLog(@"CharacterLoader: geometryBindTransform diag (%.4f, %.4f, %.4f)",
          geomBind.columns[0][0], geomBind.columns[1][1], geomBind.columns[2][2]);
    applyGeometryBindTransform(mtlMesh, mdlMeshes, geomBind);

    // Measure mesh bounds (post-geomBind) so the renderer can auto-scale.
    measureVertexBounds(mtlMesh, mdlMeshes, result);

    // Try to extract the diffuse texture from the first submesh material.
    if (mdlMeshes.count && mdlMeshes[0].submeshes.count) {
        MDLMaterial *mat = mdlMeshes[0].submeshes[0].material;
        MDLMaterialProperty *baseProp = [mat propertyWithSemantic:MDLMaterialSemanticBaseColor];
        if (baseProp && baseProp.type == MDLMaterialPropertyTypeTexture
            && baseProp.textureSamplerValue.texture) {
            MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:device];
            NSError *texErr = nil;
            id<MTLTexture> tex = [loader newTextureWithMDLTexture:baseProp.textureSamplerValue.texture
                                                          options:nil error:&texErr];
            if (tex) {
                result->diffuseTexture = tex;
                NSLog(@"CharacterLoader: diffuse texture %lux%lu",
                      (unsigned long)tex.width, (unsigned long)tex.height);
            } else {
                NSLog(@"CharacterLoader: texture load failed: %@", texErr);
            }
        } else {
            NSLog(@"CharacterLoader: no diffuse texture in material");
        }
    }
    if (!result->diffuseTexture) {
        result->diffuseTexture = makeWhiteFallbackTexture(device);
        NSLog(@"CharacterLoader: using 1x1 white fallback texture");
    }

    // -----------------------------------------------------------------------
    // Extract skeleton — jointBindTransforms are WORLD SPACE (per MDLAnimation.h)
    // -----------------------------------------------------------------------
    MDLSkeleton *skel = findSkeleton(meshAsset);
    if (!skel) {
        NSLog(@"CharacterLoader: no skeleton in %@ — mesh loaded, no animation",
              meshPath.lastPathComponent);
        return result;
    }

    NSArray<NSString*> *jointPaths = skel.jointPaths;
    int jCount = (int)jointPaths.count;
    if (!jCount) { NSLog(@"CharacterLoader: empty skeleton"); return result; }
    result->jointCount = MIN(jCount, kMaxBones);

    NSMutableDictionary<NSString*, NSNumber*> *skelIdx = [NSMutableDictionary dictionary];
    for (int i = 0; i < jCount; i++) skelIdx[jointPaths[i]] = @(i);

    // World-space bind transforms and their inverses
    MDLMatrix4x4Array *bindArr = skel.jointBindTransforms;
    std::vector<simd_float4x4> worldBind(jCount, matrix_identity_float4x4);
    std::vector<simd_float4x4> invBind(jCount, matrix_identity_float4x4);
    if ((int)bindArr.elementCount >= jCount)
        [bindArr getFloat4x4Array:worldBind.data() maxCount:jCount];
    for (int i = 0; i < jCount; i++)
        invBind[i] = simd_inverse(worldBind[i]);

    // -----------------------------------------------------------------------
    // Bake each animation clip
    // -----------------------------------------------------------------------
    for (int ci = 0; ci < (int)CharacterClipSlot::Count; ci++) {
        NSString *clipPath = (ci < (int)clipPaths.count) ? clipPaths[ci] : nil;
        if (!clipPath.length) continue;
        if (![[NSFileManager defaultManager] fileExistsAtPath:clipPath]) {
            NSLog(@"CharacterLoader: clip not found: %@", clipPath.lastPathComponent);
            continue;
        }

        MDLAsset *animAsset = [[MDLAsset alloc] initWithURL:[NSURL fileURLWithPath:clipPath]];
        MDLPackedJointAnimation *anim = findAnim(animAsset);
        if (!anim) {
            NSLog(@"CharacterLoader: no PackedJointAnimation in %@", clipPath.lastPathComponent);
            continue;
        }

        NSArray<NSString*> *aPaths = anim.jointPaths;
        int aJ = (int)aPaths.count;
        if (!aJ) continue;

        double dur = animAsset.endTime - animAsset.startTime;
        if (dur <= 0) continue;
        int frames = (int)ceil(dur * kBakedFPS) + 1;

        // Map anim joints → skeleton joints (strip armature prefix if present)
        NSMutableDictionary<NSString*, NSNumber*> *animIdx = [NSMutableDictionary dictionary];
        for (int i = 0; i < aJ; i++) animIdx[aPaths[i]] = @(i);

        NSString *stripPfx = nil;
        if (!skelIdx[aPaths[0]]) {
            NSRange fs = [aPaths[0] rangeOfString:@"/"];
            if (fs.location != NSNotFound) {
                NSString *stripped = [aPaths[0] substringFromIndex:fs.location+1];
                if (skelIdx[stripped])
                    stripPfx = [aPaths[0] substringToIndex:fs.location+1];
            }
        }

        std::vector<int> animToSkel(aJ, -1), animParent(aJ, -1);
        for (int i = 0; i < aJ; i++) {
            NSString *p = aPaths[i];
            NSString *norm = (stripPfx && [p hasPrefix:stripPfx])
                             ? [p substringFromIndex:stripPfx.length] : p;
            NSNumber *si = skelIdx[norm];
            animToSkel[i] = si ? si.intValue : -1;

            NSRange lr = [p rangeOfString:@"/" options:NSBackwardsSearch];
            if (lr.location != NSNotFound) {
                NSString *pp = [p substringToIndex:lr.location];
                NSNumber *pi = animIdx[pp];
                if (pi) animParent[i] = pi.intValue;
            }
        }

        BakedClip &clip = result->clips[ci];
        clip.frameCount = frames;
        clip.jointCount = jCount;
        clip.matrices.assign(frames * jCount * 16, 0.f);
        for (int f = 0; f < frames; f++)
            for (int j = 0; j < jCount; j++) {
                float *m = clip.matrices.data() + (f * jCount + j) * 16;
                m[0] = m[5] = m[10] = m[15] = 1.f;
            }

        // Find root joint (no parent) so we can strip horizontal root motion.
        int rootAnimIdx = -1;
        for (int i = 0; i < aJ; i++) {
            if (animParent[i] == -1) { rootAnimIdx = i; break; }
        }
        simd_float3 rootTrans0 = {0.f, 0.f, 0.f};
        bool rootTrans0Set = false;

        std::vector<simd_float3>   trans(aJ), scl(aJ);
        std::vector<simd_quatf>    rots(aJ);
        std::vector<simd_float4x4> worldAnim(aJ, matrix_identity_float4x4);

        for (int f = 0; f < frames; f++) {
            double t = animAsset.startTime + (f / (double)kBakedFPS);
            [anim.translations getFloat3Array:trans.data()  maxCount:aJ atTime:t];
            [anim.rotations    getFloatQuaternionArray:rots.data() maxCount:aJ atTime:t];
            [anim.scales       getFloat3Array:scl.data()   maxCount:aJ atTime:t];

            // Strip root motion: lock X and Z to frame-0 so character stays at ECS position.
            // Y (vertical in FBX space) is preserved for natural up/down bobbing.
            if (rootAnimIdx >= 0) {
                if (!rootTrans0Set) {
                    rootTrans0 = trans[rootAnimIdx];
                    rootTrans0Set = true;
                }
                trans[rootAnimIdx].x = rootTrans0.x;
                trans[rootAnimIdx].z = rootTrans0.z;
            }

            for (int ai = 0; ai < aJ; ai++) {
                simd_float4x4 local = buildTRS(trans[ai], rots[ai], scl[ai]);
                int p = animParent[ai];
                worldAnim[ai] = (p >= 0) ? simd_mul(worldAnim[p], local) : local;
            }

            for (int ai = 0; ai < aJ; ai++) {
                int si = animToSkel[ai];
                if (si < 0 || si >= jCount) continue;
                simd_float4x4 bm = simd_mul(worldAnim[ai], invBind[si]);
                storeMat(clip.matrices.data() + (f * jCount + si) * 16, bm);
            }
        }

        result->clipLoaded[ci] = true;
        NSLog(@"CharacterLoader: clip %s — %d frames, %d anim joints, %.2fs — %@",
              CharacterClipSlot_name((CharacterClipSlot)ci), frames, aJ, (float)dur, clipPath.lastPathComponent);
    }

    CharacterClipTable_validate_required(result->clipLoaded, meshPath.lastPathComponent);

    // With all clips baked, replace the bind-pose Z bounds with the actual
    // idle-posed extent (see measureIdlePoseBounds).
    measureIdlePoseBounds(mtlMesh, mdlMeshes, result);

    NSLog(@"CharacterLoader: loaded '%@' — %d joints, %lu indices",
          meshPath.lastPathComponent, jCount, (unsigned long)result->indexCount);
    return result;
}
