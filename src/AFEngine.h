// AFEngine.h — AppForge Live: renders real UIKit from a JSON app spec; logic runs in JavaScriptCore.
// Shared verbatim by AppForge (live preview) and by every generated wrapper app.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AFEngine : NSObject
/// Runtime JS (AFEnginePrelude.js from the main bundle).
+ (NSString *)preludeSource;
/// Headless check (any thread): JSON parse, structure validation, script boot, one evaluation of every binding.
/// Returns human-readable problems; empty array = OK.
+ (NSArray<NSString *> *)checkSpecJSON:(NSString *)json;
+ (nullable UIColor *)colorFromString:(nullable NSString *)s;

/// storePrefix namespaces NSUserDefaults (persisted state + store.*).
- (instancetype)initWithSpecJSON:(NSString *)json storePrefix:(NSString *)prefix;
@property (nonatomic, readonly) UIViewController *rootViewController;
@property (nonatomic, readonly) NSArray<NSString *> *errors;
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);
/// Stops timers, motion, sound. Call before discarding.
- (void)stop;
@end

NS_ASSUME_NONNULL_END
