#pragma once
#import <Foundation/Foundation.h>
#include "Simulation/ChartLoader.h"

class World;

// Test-only chart authoring.
//
// Building a scenario used to cost ~25 lines of JSON surgery per test: load
// m2-test.json, walk events for a label, rewrite its distance, shove the boss
// out of range, re-serialize, write a fixture, load it. This wraps that.
//
// It deliberately writes real bytes and loads them through ChartLoader rather
// than synthesizing a LevelChart in memory: M4b's replay header hashes the
// chart's bytes, so a scenario that skipped the loader would produce a chart
// with no honest identity and silently weaken every replay assertion built on
// it. Sorted-key serialization keeps the same scenario hashing identically
// across runs.
class Scenario {
public:
    Scenario();                              // starts from assets/charts/m2-test.json

    Scenario& onlyWave(NSString *label);     // keep just this labelled wave, at distance 0
    Scenario& noBoss();                      // push arrival out of reach
    Scenario& noArena();                     // no post-boss holdout
    Scenario& seed(uint32_t s);              // recorded for applyTo(); default 0xC0FFEE

    LevelChart build();                      // serialize (sorted keys) -> write -> load
    void applyTo(World &world);              // build() + replace_chart_for_tests + set_seed

    NSString *lastFixturePath() const { return _lastPath; }

private:
    NSMutableDictionary *_json;
    NSString *_lastPath;
    uint32_t _seed;
};
