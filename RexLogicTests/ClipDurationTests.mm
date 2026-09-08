#import <XCTest/XCTest.h>
#include "Simulation/Systems/AnimationSystem.h"
#include "Assets/CharacterLoader.h"
#include <memory>
#import <ModelIO/ModelIO.h>
#include <cmath>

@interface ClipDurationTests : XCTestCase
@end
@implementation ClipDurationTests
- (void)test_raptorInterruptWindowUsesBakedAttackDuration {
    World world;
    const auto& dino = world.get_component<DinoBehaviorComponent>(0);
    float duration = AnimationSystem_clip_duration(world, 0, CharacterClipSlot::Attack);
    XCTAssertEqual(duration, 26.f / 30.f);
    // Old headless fallback: 1.03 / 4 * (0.85 - 0.18) = 0.172525 seconds.
    // Actual baked clip: 26/30 / 4 * (0.85 - 0.18) = 0.14516667 seconds.
    XCTAssertEqualWithAccuracy(duration / kAttackClipSpeedMultiplier
        * (dino.interruptEndNormalized - dino.interruptStartNormalized), 0.14516667f, 0.000001f);
}
- (void)test_tableMatchesLoadedAssets {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    XCTSkipIf(device == nil, @"Metal unavailable; cannot load and bake character assets");
    for (int s = 0; s < (int)DinoSpecies::Count; ++s) {
        NSString* species = [NSString stringWithUTF8String:DinoSpecies_name((DinoSpecies)s)];
        NSString* dir = [@"assets/characters/dinos" stringByAppendingPathComponent:species];
        NSBundle* bundle = [NSBundle bundleForClass:[self class]];
        NSString* mesh = [bundle pathForResource:@"base" ofType:@"usdz" inDirectory:dir];
        XCTAssertNotNil(mesh);
        NSMutableArray* clips = [NSMutableArray array];
        for (int c = 0; c < (int)CharacterClipSlot::Count; ++c) {
            NSString* name = [NSString stringWithUTF8String:CharacterClipSlot_name((CharacterClipSlot)c)];
            NSString* path = [bundle pathForResource:[name lowercaseString] ofType:@"usdz" inDirectory:dir];
            XCTAssertNotNil(path);
            if (!path) return;
            [clips addObject:path];
        }
        std::unique_ptr<LoadedCharacter> loaded(CharacterLoader_load(mesh, clips, device));
        XCTAssertTrue(loaded != nullptr);
        if (!loaded) return;
        std::string error;
        XCTAssertTrue(AnimationSystem_validate_clip_durations((DinoSpecies)s, *loaded, &error), @"%s", error.c_str());
        for (int c = 0; c < (int)CharacterClipSlot::Count; ++c)
            XCTAssertEqualWithAccuracy(loaded->clips[c].duration(), kClipDurations[s][c], kClipDurationEpsilon,
                                      @"species %d clip %d", s, c);
    }
}
- (void)test_loadedMismatchNamesSpeciesAndClipAndCannotChangeSimulation {
    LoadedCharacter character;
    for (int c = 0; c < (int)CharacterClipSlot::Count; ++c) {
        character.clipLoaded[c] = true;
        character.clips[c].frameCount = (int)lroundf(kClipDurations[0][c] * 30);
    }
    character.clips[(int)CharacterClipSlot::Attack].frameCount += 1;
    std::string error;
    XCTAssertFalse(AnimationSystem_validate_clip_durations(DinoSpecies::Velociraptor, character, &error));
    XCTAssertTrue(error.find("clipDurations[0][attack]") != std::string::npos);
    AnimationSystem_set_dino_character(DinoSpecies::Velociraptor, &character);
    World world;
    XCTAssertEqual(AnimationSystem_clip_duration(world, 0, CharacterClipSlot::Attack), 26.f/30.f);
    AnimationSystem_set_dino_character(DinoSpecies::Velociraptor, nullptr);
}

// Device-free counterpart to test_tableMatchesLoadedAssets. That one needs a
// Metal device to bake, so it SKIPS on CI — meaning the drift M4b just fixed
// (a stale table silently disagreeing with the assets) could return unnoticed.
// MDLAsset reads the timing metadata without any device, and the loader's own
// ceil(dur * kBakedFPS) + 1 is reproduced here, so this FAILS rather than skips.
- (void)test_tableMatchesAssetMetadataWithoutAMetalDevice {
    NSBundle* bundle = [NSBundle bundleForClass:[self class]];
    for (int s = 0; s < (int)DinoSpecies::Count; ++s) {
        NSString* species = [NSString stringWithUTF8String:DinoSpecies_name((DinoSpecies)s)];
        NSString* dir = [@"assets/characters/dinos" stringByAppendingPathComponent:species];
        // The base has no clip duration, but must also be readable without
        // Metal: missing or LFS-pointer meshes should fail this CI check.
        NSString* mesh = [bundle pathForResource:@"base" ofType:@"usdz" inDirectory:dir];
        XCTAssertNotNil(mesh, @"%@ base missing from the test bundle", species);
        if (mesh) {
            MDLAsset* base = [[MDLAsset alloc] initWithURL:[NSURL fileURLWithPath:mesh]];
            XCTAssertGreaterThan([base childObjectsOfClass:[MDLMesh class]].count, (NSUInteger)0,
                                 @"%@ base has no mesh", species);
        }
        for (int c = 0; c < (int)CharacterClipSlot::Count; ++c) {
            NSString* name = [NSString stringWithUTF8String:CharacterClipSlot_name((CharacterClipSlot)c)];
            NSString* path = [bundle pathForResource:[name lowercaseString] ofType:@"usdz" inDirectory:dir];
            XCTAssertNotNil(path, @"%@ %@ missing from the test bundle", species, name);
            if (!path) continue;
            MDLAsset* asset = [[MDLAsset alloc] initWithURL:[NSURL fileURLWithPath:path]];
            XCTAssertNotNil(asset);
            double dur = asset.endTime - asset.startTime;
            XCTAssertGreaterThan(dur, 0.0, @"%@ %@ has no timeline", species, name);
            int frames = (int)ceil(dur * kBakedFPS) + 1;
            float baked = (float)frames / kBakedFPS;
            XCTAssertEqualWithAccuracy(baked, kClipDurations[s][c], kClipDurationEpsilon,
                @"%@ %@: assets say %.6f (%d frames), table says %.6f",
                species, name, baked, frames, kClipDurations[s][c]);
        }
    }
}

@end
