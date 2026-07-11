#include "ChartLoader.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <stdexcept>

static std::runtime_error chart_error(NSString *message) {
    return std::runtime_error([[NSString stringWithFormat:@"ChartLoader: %@", message] UTF8String]);
}

static NSArray *required_array(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    if (![value isKindOfClass:[NSArray class]]) {
        @throw [NSException exceptionWithName:@"ChartLoaderValidation"
                                       reason:[NSString stringWithFormat:@"missing array %@", key]
                                     userInfo:nil];
    }
    return (NSArray *)value;
}

static NSNumber *required_number(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    if (![value isKindOfClass:[NSNumber class]]) {
        @throw [NSException exceptionWithName:@"ChartLoaderValidation"
                                       reason:[NSString stringWithFormat:@"missing number %@", key]
                                     userInfo:nil];
    }
    return (NSNumber *)value;
}

static RexVec3 parse_vec3(id value, NSString *label) {
    if (![value isKindOfClass:[NSArray class]] || [(NSArray *)value count] != 3) {
        @throw [NSException exceptionWithName:@"ChartLoaderValidation"
                                       reason:[NSString stringWithFormat:@"%@ must be [x,y,z]", label]
                                     userInfo:nil];
    }
    NSArray *array = (NSArray *)value;
    for (id n in array) {
        if (![n isKindOfClass:[NSNumber class]]) {
            @throw [NSException exceptionWithName:@"ChartLoaderValidation"
                                           reason:[NSString stringWithFormat:@"%@ contains non-number", label]
                                         userInfo:nil];
        }
    }
    return {[(NSNumber *)array[0] floatValue],
            [(NSNumber *)array[1] floatValue],
            [(NSNumber *)array[2] floatValue]};
}

static RaptorWaveChartPayload parse_raptor_wave_payload(id payload) {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        throw chart_error(@"raptor_wave payload must be an object");
    }
    NSDictionary *dict = (NSDictionary *)payload;

    int groupSize = [required_number(dict, @"groupSize") intValue];
    if (groupSize < 1 || groupSize > 3) {
        throw chart_error(@"raptor_wave groupSize must be 1, 2, or 3");
    }

    NSArray *lanes = required_array(dict, @"lanes");
    if ((int)lanes.count != groupSize) {
        throw chart_error(@"raptor_wave lanes count must equal groupSize");
    }

    RaptorWaveChartPayload out;
    out.valid = true;
    out.groupSize = (uint8_t)groupSize;
    for (int i = 0; i < groupSize; ++i) {
        if (![lanes[i] isKindOfClass:[NSNumber class]]) {
            throw chart_error(@"raptor_wave lanes must contain numbers");
        }
        out.lanes[i] = [(NSNumber *)lanes[i] floatValue];
    }

    out.spawnGap = [required_number(dict, @"spawnGap") floatValue];
    out.holdSeconds = [required_number(dict, @"holdSeconds") floatValue];
    out.attackStaggerSeconds = [required_number(dict, @"attackStaggerSeconds") floatValue];
    if (out.spawnGap <= 1.f) {
        throw chart_error(@"raptor_wave spawnGap must be greater than 1");
    }
    if (out.holdSeconds < 0.f || out.attackStaggerSeconds < 0.f) {
        throw chart_error(@"raptor_wave timing values must be non-negative");
    }

    id label = dict[@"label"];
    if (label) {
        if (![label isKindOfClass:[NSString class]]) {
            throw chart_error(@"raptor_wave label must be a string");
        }
        out.label = [(NSString *)label UTF8String];
    }
    return out;
}

static std::string json_string_for_object(id object) {
    if (!object || ![NSJSONSerialization isValidJSONObject:object]) return "{}";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return "{}";
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return string ? [string UTF8String] : "{}";
}

// Optional numeric field: absent -> fallback, present-but-not-a-number ->
// loud failure (a typo'd value should never silently become the default).
static float optional_float(NSDictionary *dict, NSString *key, float fallback) {
    id value = dict[key];
    if (!value) return fallback;
    if (![value isKindOfClass:[NSNumber class]]) {
        throw chart_error([NSString stringWithFormat:@"%@ must be a number", key]);
    }
    return [(NSNumber *)value floatValue];
}

static BossChartConfig parse_boss_config(id bossObject) {
    if (![bossObject isKindOfClass:[NSDictionary class]]) {
        throw chart_error(@"boss must be an object");
    }
    NSDictionary *dict = (NSDictionary *)bossObject;
    id species = dict[@"species"];
    if (![species isKindOfClass:[NSString class]]) {
        throw chart_error(@"boss.species must be a string");
    }
    BossChartConfig out; // field defaults double as the fallback values
    out.species = [(NSString *)species UTF8String];
    // Species whitelist mirrors the loadable character set — a typo (or a
    // species whose asset hasn't landed yet, e.g. triceratops) must fail at
    // chart load, not silently render the wrong boss.
    if (out.species != "trex" && out.species != "velociraptor") {
        throw chart_error([NSString stringWithFormat:
            @"boss.species '%@' is not a loadable character (supported: trex, velociraptor)",
            (NSString *)species]);
    }
    out.valid = true;
    out.maxHealth = (int)optional_float(dict, @"health", (float)out.maxHealth);
    out.attackDamage = (int)optional_float(dict, @"attackDamage", (float)out.attackDamage);
    out.attackRange = optional_float(dict, @"attackRange", out.attackRange);
    out.chaseSpeed = optional_float(dict, @"chaseSpeed", out.chaseSpeed);
    out.holdDuration = optional_float(dict, @"holdDuration", out.holdDuration);
    if (out.maxHealth < 1) throw chart_error(@"boss.health must be at least 1");
    return out;
}

