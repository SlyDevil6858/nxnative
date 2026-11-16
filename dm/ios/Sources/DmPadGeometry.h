// Geometry and validation shared by the touch-control editor and profile storage.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

static inline BOOL dm_pad_entry_valid(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;

    // Editor operations may update only one property at a time: scale-only,
    // opacity-only, or position-only (x/y). Keep those partial records valid.
    BOOL hasX = value[@"x"] != nil, hasY = value[@"y"] != nil;
    BOOL hasScale = value[@"scale"] != nil, hasAlpha = value[@"alpha"] != nil;
    if (hasX != hasY || (!hasX && !hasScale && !hasAlpha)) return NO;

    for (NSString *key in @[@"x", @"y", @"scale", @"alpha"]) {
        id number = value[key];
        if (!number) continue;
        BOOL scale = [key isEqual:@"scale"];
        if (![number isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return NO;
        double n = [number doubleValue];
        if (!isfinite(n) || n < (scale ? 0.5 : 0.0) || n > (scale ? 2.0 : 1.0)) return NO;
    }
    return YES;
}

static inline CGPoint dm_pad_clamp(CGPoint p, CGRect r, CGFloat margin) {
    CGFloat mx = MIN(margin, r.size.width / 2.0);
    CGFloat my = MIN(margin, r.size.height / 2.0);
    return CGPointMake(fmin(fmax(p.x, CGRectGetMinX(r) + mx), CGRectGetMaxX(r) - mx),
                       fmin(fmax(p.y, CGRectGetMinY(r) + my), CGRectGetMaxY(r) - my));
}

static inline CGPoint dm_pad_position(NSDictionary *value, CGPoint original, CGRect safe, CGFloat margin) {
    if (!value) return original;
    CGPoint point = CGPointMake(safe.origin.x + [value[@"x"] doubleValue] * safe.size.width,
                                safe.origin.y + [value[@"y"] doubleValue] * safe.size.height);
    return dm_pad_clamp(point, safe, margin);
}

static inline CGFloat dm_pad_distance(CGPoint point, CGPoint center, CGFloat radius) {
    return radius > 0 ? hypot(point.x - center.x, point.y - center.y) / radius : INFINITY;
}