LevelChart ChartLoader_load_file(const char *path) {
    @autoreleasepool {
        @try {
            NSString *nsPath = path ? [NSString stringWithUTF8String:path] : nil;
            if (!nsPath.length) throw chart_error(@"empty path");

            NSData *data = [NSData dataWithContentsOfFile:nsPath];
            if (!data) {
                throw chart_error([NSString stringWithFormat:@"missing chart %@", nsPath]);
            }

            NSError *error = nil;
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if (!root || ![root isKindOfClass:[NSDictionary class]]) {
                throw chart_error([NSString stringWithFormat:@"malformed JSON %@", error]);
            }

            NSDictionary *dict = (NSDictionary *)root;
            NSDictionary *railDict = dict[@"rail"];
            if (![railDict isKindOfClass:[NSDictionary class]]) {
                throw chart_error(@"missing rail object");
            }

            NSArray *pointsJSON = required_array(railDict, @"controlPoints");
            std::vector<RexVec3> points;
            points.reserve(pointsJSON.count);
            for (NSUInteger i = 0; i < pointsJSON.count; ++i) {
                points.push_back(parse_vec3(pointsJSON[i], [NSString stringWithFormat:@"rail.controlPoints[%lu]", (unsigned long)i]));
            }

            int samplesPerSegment = 64;
            id samples = railDict[@"samplesPerSegment"];
            if ([samples isKindOfClass:[NSNumber class]]) {
                samplesPerSegment = [(NSNumber *)samples intValue];
            }

            LevelChart chart;
            chart.rail.build(points, samplesPerSegment);

            NSArray *beatsJSON = required_array(dict, @"lookAtBeats");
            for (id beatObject in beatsJSON) {
                if (![beatObject isKindOfClass:[NSDictionary class]]) {
                    throw chart_error(@"lookAtBeats entries must be objects");
                }
                NSDictionary *beat = (NSDictionary *)beatObject;
                LookAtBeat out;
                out.distance = [required_number(beat, @"distance") floatValue];
                out.target = parse_vec3(beat[@"target"], @"lookAtBeats.target");
                chart.lookAtBeats.push_back(out);
            }
            std::sort(chart.lookAtBeats.begin(), chart.lookAtBeats.end(),
                      [](const LookAtBeat& a, const LookAtBeat& b) { return a.distance < b.distance; });
            if (chart.lookAtBeats.empty()) {
                throw chart_error(@"chart must contain at least one lookAt beat");
            }

            NSArray *eventsJSON = required_array(dict, @"events");
            for (id eventObject in eventsJSON) {
                if (![eventObject isKindOfClass:[NSDictionary class]]) {
                    throw chart_error(@"events entries must be objects");
                }
                NSDictionary *event = (NSDictionary *)eventObject;
                id type = event[@"type"];
                if (![type isKindOfClass:[NSString class]]) {
                    throw chart_error(@"event.type must be a string");
                }
                ChartEvent out;
                out.distance = [required_number(event, @"distance") floatValue];
                out.type = [(NSString *)type UTF8String];
                id payload = event[@"payload"] ?: @{};
                out.payloadJSON = json_string_for_object(payload);
                if (out.type == "raptor_wave") {
                    out.raptorWave = parse_raptor_wave_payload(payload);
                }
                chart.events.push_back(out);
            }
            std::sort(chart.events.begin(), chart.events.end(),
                      [](const ChartEvent& a, const ChartEvent& b) { return a.distance < b.distance; });

            // Optional per-level boss block; absent -> World's built-in
            // T-Rex defaults (chart.boss.valid stays false).
            id bossJSON = dict[@"boss"];
            if (bossJSON) chart.boss = parse_boss_config(bossJSON);
            return chart;
        } @catch (NSException *exception) {
            throw chart_error(exception.reason ?: @"validation failed");
        }
    }
}

LevelChart ChartLoader_load_default() {
    @autoreleasepool {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"m2-test"
                                                         ofType:@"json"
                                                    inDirectory:@"assets/charts"];
        if (!path) {
            for (NSBundle *bundle in [NSBundle allBundles]) {
                path = [bundle pathForResource:@"m2-test"
                                        ofType:@"json"
                                   inDirectory:@"assets/charts"];
                if (path) break;
            }
        }
        if (!path) {
            NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
            NSString *candidate = [resourcePath stringByAppendingPathComponent:@"assets/charts/m2-test.json"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                path = candidate;
            }
        }
        if (!path) {
            throw chart_error(@"default chart assets/charts/m2-test.json missing from bundle");
        }
        return ChartLoader_load_file(path.UTF8String);
    }
}
