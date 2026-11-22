// AFEngine.m — AppForge Live runtime (UIKit renderer + JavaScriptCore logic).
#import "AFEngine.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>

static char kAFENodeKey, kAFETargetsKey, kAFEControlKey, kAFELabelKey, kAFEAbsKey, kAFEWKey, kAFEHKey, kAFERotKey, kAFEScaleKey;

static NSString *AFEStr(id v) {
  if ([v isKindOfClass:NSString.class]) return v;
  if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
  return nil;
}
static BOOL AFEIsNum(id v) {
  if ([v isKindOfClass:NSNumber.class]) return YES;
  if ([v isKindOfClass:NSString.class] && [v length]) {
    NSScanner *sc = [NSScanner scannerWithString:v];
    double d; return [sc scanDouble:&d] && sc.isAtEnd;
  }
  return NO;
}
static double AFENum(id v, double def) { return AFEIsNum(v) ? [v doubleValue] : def; }
static BOOL AFEBool(id v, BOOL def) {
  if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
  if ([v isKindOfClass:NSString.class]) {
    NSString *s = [v lowercaseString];
    return [s isEqualToString:@"true"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
  }
  return def;
}
static NSString *AFEType(id t) {
  NSString *s = AFEStr(t) ?: @"";
  NSDictionary *alias = @{ @"label": @"text", @"textfield": @"input", @"switch": @"toggle", @"column": @"vstack",
                           @"row": @"hstack", @"stack": @"vstack", @"view": @"vstack" };
  return alias[s] ?: s;
}
static UIEdgeInsets AFEInsets(id p) {
  if (AFEIsNum(p)) { CGFloat v = [p doubleValue]; return UIEdgeInsetsMake(v, v, v, v); }
  if ([p isKindOfClass:NSArray.class]) {
    NSArray *a = p;
    if (a.count == 2) { CGFloat v = AFENum(a[0], 0), h = AFENum(a[1], 0); return UIEdgeInsetsMake(v, h, v, h); }
    if (a.count == 4) return UIEdgeInsetsMake(AFENum(a[0], 0), AFENum(a[3], 0), AFENum(a[2], 0), AFENum(a[1], 0));
  }
  if ([p isKindOfClass:NSDictionary.class]) {
    NSDictionary *d = p;
    return UIEdgeInsetsMake(AFENum(d[@"top"], 0), AFENum(d[@"left"], 0), AFENum(d[@"bottom"], 0), AFENum(d[@"right"], 0));
  }
  return UIEdgeInsetsZero;
}
static UIFontWeight AFEWeight(NSString *w) {
  NSDictionary *m = @{ @"ultralight": @(UIFontWeightUltraLight), @"thin": @(UIFontWeightThin), @"light": @(UIFontWeightLight),
    @"regular": @(UIFontWeightRegular), @"medium": @(UIFontWeightMedium), @"semibold": @(UIFontWeightSemibold),
    @"bold": @(UIFontWeightBold), @"heavy": @(UIFontWeightHeavy), @"black": @(UIFontWeightBlack) };
  NSNumber *n = m[w.lowercaseString ?: @""];
  return n ? (UIFontWeight)n.doubleValue : UIFontWeightRegular;
}

#pragma mark - small views

@interface AFELabel : UILabel
@property (nonatomic) UIEdgeInsets insets;
@end
@implementation AFELabel
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)n {
  UIEdgeInsets i = _insets;
  CGRect r = [super textRectForBounds:UIEdgeInsetsInsetRect(bounds, i) limitedToNumberOfLines:n];
  return UIEdgeInsetsInsetRect(r, UIEdgeInsetsMake(-i.top, -i.left, -i.bottom, -i.right));
}
- (void)drawTextInRect:(CGRect)r { [super drawTextInRect:UIEdgeInsetsInsetRect(r, _insets)]; }
@end

@interface AFEButton : UIButton
@property (nonatomic) BOOL circle;
@end
@implementation AFEButton
- (void)layoutSubviews {
  [super layoutSubviews];
  if (_circle) self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
}
- (void)setHighlighted:(BOOL)h {
  [super setHighlighted:h];
  [UIView animateWithDuration:0.12 animations:^{ self.transform = h ? CGAffineTransformMakeScale(0.96, 0.96) : CGAffineTransformIdentity; }];
}
@end

@class AFEngine;
@interface AFECanvas : UIView
@property (nonatomic, weak) AFEngine *engine;
@property (nonatomic, copy) NSString *nodeId;
@property (nonatomic) CGSize lastSize;
@end

@interface AFEScope : NSObject
@property (nonatomic, strong) NSMutableArray *bindings;
@property (nonatomic, strong) NSMutableArray *lists;
@end
@implementation AFEScope
- (instancetype)init { if ((self = [super init])) { _bindings = [NSMutableArray new]; _lists = [NSMutableArray new]; } return self; }
@end

@interface AFEBinding : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, copy) NSString *prop;
@property (nonatomic) NSInteger expr;
@property (nonatomic, strong) JSValue *item;
@property (nonatomic) NSInteger index;
@property (nonatomic, strong) id last;
@end
@implementation AFEBinding
@end

@interface AFEList : NSObject
@property (nonatomic, weak) UIStackView *stack;
@property (nonatomic) NSInteger expr;
@property (nonatomic, strong) NSDictionary *node;
@property (nonatomic, copy) NSString *sig;
@property (nonatomic, strong) AFEScope *scope;
@property (nonatomic, strong) JSValue *item;
@property (nonatomic) NSInteger index;
@end
@implementation AFEList
@end

@interface AFEScreenVC : UIViewController
@property (nonatomic, weak) AFEngine *engine;
@property (nonatomic, strong) NSDictionary *screen;
@property (nonatomic, strong) AFEScope *scope;
@property (nonatomic, weak) UIScrollView *scroll;
@property (nonatomic, strong) NSMutableArray *targets;
@end

@interface AFEAction : NSObject
@property (nonatomic, weak) AFEngine *engine;
@property (nonatomic) NSInteger action;
@property (nonatomic, strong) JSValue *item;
@property (nonatomic) NSInteger index;
@property (nonatomic, copy) NSString *bind;
@property (nonatomic, weak) UIView *control;
- (void)fire:(id)sender;
@end

@interface AFEngine () <UITextViewDelegate>
- (void)buildScreen:(AFEScreenVC *)vc;
- (void)runActionSource:(NSString *)src item:(JSValue *)item index:(NSInteger)index value:(id)value;
- (void)runActionIndex:(NSInteger)a item:(JSValue *)item index:(NSInteger)index value:(id)value;
- (void)setBind:(NSString *)key value:(id)value;
- (id)valueOfControl:(UIView *)c;
- (void)setNeedsRefresh;
- (void)canvas:(AFECanvas *)c resized:(CGSize)s;
@end

@implementation AFECanvas
- (void)layoutSubviews {
  [super layoutSubviews];
  if (!CGSizeEqualToSize(self.bounds.size, _lastSize)) {
    _lastSize = self.bounds.size;
    [self.engine canvas:self resized:_lastSize];
  }
}
@end

@implementation AFEAction
- (void)fire:(id)sender {
  AFEngine *e = self.engine;
  if (!e) return;
  id value = nil;
  if ([sender isKindOfClass:UILongPressGestureRecognizer.class]) {
    if (((UIGestureRecognizer *)sender).state != UIGestureRecognizerStateBegan) return;
  }
  if ([sender isKindOfClass:UIPanGestureRecognizer.class]) {
    UIPanGestureRecognizer *p = sender;
    CGPoint loc = [p locationInView:p.view], tr = [p translationInView:p.view];
    NSString *st = p.state == UIGestureRecognizerStateBegan ? @"began" : (p.state == UIGestureRecognizerStateChanged ? @"changed" : @"ended");
    value = @{ @"x": @(loc.x), @"y": @(loc.y), @"dx": @(tr.x), @"dy": @(tr.y), @"state": st };
  } else if ([sender isKindOfClass:UIGestureRecognizer.class]) {
    UIGestureRecognizer *g = sender;
    CGPoint loc = [g locationInView:g.view];
    value = @{ @"x": @(loc.x), @"y": @(loc.y) };
  } else if (self.control) {
    value = [e valueOfControl:self.control];
  }
  if (self.bind.length) [e setBind:self.bind value:value];
  if (self.action >= 0) [e runActionIndex:self.action item:self.item index:self.index value:value];
  else [e setNeedsRefresh];
}
@end

@implementation AFEScreenVC
- (void)viewDidLoad {
  [super viewDidLoad];
  self.targets = self.targets ?: [NSMutableArray new];
  [self.engine buildScreen:self];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(kb:) name:UIKeyboardWillChangeFrameNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)kb:(NSNotification *)n {
  UIScrollView *sc = self.scroll;
  if (!sc || !self.view.window) return;
  CGRect f = [self.view convertRect:[n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromView:nil];
  CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - f.origin.y - self.view.safeAreaInsets.bottom);
  UIEdgeInsets in = sc.contentInset; in.bottom = overlap; sc.contentInset = in;
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.navigationController setNavigationBarHidden:AFEBool(self.screen[@"hideNav"], NO) animated:animated];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  NSString *oa = AFEStr(self.screen[@"onAppear"]);
  if (oa.length) [self.engine runActionSource:oa item:nil index:0 value:nil];
}
@end

#pragma mark - engine

@implementation AFEngine {
  JSContext *_ctx;
  NSDictionary *_spec;
  NSString *_json, *_prefix;
  NSHashTable *_screens;
  NSMutableDictionary<NSNumber *, NSTimer *> *_timers;
  NSMutableDictionary<NSString *, NSNumber *> *_exprCache, *_actionCache;
  NSMutableArray<NSString *> *_errs;
  BOOL _refreshPending, _stopped;
  CMMotionManager *_motion;
  AVSpeechSynthesizer *_speech;
  AVAudioEngine *_audio;
  AVAudioPlayerNode *_player;
  AVAudioFormat *_toneFormat;
  NSArray *_persistKeys;
  NSMutableDictionary *_persistLast;
  UIViewController *_root;
  UITabBarController *_tabs;
  UINavigationController *_nav;
  NSArray *_tabIds;
  UIColor *_tint, *_bg, *_text;
  NSString *_design;
  JSValue *_fEval, *_fRun, *_fCompE, *_fCompA, *_fTpl, *_fList, *_fListItem, *_fSet, *_fTimer, *_fCb, *_fMotion, *_fPersist;
}

+ (NSString *)preludeSource {
  static NSString *src;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *p = [[NSBundle mainBundle] pathForResource:@"AFEnginePrelude" ofType:@"js"];
    src = p ? [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!src) src = @"var __PRELUDE_MISSING = true;";
  });
  return src;
}

+ (UIColor *)colorFromString:(NSString *)s {
  if (![s isKindOfClass:NSString.class] || !s.length) return nil;
  NSString *t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if ([t hasPrefix:@"#"]) {
    NSString *h = [t substringFromIndex:1];
    if (h.length == 3) h = [NSString stringWithFormat:@"%C%C%C%C%C%C", [h characterAtIndex:0], [h characterAtIndex:0],
                            [h characterAtIndex:1], [h characterAtIndex:1], [h characterAtIndex:2], [h characterAtIndex:2]];
    unsigned int v = 0;
    if (![[NSScanner scannerWithString:h] scanHexInt:&v]) return nil;
    if (h.length == 6) return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
    if (h.length == 8) return [UIColor colorWithRed:((v >> 24) & 255) / 255.0 green:((v >> 16) & 255) / 255.0 blue:((v >> 8) & 255) / 255.0 alpha:(v & 255) / 255.0];
    return nil;
  }
  NSString *l = t.lowercaseString;
  if ([l hasPrefix:@"rgb"]) {
    NSRange a = [t rangeOfString:@"("], b = [t rangeOfString:@")"];
    if (a.location == NSNotFound || b.location == NSNotFound || b.location < a.location) return nil;
    NSArray *parts = [[t substringWithRange:NSMakeRange(a.location + 1, b.location - a.location - 1)] componentsSeparatedByString:@","];
    if (parts.count < 3) return nil;
    double al = parts.count > 3 ? [parts[3] doubleValue] : 1;
    return [UIColor colorWithRed:[parts[0] doubleValue] / 255.0 green:[parts[1] doubleValue] / 255.0 blue:[parts[2] doubleValue] / 255.0 alpha:al];
  }
  NSDictionary *names = @{
    @"red": UIColor.systemRedColor, @"green": UIColor.systemGreenColor, @"blue": UIColor.systemBlueColor,
    @"orange": UIColor.systemOrangeColor, @"yellow": UIColor.systemYellowColor, @"pink": UIColor.systemPinkColor,
    @"purple": UIColor.systemPurpleColor, @"teal": UIColor.systemTealColor, @"indigo": UIColor.systemIndigoColor,
    @"brown": [UIColor colorWithRed:0.64 green:0.52 blue:0.37 alpha:1], @"gray": UIColor.systemGrayColor, @"grey": UIColor.systemGrayColor,
    @"mint": [UIColor colorWithRed:0 green:0.78 blue:0.75 alpha:1], @"cyan": [UIColor colorWithRed:0.2 green:0.68 blue:0.9 alpha:1],
    @"black": UIColor.blackColor, @"white": UIColor.whiteColor, @"clear": UIColor.clearColor, @"transparent": UIColor.clearColor,
    @"label": UIColor.labelColor, @"secondary": UIColor.secondaryLabelColor, @"background": UIColor.systemBackgroundColor,
    @"secondarybackground": UIColor.secondarySystemBackgroundColor, @"groupedbackground": UIColor.systemGroupedBackgroundColor,
    @"tint": UIColor.systemBlueColor, @"accent": UIColor.systemBlueColor, @"separator": UIColor.separatorColor,
  };
  UIColor *c = names[l];
  if (c) return c;
  if ([t hasPrefix:@"system"]) {
    SEL sel = NSSelectorFromString([t stringByAppendingString:@"Color"]);
    if ([UIColor respondsToSelector:sel]) {
      UIColor *(*f)(id, SEL) = (UIColor *(*)(id, SEL))[UIColor methodForSelector:sel];
      return f(UIColor.class, sel);
    }
  }
  return nil;
}

+ (NSArray<NSString *> *)checkSpecJSON:(NSString *)json {
  if (!json.length) return @[ @"Spec gol." ];
  NSError *pe = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&pe];
  if (![obj isKindOfClass:NSDictionary.class])
    return @[ [NSString stringWithFormat:@"JSON invalid: %@", pe.localizedDescription ?: @"nu e un obiect"] ];
  NSMutableArray *errs = [NSMutableArray new];
  JSContext *ctx = [JSContext new];
  ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
    @synchronized (errs) { [errs addObject:[NSString stringWithFormat:@"JS: %@", [e toString]]]; }
  };
  [ctx evaluateScript:@"var __native = new Proxy({}, { get: function (t, k) { return k === 'storeGet' ? function () { return ''; } : function () { return null; }; } });"];
  [ctx evaluateScript:[self preludeSource]];
  NSArray *v = [[ctx[@"__validate"] callWithArguments:@[ json ]] toArray];
  for (id e in v) if ([e isKindOfClass:NSString.class] && ![errs containsObject:e]) [errs addObject:e];
  if (!errs.count) {
    NSArray *r = [[ctx[@"__dryRun"] callWithArguments:@[ json ]] toArray];
    for (id e in r) if ([e isKindOfClass:NSString.class] && ![errs containsObject:e]) [errs addObject:e];
  }
  return errs;
}

- (instancetype)initWithSpecJSON:(NSString *)json storePrefix:(NSString *)prefix {
  if ((self = [super init])) {
    _json = json.length ? json : @"{}";
    _prefix = prefix.length ? prefix : @"af.";
    id obj = [NSJSONSerialization JSONObjectWithData:[_json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    _spec = [obj isKindOfClass:NSDictionary.class] ? obj : @{};
    _screens = [NSHashTable weakObjectsHashTable];
    _timers = [NSMutableDictionary new];
    _exprCache = [NSMutableDictionary new];
    _actionCache = [NSMutableDictionary new];
    _errs = [NSMutableArray new];
    _persistLast = [NSMutableDictionary new];
    NSDictionary *theme = [_spec[@"theme"] isKindOfClass:NSDictionary.class] ? _spec[@"theme"] : @{};
    _tint = [AFEngine colorFromString:AFEStr(theme[@"tint"])] ?: UIColor.systemBlueColor;
    _bg = [AFEngine colorFromString:AFEStr(theme[@"background"])];
    _text = [AFEngine colorFromString:AFEStr(theme[@"text"])];
    _design = AFEStr(theme[@"font"]);
    NSMutableArray *pk = [NSMutableArray new];
    if ([_spec[@"persist"] isKindOfClass:NSArray.class]) for (id k in _spec[@"persist"]) if (AFEStr(k).length) [pk addObject:AFEStr(k)];
    _persistKeys = pk;
    [self setupContext];
    [self bootJS];
    _root = [self buildRoot];
  }
  return self;
}

- (NSArray<NSString *> *)errors { return [_errs copy]; }
- (UIViewController *)rootViewController { return _root; }

- (void)reportError:(NSString *)m {
  if (!m.length) return;
  if ([_errs containsObject:m]) return;
  if (_errs.count < 50) [_errs addObject:m];
  NSLog(@"[AFEngine] %@", m);
  void (^cb)(NSString *) = self.onError;
  if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(m); });
}

- (void)setupContext {
  _ctx = [JSContext new];
  __weak AFEngine *w = self;
  _ctx.exceptionHandler = ^(JSContext *c, JSValue *e) { [w reportError:[NSString stringWithFormat:@"JS: %@", [e toString]]]; };
  JSValue *n = [JSValue valueWithNewObjectInContext:_ctx];
  n[@"error"] = ^(NSString *m) { [w reportError:m]; };
  n[@"refresh"] = ^{ [w setNeedsRefresh]; };
  n[@"log"] = ^(NSString *m) { AFEngine *s = w; NSLog(@"[app] %@", m); if (s.onLog) s.onLog(m); };
  n[@"timer"] = ^(double tid, double ms, BOOL rep) { [w addTimer:(NSInteger)tid ms:ms repeat:rep]; };
  n[@"cancelTimer"] = ^(double tid) { [w cancelTimer:(NSInteger)tid]; };
  n[@"go"] = ^(NSString *sid) { [w go:sid]; };
  n[@"back"] = ^{ [w back]; };
  n[@"alert"] = ^(NSString *t, NSString *m) { [w alert:t message:m]; };
  n[@"confirm"] = ^(NSString *t, NSString *m, double cb) { [w confirm:t message:m cb:(NSInteger)cb]; };
  n[@"ask"] = ^(NSString *t, NSString *m, NSString *d, double cb) { [w ask:t message:m def:d cb:(NSInteger)cb]; };
  n[@"haptic"] = ^(NSString *k) { [w haptic:k]; };
  n[@"sound"] = ^(NSString *k) { [w sound:k]; };
  n[@"tone"] = ^(double f, double ms, double vol) { [w toneFreq:f ms:ms volume:vol]; };
  n[@"speak"] = ^(NSString *t, NSString *lang) { [w speak:t lang:lang]; };
  n[@"toast"] = ^(NSString *t) { [w toast:t]; };
  n[@"share"] = ^(NSString *t) { [w share:t]; };
  n[@"copy"] = ^(NSString *t) { UIPasteboard.generalPasteboard.string = t ?: @""; };
  n[@"open"] = ^(NSString *u) {
    NSURL *url = [NSURL URLWithString:u ?: @""];
    if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
  };
  n[@"storeGet"] = ^NSString *(NSString *k) {
    AFEngine *s = w;
    return s ? ([NSUserDefaults.standardUserDefaults stringForKey:[s->_prefix stringByAppendingFormat:@"store.%@", k]] ?: @"") : @"";
  };
  n[@"storeSet"] = ^(NSString *k, NSString *v) {
    AFEngine *s = w; if (!s) return;
    NSString *key = [s->_prefix stringByAppendingFormat:@"store.%@", k];
    if (v.length) [NSUserDefaults.standardUserDefaults setObject:v forKey:key];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
  };
  n[@"motionStart"] = ^(double hz) { [w motionStart:hz]; };
  n[@"motionStop"] = ^{ [w motionStop]; };
  _ctx[@"__native"] = n;
  [_ctx evaluateScript:[AFEngine preludeSource] withSourceURL:[NSURL URLWithString:@"appforge://prelude.js"]];
  CGSize sz = UIScreen.mainScreen.bounds.size;
  _ctx[@"screen"] = @{ @"width": @(sz.width), @"height": @(sz.height) };
  _fEval = _ctx[@"__evalExpr"]; _fRun = _ctx[@"__runAction"];
  _fCompE = _ctx[@"__compileExpr"]; _fCompA = _ctx[@"__compileAction"];
  _fTpl = _ctx[@"__template"]; _fList = _ctx[@"__listItems"]; _fListItem = _ctx[@"__listItem"];
  _fSet = _ctx[@"__setPath"]; _fTimer = _ctx[@"__fireTimer"]; _fCb = _ctx[@"__fireCb"];
  _fMotion = _ctx[@"__motion"]; _fPersist = _ctx[@"__persistJSON"];
}

- (void)bootJS {
  NSMutableDictionary *saved = [NSMutableDictionary new];
  for (NSString *k in _persistKeys) {
    NSString *s = [NSUserDefaults.standardUserDefaults stringForKey:[_prefix stringByAppendingFormat:@"state.%@", k]];
    if (s.length) { saved[k] = s; _persistLast[k] = s; }
  }
  [_ctx[@"__boot"] callWithArguments:@[ _json, saved ]];
}

- (JSValue *)null { return [JSValue valueWithNullInContext:_ctx]; }

- (NSInteger)compileExpr:(NSString *)src {
  NSNumber *c = _exprCache[src];
  if (c) return c.integerValue;
  NSInteger i = [[_fCompE callWithArguments:@[ src ]] toInt32];
  _exprCache[src] = @(i);
  return i;
}
- (NSInteger)compileAction:(NSString *)src {
  NSNumber *c = _actionCache[src];
  if (c) return c.integerValue;
  NSInteger i = [[_fCompA callWithArguments:@[ src ]] toInt32];
  _actionCache[src] = @(i);
  return i;
}
- (NSString *)templateExpr:(NSString *)s {
  JSValue *v = [_fTpl callWithArguments:@[ s ]];
  return v.isString ? [v toString] : nil;
}
- (JSValue *)evalExpr:(NSInteger)i item:(JSValue *)item index:(NSInteger)idx {
  return [_fEval callWithArguments:@[ @(i), item ?: [self null], @(idx) ]];
}
- (void)runActionIndex:(NSInteger)a item:(JSValue *)item index:(NSInteger)index value:(id)value {
  if (_stopped || a < 0) return;
  [_fRun callWithArguments:@[ @(a), item ?: [self null], @(index), value ?: [self null] ]];
}
- (void)runActionSource:(NSString *)src item:(JSValue *)item index:(NSInteger)index value:(id)value {
  if (!src.length) return;
  [self runActionIndex:[self compileAction:src] item:item index:index value:value];
}
- (void)setBind:(NSString *)key value:(id)value {
  [_fSet callWithArguments:@[ key, value ?: [NSNull null] ]];
}

#pragma mark refresh

- (void)setNeedsRefresh {
  if (_refreshPending || _stopped) return;
  _refreshPending = YES;
  dispatch_async(dispatch_get_main_queue(), ^{ [self refreshNow]; });
}
- (void)refreshNow {
  _refreshPending = NO;
  if (_stopped) return;
  for (AFEScreenVC *vc in _screens.allObjects) if (vc.scope) [self refreshScope:vc.scope];
  [self persist];
}
- (void)refreshScope:(AFEScope *)sc {
  for (AFEList *l in [sc.lists copy]) [self refreshList:l];
  for (AFEBinding *b in [sc.bindings copy]) [self applyBinding:b initial:NO];
  for (AFEList *l in [sc.lists copy]) [self refreshScope:l.scope];
}
- (void)persist {
  if (!_persistKeys.count) return;
  NSDictionary *d = [[_fPersist callWithArguments:@[ _persistKeys ]] toDictionary];
  for (NSString *k in _persistKeys) {
    NSString *v = AFEStr(d[k]);
    if (!v || [v isEqualToString:_persistLast[k]]) continue;
    _persistLast[k] = v;
    [NSUserDefaults.standardUserDefaults setObject:v forKey:[_prefix stringByAppendingFormat:@"state.%@", k]];
  }
}

static NSSet *AFESet(NSArray *a) { return [NSSet setWithArray:a]; }

- (void)applyBinding:(AFEBinding *)b initial:(BOOL)initial {
  UIView *v = b.view;
  if (!v && !b.vc) return;
  static NSSet *boolP, *numP;
  static dispatch_once_t o;
  dispatch_once(&o, ^{
    boolP = AFESet(@[ @"visible", @"enabled" ]);
    numP = AFESet(@[ @"opacity", @"radius", @"width", @"height", @"x", @"y", @"rotation", @"scale", @"size", @"value", @"borderWidth" ]);
  });
  JSValue *r = [self evalExpr:b.expr item:b.item index:b.index];
  id val;
  if ([b.prop isEqualToString:@"__bind"]) {
    val = (r.isNull || r.isUndefined) ? [NSNull null] : ([r toObject] ?: [NSNull null]);
  } else if ([boolP containsObject:b.prop]) {
    val = @([r toBool]);
  } else if ([numP containsObject:b.prop]) {
    if (r.isNull || r.isUndefined) return;
    double d = [r toDouble];
    if (isnan(d)) return;
    val = @(d);
  } else {
    val = (r.isNull || r.isUndefined) ? @"" : ([r toString] ?: @"");
  }
  if (!initial && b.last && [b.last isEqual:val]) return;
  b.last = val;
  if ([b.prop isEqualToString:@"__title"]) { b.vc.title = AFEStr(val); return; }
  NSDictionary *node = objc_getAssociatedObject(v, &kAFENodeKey);
  if (!initial && AFEBool(node[@"animate"], NO)) {
    [UIView animateWithDuration:0.25 animations:^{ [self apply:b.prop value:val view:v]; [v.superview layoutIfNeeded]; }];
  } else {
    [self apply:b.prop value:val view:v];
  }
}

- (void)bindProp:(NSString *)prop expr:(NSString *)expr view:(UIView *)v item:(JSValue *)item index:(NSInteger)idx scope:(AFEScope *)scope {
  AFEBinding *b = [AFEBinding new];
  b.view = v; b.prop = prop; b.expr = [self compileExpr:expr]; b.item = item; b.index = idx;
  [scope.bindings addObject:b];
  [self applyBinding:b initial:YES];
}

- (UIView *)controlOf:(UIView *)v { return objc_getAssociatedObject(v, &kAFEControlKey) ?: v; }

- (void)setDim:(NSString *)key value:(CGFloat)c view:(UIView *)v {
  BOOL abs = [objc_getAssociatedObject(v, &kAFEAbsKey) boolValue];
  BOOL isW = [key isEqualToString:@"width"];
  if (abs) {
    CGAffineTransform t = v.transform; v.transform = CGAffineTransformIdentity;
    CGRect f = v.frame;
    if (isW) f.size.width = c; else f.size.height = c;
    v.frame = f; v.transform = t;
    return;
  }
  char *k = isW ? &kAFEWKey : &kAFEHKey;
  NSLayoutConstraint *lc = objc_getAssociatedObject(v, k);
  if (!lc) {
    lc = isW ? [v.widthAnchor constraintEqualToConstant:c] : [v.heightAnchor constraintEqualToConstant:c];
    lc.priority = 999;
    lc.active = YES;
    objc_setAssociatedObject(v, k, lc, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  lc.constant = MAX(0, c);
}

- (void)updateTransform:(UIView *)v {
  double rot = [objc_getAssociatedObject(v, &kAFERotKey) doubleValue];
  NSNumber *sc = objc_getAssociatedObject(v, &kAFEScaleKey);
  double s = sc ? sc.doubleValue : 1;
  v.transform = CGAffineTransformScale(CGAffineTransformMakeRotation(rot * M_PI / 180.0), s, s);
}

- (UIImage *)symbol:(NSString *)name node:(NSDictionary *)node {
  if (!name.length) return nil;
  CGFloat size = AFENum(node[@"size"], [AFEType(node[@"type"]) isEqualToString:@"image"] ? 28 : 17);
  UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
  return [UIImage systemImageNamed:name withConfiguration:cfg];
}

- (void)apply:(NSString *)p value:(id)val view:(UIView *)v {
  if (!v) return;
  NSDictionary *node = objc_getAssociatedObject(v, &kAFENodeKey);
  UIView *c = [self controlOf:v];
  NSString *s = AFEStr(val);
  if ([p isEqualToString:@"text"] || [p isEqualToString:@"title"]) {
    if ([c isKindOfClass:UIButton.class]) [(UIButton *)c setTitle:s forState:UIControlStateNormal];
    else if ([c isKindOfClass:UILabel.class]) ((UILabel *)c).text = s;
    else { UILabel *l = objc_getAssociatedObject(v, &kAFELabelKey); l.text = s; }
  } else if ([p isEqualToString:@"label"]) {
    UILabel *l = objc_getAssociatedObject(v, &kAFELabelKey); l.text = s;
  } else if ([p isEqualToString:@"color"]) {
    UIColor *col = [AFEngine colorFromString:s];
    if (!col) return;
    if ([c isKindOfClass:UIButton.class]) { [(UIButton *)c setTitleColor:col forState:UIControlStateNormal]; c.tintColor = col; }
    else if ([c isKindOfClass:UILabel.class]) ((UILabel *)c).textColor = col;
    else if ([c isKindOfClass:UITextField.class]) ((UITextField *)c).textColor = col;
    else if ([c isKindOfClass:UITextView.class]) ((UITextView *)c).textColor = col;
    else if ([c isKindOfClass:UISwitch.class]) ((UISwitch *)c).onTintColor = col;
    else if ([c isKindOfClass:UISlider.class]) ((UISlider *)c).minimumTrackTintColor = col;
    else if ([c isKindOfClass:UIProgressView.class]) ((UIProgressView *)c).progressTintColor = col;
    else if ([c isKindOfClass:UISegmentedControl.class]) ((UISegmentedControl *)c).selectedSegmentTintColor = col;
    else c.tintColor = col;
    UILabel *l = objc_getAssociatedObject(v, &kAFELabelKey);
    if (l && l != c) l.textColor = col;
  } else if ([p isEqualToString:@"background"]) {
    v.backgroundColor = [AFEngine colorFromString:s];
  } else if ([p isEqualToString:@"tint"]) {
    c.tintColor = [AFEngine colorFromString:s];
  } else if ([p isEqualToString:@"sf"]) {
    UIImage *img = [self symbol:s node:node];
    if ([c isKindOfClass:UIImageView.class]) ((UIImageView *)c).image = img;
    else if ([c isKindOfClass:UIButton.class]) [(UIButton *)c setImage:img forState:UIControlStateNormal];
  } else if ([p isEqualToString:@"src"]) {
    if (![c isKindOfClass:UIImageView.class] || !s.length) return;
    UIImageView *iv = (UIImageView *)c;
    if ([s hasPrefix:@"data:"]) {
      NSRange comma = [s rangeOfString:@","];
      NSData *d = comma.location != NSNotFound ? [[NSData alloc] initWithBase64EncodedString:[s substringFromIndex:comma.location + 1] options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
      iv.image = d ? [UIImage imageWithData:d] : nil;
      return;
    }
    NSURL *u = [NSURL URLWithString:s];
    if (!u) return;
    __weak UIImageView *wiv = iv;
    [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
      UIImage *img = d ? [UIImage imageWithData:d] : nil;
      if (img) dispatch_async(dispatch_get_main_queue(), ^{ wiv.image = img; });
    }] resume];
  } else if ([p isEqualToString:@"opacity"]) {
    v.alpha = [val doubleValue];
  } else if ([p isEqualToString:@"radius"]) {
    v.layer.cornerRadius = [val doubleValue];
    if (!AFEBool(node[@"shadow"], NO)) v.clipsToBounds = YES;
  } else if ([p isEqualToString:@"width"] || [p isEqualToString:@"height"]) {
    if (AFEIsNum(val)) [self setDim:p value:[val doubleValue] view:v];
  } else if ([p isEqualToString:@"placeholder"]) {
    if ([c isKindOfClass:UITextField.class]) ((UITextField *)c).placeholder = s;
  } else if ([p isEqualToString:@"borderColor"]) {
    v.layer.borderColor = [AFEngine colorFromString:s].CGColor;
    if (v.layer.borderWidth == 0) v.layer.borderWidth = 1;
  } else if ([p isEqualToString:@"borderWidth"]) {
    v.layer.borderWidth = [val doubleValue];
  } else if ([p isEqualToString:@"visible"]) {
    v.hidden = ![val boolValue];
  } else if ([p isEqualToString:@"enabled"]) {
    BOOL on = [val boolValue];
    if ([c isKindOfClass:UIControl.class]) ((UIControl *)c).enabled = on;
    else c.userInteractionEnabled = on;
    v.alpha = on ? AFENum(node[@"opacity"], 1) : 0.45;
  } else if ([p isEqualToString:@"value"]) {
    if ([c isKindOfClass:UIProgressView.class]) [(UIProgressView *)c setProgress:(float)MAX(0, MIN(1, [val doubleValue])) animated:NO];
  } else if ([p isEqualToString:@"x"] || [p isEqualToString:@"y"]) {
    if (![objc_getAssociatedObject(v, &kAFEAbsKey) boolValue]) return;
    CGAffineTransform t = v.transform; v.transform = CGAffineTransformIdentity;
    CGRect f = v.frame;
    if ([p isEqualToString:@"x"]) f.origin.x = [val doubleValue]; else f.origin.y = [val doubleValue];
    v.frame = f; v.transform = t;
  } else if ([p isEqualToString:@"rotation"]) {
    objc_setAssociatedObject(v, &kAFERotKey, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [self updateTransform:v];
  } else if ([p isEqualToString:@"scale"]) {
    objc_setAssociatedObject(v, &kAFEScaleKey, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC); [self updateTransform:v];
  } else if ([p isEqualToString:@"size"]) {
    if ([c isKindOfClass:UILabel.class]) ((UILabel *)c).font = [((UILabel *)c).font fontWithSize:[val doubleValue]];
    else if ([c isKindOfClass:UIButton.class]) ((UIButton *)c).titleLabel.font = [((UIButton *)c).titleLabel.font fontWithSize:[val doubleValue]];
  } else if ([p isEqualToString:@"__bind"]) {
    if ([c isKindOfClass:UISwitch.class]) ((UISwitch *)c).on = AFEBool(val, NO);
    else if ([c isKindOfClass:UISlider.class]) ((UISlider *)c).value = (float)AFENum(val, ((UISlider *)c).value);
    else if ([c isKindOfClass:UIStepper.class]) ((UIStepper *)c).value = AFENum(val, ((UIStepper *)c).value);
    else if ([c isKindOfClass:UISegmentedControl.class]) {
      UISegmentedControl *sg = (UISegmentedControl *)c;
      if ([val isKindOfClass:NSNumber.class]) sg.selectedSegmentIndex = [val integerValue];
      else {
        NSArray *opts = node[@"options"];
        NSUInteger i = [opts isKindOfClass:NSArray.class] ? [opts indexOfObject:AFEStr(val) ?: @""] : NSNotFound;
        sg.selectedSegmentIndex = i == NSNotFound ? UISegmentedControlNoSegment : (NSInteger)i;
      }
    } else if ([c isKindOfClass:UITextField.class]) {
      UITextField *tf = (UITextField *)c;
      NSString *nv = [val isKindOfClass:NSNull.class] ? @"" : (AFEStr(val) ?: @"");
      if (!tf.isFirstResponder && ![tf.text isEqualToString:nv]) tf.text = nv;
    } else if ([c isKindOfClass:UITextView.class]) {
      UITextView *tv = (UITextView *)c;
      NSString *nv = [val isKindOfClass:NSNull.class] ? @"" : (AFEStr(val) ?: @"");
      if (!tv.isFirstResponder && ![tv.text isEqualToString:nv]) tv.text = nv;
    }
  }
}

- (id)valueOfControl:(UIView *)c {
  if ([c isKindOfClass:UISwitch.class]) return @(((UISwitch *)c).isOn);
  if ([c isKindOfClass:UISlider.class]) return @(((UISlider *)c).value);
  if ([c isKindOfClass:UIStepper.class]) return @(((UIStepper *)c).value);
  if ([c isKindOfClass:UITextField.class]) return ((UITextField *)c).text ?: @"";
  if ([c isKindOfClass:UITextView.class]) return ((UITextView *)c).text ?: @"";
  if ([c isKindOfClass:UISegmentedControl.class]) {
    UISegmentedControl *sg = (UISegmentedControl *)c;
    NSDictionary *node = objc_getAssociatedObject(c, &kAFENodeKey);
    NSArray *opts = node[@"options"];
    NSString *bind = AFEStr(node[@"bind"]);
    JSValue *cur = bind.length ? [_ctx[@"__getPath"] callWithArguments:@[ bind ]] : nil;
    if (cur.isNumber || ![opts isKindOfClass:NSArray.class]) return @(sg.selectedSegmentIndex);
    NSInteger i = sg.selectedSegmentIndex;
    return (i >= 0 && i < (NSInteger)opts.count) ? (AFEStr(opts[i]) ?: @"") : @"";
  }
  return [NSNull null];
}

#pragma mark build

- (void)addTarget:(AFEAction *)a toView:(UIView *)v {
  NSMutableArray *arr = objc_getAssociatedObject(v, &kAFETargetsKey);
  if (!arr) { arr = [NSMutableArray new]; objc_setAssociatedObject(v, &kAFETargetsKey, arr, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
  [arr addObject:a];
}
- (AFEAction *)actionFor:(NSString *)src item:(JSValue *)item index:(NSInteger)idx {
  AFEAction *a = [AFEAction new];
  a.engine = self; a.item = item; a.index = idx;
  a.action = src.length ? [self compileAction:src] : -1;
  return a;
}

- (UIFont *)fontFor:(NSDictionary *)n base:(CGFloat)base weight:(UIFontWeight)defW {
  NSDictionary *styles = @{ @"largetitle": UIFontTextStyleLargeTitle, @"title": UIFontTextStyleTitle1, @"title1": UIFontTextStyleTitle1,
    @"title2": UIFontTextStyleTitle2, @"title3": UIFontTextStyleTitle3, @"headline": UIFontTextStyleHeadline,
    @"subheadline": UIFontTextStyleSubheadline, @"body": UIFontTextStyleBody, @"callout": UIFontTextStyleCallout,
    @"footnote": UIFontTextStyleFootnote, @"caption": UIFontTextStyleCaption1, @"caption2": UIFontTextStyleCaption2 };
  NSString *st = AFEStr(n[@"font"]).lowercaseString;
  CGFloat size = AFENum(n[@"size"], 0);
  NSString *wn = AFEStr(n[@"weight"]);
  if (AFEBool(n[@"bold"], NO)) wn = @"bold";
  UIFontWeight w = wn.length ? AFEWeight(wn) : defW;
  UIFont *f;
  if (st.length && styles[st]) {
    UIFont *pf = [UIFont preferredFontForTextStyle:styles[st]];
    BOOL big = [st containsString:@"title"] || [st isEqualToString:@"headline"];
    f = [UIFont systemFontOfSize:size > 0 ? size : pf.pointSize weight:wn.length ? w : (big ? UIFontWeightBold : UIFontWeightRegular)];
  } else {
    f = [UIFont systemFontOfSize:size > 0 ? size : base weight:w];
  }
  if (AFEBool(n[@"monoDigits"], NO)) f = [UIFont monospacedDigitSystemFontOfSize:f.pointSize weight:w];
  NSString *design = (AFEStr(n[@"design"]) ?: _design).lowercaseString;
  UIFontDescriptorSystemDesign d = nil;
  if ([design isEqualToString:@"rounded"]) d = UIFontDescriptorSystemDesignRounded;
  else if ([design hasPrefix:@"mono"]) d = UIFontDescriptorSystemDesignMonospaced;
  else if ([design isEqualToString:@"serif"]) d = UIFontDescriptorSystemDesignSerif;
  if (d) {
    UIFontDescriptor *fd = [f.fontDescriptor fontDescriptorWithDesign:d];
    if (fd) f = [UIFont fontWithDescriptor:fd size:f.pointSize];
  }
  return f;
}

- (UIStackView *)stackAxis:(UILayoutConstraintAxis)axis node:(NSDictionary *)n {
  UIStackView *st = [UIStackView new];
  st.axis = axis;
  st.spacing = AFENum(n[@"spacing"], axis == UILayoutConstraintAxisVertical ? 12 : 8);
  NSString *al = AFEStr(n[@"align"]).lowercaseString ?: @"";
  if (axis == UILayoutConstraintAxisVertical) {
    st.alignment = [al isEqualToString:@"center"] ? UIStackViewAlignmentCenter :
      ([al isEqualToString:@"leading"] || [al isEqualToString:@"left"] || [al isEqualToString:@"start"]) ? UIStackViewAlignmentLeading :
      ([al isEqualToString:@"trailing"] || [al isEqualToString:@"right"] || [al isEqualToString:@"end"]) ? UIStackViewAlignmentTrailing : UIStackViewAlignmentFill;
  } else {
    st.alignment = ([al isEqualToString:@"top"] || [al isEqualToString:@"start"]) ? UIStackViewAlignmentTop :
      ([al isEqualToString:@"bottom"] || [al isEqualToString:@"end"]) ? UIStackViewAlignmentBottom :
      [al isEqualToString:@"fill"] ? UIStackViewAlignmentFill : UIStackViewAlignmentCenter;
  }
  NSString *ds = AFEStr(n[@"distribution"]).lowercaseString ?: @"";
  st.distribution = ([ds isEqualToString:@"equal"] || [ds isEqualToString:@"fillequally"]) ? UIStackViewDistributionFillEqually :
    ([ds isEqualToString:@"spaced"] || [ds isEqualToString:@"equalspacing"] || [ds isEqualToString:@"between"]) ? UIStackViewDistributionEqualSpacing :
    [ds isEqualToString:@"centering"] ? UIStackViewDistributionEqualCentering : UIStackViewDistributionFill;
  if (n[@"padding"]) {
    st.layoutMargins = AFEInsets(n[@"padding"]);
    st.layoutMarginsRelativeArrangement = YES;
  }
  return st;
}

- (void)pin:(UIView *)v in:(UIView *)p insets:(UIEdgeInsets)i {
  v.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [v.topAnchor constraintEqualToAnchor:p.topAnchor constant:i.top],
    [v.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:i.left],
    [v.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-i.right],
    [v.bottomAnchor constraintEqualToAnchor:p.bottomAnchor constant:-i.bottom],
  ]];
}

- (UIView *)labeled:(UIView *)control node:(NSDictionary *)n {
  if (!n[@"label"]) return control;
  UIStackView *h = [UIStackView new];
  h.axis = UILayoutConstraintAxisHorizontal; h.spacing = 12; h.alignment = UIStackViewAlignmentCenter;
  AFELabel *l = [AFELabel new];
  l.font = [self fontFor:@{} base:17 weight:UIFontWeightRegular];
  l.textColor = _text ?: UIColor.labelColor;
  l.numberOfLines = 0;
  [h addArrangedSubview:l];
  if ([control isKindOfClass:UISlider.class]) {
    [control setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
  } else {
    [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIView *sp = [UIView new];
    [sp setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [h addArrangedSubview:sp];
  }
  [h addArrangedSubview:control];
  objc_setAssociatedObject(h, &kAFELabelKey, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return h;
}

- (NSArray *)kids:(NSDictionary *)n { return [n[@"children"] isKindOfClass:NSArray.class] ? n[@"children"] : @[]; }

- (AFEAction *)controlAction:(NSDictionary *)n control:(UIView *)c item:(JSValue *)item index:(NSInteger)idx event:(UIControlEvents)ev {
  AFEAction *a = [self actionFor:AFEStr(n[@"onChange"]) item:item index:idx];
  a.bind = AFEStr(n[@"bind"]); a.control = c;
  if ([c isKindOfClass:UIControl.class]) [(UIControl *)c addTarget:a action:@selector(fire:) forControlEvents:ev];
  [self addTarget:a toView:c];
  return a;
}

- (UIView *)buildNode:(NSDictionary *)n item:(JSValue *)item index:(NSInteger)idx scope:(AFEScope *)scope axis:(NSInteger)axis abs:(BOOL)abs {
  if (![n isKindOfClass:NSDictionary.class]) return [UIView new];
  NSString *t = AFEType(n[@"type"]);
  UIView *v = nil, *control = nil;
  if ([t isEqualToString:@"vstack"] || [t isEqualToString:@"hstack"]) {
    BOOL h = [t isEqualToString:@"hstack"];
    UIStackView *st = [self stackAxis:h ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical node:n];
    for (id ch in [self kids:n]) [st addArrangedSubview:[self buildNode:ch item:item index:idx scope:scope axis:h ? 1 : 0 abs:NO]];
    v = st;
  } else if ([t isEqualToString:@"zstack"]) {
    UIView *z = [UIView new];
    UIEdgeInsets pad = AFEInsets(n[@"padding"]);
    for (id ch in [self kids:n]) {
      UIView *cv = [self buildNode:ch item:item index:idx scope:scope axis:0 abs:NO];
      [z addSubview:cv];
      if ([ch isKindOfClass:NSDictionary.class] && AFEBool(ch[@"fill"], NO)) [self pin:cv in:z insets:pad];
      else {
        cv.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
          [cv.centerXAnchor constraintEqualToAnchor:z.centerXAnchor], [cv.centerYAnchor constraintEqualToAnchor:z.centerYAnchor],
          [cv.topAnchor constraintGreaterThanOrEqualToAnchor:z.topAnchor constant:pad.top],
          [cv.leadingAnchor constraintGreaterThanOrEqualToAnchor:z.leadingAnchor constant:pad.left],
          [cv.trailingAnchor constraintLessThanOrEqualToAnchor:z.trailingAnchor constant:-pad.right],
          [cv.bottomAnchor constraintLessThanOrEqualToAnchor:z.bottomAnchor constant:-pad.bottom],
        ]];
      }
    }
    v = z;
  } else if ([t isEqualToString:@"grid"]) {
    NSInteger cols = MAX(1, (NSInteger)AFENum(n[@"columns"], 3));
    UIStackView *st = [self stackAxis:UILayoutConstraintAxisVertical node:n];
    st.alignment = UIStackViewAlignmentFill;
    NSArray *kids = [self kids:n];
    for (NSUInteger i = 0; i < kids.count; i += cols) {
      UIStackView *row = [UIStackView new];
      row.axis = UILayoutConstraintAxisHorizontal; row.distribution = UIStackViewDistributionFillEqually;
      row.spacing = AFENum(n[@"spacing"], 12); row.alignment = UIStackViewAlignmentFill;
      for (NSUInteger j = i; j < i + cols; j++)
        [row addArrangedSubview:j < kids.count ? [self buildNode:kids[j] item:item index:idx scope:scope axis:1 abs:NO] : [UIView new]];
      [st addArrangedSubview:row];
    }
    v = st;
  } else if ([t isEqualToString:@"scroll"]) {
    UIScrollView *sc = [UIScrollView new];
    BOOL horiz = [AFEStr(n[@"axis"]) isEqualToString:@"horizontal"];
    UIStackView *st = [self stackAxis:horiz ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical node:n];
    for (id ch in [self kids:n]) [st addArrangedSubview:[self buildNode:ch item:item index:idx scope:scope axis:horiz ? 1 : 0 abs:NO]];
    [sc addSubview:st];
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [st.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor],
      [st.leadingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.leadingAnchor],
      [st.trailingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.trailingAnchor],
      [st.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor],
      horiz ? [st.heightAnchor constraintEqualToAnchor:sc.frameLayoutGuide.heightAnchor]
            : [st.widthAnchor constraintEqualToAnchor:sc.frameLayoutGuide.widthAnchor],
    ]];
    sc.alwaysBounceVertical = !horiz;
    sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    NSLayoutConstraint *hc = horiz ? [sc.heightAnchor constraintEqualToAnchor:st.heightAnchor] : [sc.heightAnchor constraintEqualToAnchor:st.heightAnchor];
    hc.priority = 250; hc.active = YES;
    v = sc;
  } else if ([t isEqualToString:@"spacer"]) {
    v = [UIView new];
    if (AFEIsNum(n[@"size"])) {
      CGFloat s = AFENum(n[@"size"], 8);
      (axis == 1 ? [v.widthAnchor constraintEqualToConstant:s] : [v.heightAnchor constraintEqualToConstant:s]).active = YES;
    } else {
      for (NSNumber *ax in @[ @(UILayoutConstraintAxisVertical), @(UILayoutConstraintAxisHorizontal) ]) {
        [v setContentHuggingPriority:1 forAxis:ax.integerValue];
        [v setContentCompressionResistancePriority:1 forAxis:ax.integerValue];
      }
    }
  } else if ([t isEqualToString:@"divider"]) {
    v = [UIView new];
    v.backgroundColor = UIColor.separatorColor;
    CGFloat th = AFENum(n[@"thickness"], 1.0 / UIScreen.mainScreen.scale);
    (axis == 1 ? [v.widthAnchor constraintEqualToConstant:th] : [v.heightAnchor constraintEqualToConstant:th]).active = YES;
  } else if ([t isEqualToString:@"text"]) {
    AFELabel *l = [AFELabel new];
    l.numberOfLines = (NSInteger)AFENum(n[@"lines"], 0);
    l.font = [self fontFor:n base:17 weight:UIFontWeightRegular];
    l.textColor = _text ?: UIColor.labelColor;
    l.adjustsFontSizeToFitWidth = AFEBool(n[@"shrink"], NO);
    l.minimumScaleFactor = 0.3;
    NSString *ta = AFEStr(n[@"textAlign"]).lowercaseString;
    l.textAlignment = [ta isEqualToString:@"center"] ? NSTextAlignmentCenter : [ta isEqualToString:@"right"] ? NSTextAlignmentRight : NSTextAlignmentNatural;
    if (n[@"padding"]) l.insets = AFEInsets(n[@"padding"]);
    v = l;
  } else if ([t isEqualToString:@"button"]) {
    AFEButton *b = [AFEButton buttonWithType:UIButtonTypeSystem];
    NSString *style = AFEStr(n[@"style"]).lowercaseString ?: @"filled";
    BOOL filled = ![style isEqualToString:@"plain"] && ![style isEqualToString:@"link"];
    b.titleLabel.font = [self fontFor:n base:17 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.5;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    if ([style isEqualToString:@"tinted"] || [style isEqualToString:@"bordered"]) {
      b.backgroundColor = [_tint colorWithAlphaComponent:0.15];
      [b setTitleColor:_tint forState:UIControlStateNormal];
    } else if (filled) {
      b.backgroundColor = _tint;
      [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
      b.tintColor = UIColor.whiteColor;
    } else {
      [b setTitleColor:_tint forState:UIControlStateNormal];
    }
    if (filled) {
      b.layer.cornerRadius = 12; b.clipsToBounds = YES;
      b.contentEdgeInsets = UIEdgeInsetsMake(12, 18, 12, 18);
      NSLayoutConstraint *mh = [b.heightAnchor constraintGreaterThanOrEqualToConstant:44]; mh.priority = 750; mh.active = YES;
    }
    if (n[@"padding"]) b.contentEdgeInsets = AFEInsets(n[@"padding"]);
    if ([style isEqualToString:@"circle"]) {
      b.circle = YES;
      [b.widthAnchor constraintEqualToAnchor:b.heightAnchor].active = YES;
    }
    if (n[@"sf"] && n[@"title"]) b.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
    AFEAction *a = [self actionFor:AFEStr(n[@"onTap"]) ?: AFEStr(n[@"action"]) item:item index:idx];
    [b addTarget:a action:@selector(fire:) forControlEvents:UIControlEventTouchUpInside];
    [self addTarget:a toView:b];
    v = b;
  } else if ([t isEqualToString:@"image"]) {
    UIImageView *iv = [UIImageView new];
    iv.contentMode = [AFEStr(n[@"mode"]) isEqualToString:@"fill"] ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
    iv.clipsToBounds = YES;
    iv.tintColor = _tint;
    v = iv;
  } else if ([t isEqualToString:@"input"]) {
    UITextField *tf = [UITextField new];
    tf.borderStyle = n[@"background"] ? UITextBorderStyleNone : UITextBorderStyleRoundedRect;
    tf.font = [self fontFor:n base:17 weight:UIFontWeightRegular];
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    NSString *kb = AFEStr(n[@"keyboard"]).lowercaseString;
    tf.keyboardType = [kb isEqualToString:@"number"] ? UIKeyboardTypeNumberPad : [kb isEqualToString:@"decimal"] ? UIKeyboardTypeDecimalPad :
      [kb isEqualToString:@"email"] ? UIKeyboardTypeEmailAddress : [kb isEqualToString:@"phone"] ? UIKeyboardTypePhonePad : UIKeyboardTypeDefault;
    tf.secureTextEntry = AFEBool(n[@"secure"], NO);
    tf.returnKeyType = UIReturnKeyDone;
    if (n[@"background"]) { tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 10)]; tf.leftViewMode = UITextFieldViewModeAlways; }
    [tf.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self controlAction:n control:tf item:item index:idx event:UIControlEventEditingChanged];
    AFEAction *sub = [self actionFor:AFEStr(n[@"onSubmit"]) item:item index:idx];
    [tf addTarget:sub action:@selector(fire:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [self addTarget:sub toView:tf];
    v = tf;
  } else if ([t isEqualToString:@"textarea"]) {
    UITextView *tv = [UITextView new];
    tv.font = [self fontFor:n base:17 weight:UIFontWeightRegular];
    tv.layer.cornerRadius = 8; tv.layer.borderWidth = 1; tv.layer.borderColor = UIColor.separatorColor.CGColor;
    tv.delegate = self;
    if (!n[@"height"]) [tv.heightAnchor constraintEqualToConstant:120].active = YES;
    [self controlAction:n control:tv item:item index:idx event:0];
    v = tv;
  } else if ([t isEqualToString:@"toggle"]) {
    UISwitch *sw = [UISwitch new];
    sw.onTintColor = _tint;
    [self controlAction:n control:sw item:item index:idx event:UIControlEventValueChanged];
    control = sw; v = [self labeled:sw node:n];
  } else if ([t isEqualToString:@"slider"]) {
    UISlider *sl = [UISlider new];
    sl.minimumValue = (float)AFENum(n[@"min"], 0); sl.maximumValue = (float)AFENum(n[@"max"], 1);
    sl.minimumTrackTintColor = _tint;
    [self controlAction:n control:sl item:item index:idx event:UIControlEventValueChanged];
    control = sl; v = [self labeled:sl node:n];
  } else if ([t isEqualToString:@"stepper"]) {
    UIStepper *sp = [UIStepper new];
    sp.minimumValue = AFENum(n[@"min"], 0); sp.maximumValue = AFENum(n[@"max"], 100); sp.stepValue = AFENum(n[@"step"], 1);
    [self controlAction:n control:sp item:item index:idx event:UIControlEventValueChanged];
    control = sp; v = [self labeled:sp node:n];
  } else if ([t isEqualToString:@"segmented"]) {
    NSMutableArray *opts = [NSMutableArray new];
    for (id o in ([n[@"options"] isKindOfClass:NSArray.class] ? n[@"options"] : @[])) [opts addObject:AFEStr(o) ?: @"?"];
    UISegmentedControl *sg = [[UISegmentedControl alloc] initWithItems:opts];
    objc_setAssociatedObject(sg, &kAFENodeKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self controlAction:n control:sg item:item index:idx event:UIControlEventValueChanged];
    v = sg;
  } else if ([t isEqualToString:@"progress"]) {
    UIProgressView *pv = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    pv.progressTintColor = _tint;
    v = pv;
  } else if ([t isEqualToString:@"list"]) {
    UIStackView *st = [self stackAxis:UILayoutConstraintAxisVertical node:n];
    if (!n[@"spacing"]) st.spacing = 8;
    AFEList *l = [AFEList new];
    l.stack = st; l.node = n; l.item = item; l.index = idx;
    l.expr = [self compileExpr:AFEStr(n[@"items"]) ?: @"[]"];
    l.scope = [AFEScope new];
    [scope.lists addObject:l];
    [self refreshList:l];
    v = st;
  } else if ([t isEqualToString:@"canvas"]) {
    AFECanvas *cv = [AFECanvas new];
    cv.engine = self; cv.nodeId = AFEStr(n[@"id"]) ?: @"canvas";
    cv.clipsToBounds = YES;
    if (!n[@"height"]) { NSLayoutConstraint *hc = [cv.heightAnchor constraintEqualToConstant:300]; hc.priority = 750; hc.active = YES; }
    for (id ch in [self kids:n]) [cv addSubview:[self buildNode:ch item:item index:idx scope:scope axis:0 abs:YES]];
    v = cv;
  } else if ([t isEqualToString:@"box"]) {
    v = [UIView new];
    if (n[@"text"]) {
      AFELabel *l = [AFELabel new];
      l.font = [self fontFor:n base:17 weight:UIFontWeightSemibold];
      l.textAlignment = NSTextAlignmentCenter; l.numberOfLines = 0;
      l.textColor = _text ?: UIColor.labelColor;
      l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.3;
      [v addSubview:l];
      if (abs) { l.frame = v.bounds; l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; }
      else [self pin:l in:v insets:AFEInsets(n[@"padding"] ?: @4)];
      objc_setAssociatedObject(v, &kAFELabelKey, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  } else {
    AFELabel *l = [AFELabel new];
    l.text = [NSString stringWithFormat:@"⚠︎ tip necunoscut: %@", t];
    l.textColor = UIColor.systemRedColor;
    v = l;
  }
  if (control && control != v) {
    objc_setAssociatedObject(v, &kAFEControlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(control, &kAFENodeKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  objc_setAssociatedObject(v, &kAFENodeKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (abs) {
    objc_setAssociatedObject(v, &kAFEAbsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.translatesAutoresizingMaskIntoConstraints = YES;
    v.frame = CGRectMake(0, 0, 40, 40);
  }
  if (AFEStr(n[@"id"]).length) v.accessibilityIdentifier = AFEStr(n[@"id"]);
  if (AFEBool(n[@"shadow"], NO)) {
    v.layer.shadowColor = UIColor.blackColor.CGColor; v.layer.shadowOpacity = 0.15;
    v.layer.shadowRadius = 8; v.layer.shadowOffset = CGSizeMake(0, 3);
  }
  if (AFEBool(n[@"flex"], NO) || [AFEStr(n[@"width"]) isEqualToString:@"fill"]) {
    [v setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [v setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
  }
  if (AFEIsNum(n[@"minHeight"])) [v.heightAnchor constraintGreaterThanOrEqualToConstant:AFENum(n[@"minHeight"], 0)].active = YES;
  static NSSet *dynP, *exprP;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dynP = AFESet(@[ @"text", @"title", @"color", @"background", @"sf", @"src", @"opacity", @"radius", @"width", @"height",
      @"placeholder", @"label", @"borderColor", @"borderWidth", @"tint", @"visible", @"enabled", @"value", @"x", @"y", @"rotation", @"scale", @"size" ]);
    exprP = AFESet(@[ @"visible", @"enabled", @"value", @"x", @"y", @"rotation", @"scale" ]);
  });
  BOOL isBtn = [t isEqualToString:@"button"];
  for (NSString *k in n) {
    if (![dynP containsObject:k]) continue;
    if ([k isEqualToString:@"title"] && !isBtn) continue;
    if ([k isEqualToString:@"text"] && [t isEqualToString:@"box"] && !objc_getAssociatedObject(v, &kAFELabelKey)) continue;
    if ([k isEqualToString:@"size"] && ![t isEqualToString:@"text"] && ![t isEqualToString:@"button"]) continue;
    id val = n[k];
    if ([exprP containsObject:k] && [val isKindOfClass:NSString.class]) {
      [self bindProp:k expr:val view:v item:item index:idx scope:scope];
    } else if ([val isKindOfClass:NSString.class] && [val containsString:@"{{"]) {
      NSString *ex = [self templateExpr:val];
      if (ex) [self bindProp:k expr:ex view:v item:item index:idx scope:scope];
    } else {
      [self apply:k value:val view:v];
    }
  }
  NSString *bind = AFEStr(n[@"bind"]);
  if (bind.length) {
    NSString *ks = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[ bind ] options:0 error:nil] encoding:NSUTF8StringEncoding];
    ks = [ks substringWithRange:NSMakeRange(1, ks.length - 2)];
    AFEBinding *b = [AFEBinding new];
    b.view = control ?: v; b.prop = @"__bind"; b.item = item; b.index = idx;
    b.expr = [self compileExpr:[NSString stringWithFormat:@"__getPath(%@)", ks]];
    objc_setAssociatedObject(b.view, &kAFENodeKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [scope.bindings addObject:b];
    [self applyBinding:b initial:YES];
  }
  if (!isBtn && ![v isKindOfClass:UIControl.class] && !control) {
    NSString *tap = AFEStr(n[@"onTap"]);
    if (tap.length) {
      AFEAction *a = [self actionFor:tap item:item index:idx];
      UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:a action:@selector(fire:)];
      g.cancelsTouchesInView = NO;
      [v addGestureRecognizer:g]; v.userInteractionEnabled = YES;
      [self addTarget:a toView:v];
    }
    NSString *drag = AFEStr(n[@"onDrag"]);
    if (drag.length) {
      AFEAction *a = [self actionFor:drag item:item index:idx];
      [v addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:a action:@selector(fire:)]];
      v.userInteractionEnabled = YES;
      [self addTarget:a toView:v];
    }
  }
  NSString *lp = AFEStr(n[@"onLongPress"]);
  if (lp.length) {
    AFEAction *a = [self actionFor:lp item:item index:idx];
    [v addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:a action:@selector(fire:)]];
    v.userInteractionEnabled = YES;
    [self addTarget:a toView:v];
  }
  return v;
}

- (void)textViewDidChange:(UITextView *)tv {
  for (AFEAction *a in [objc_getAssociatedObject(tv, &kAFETargetsKey) copy]) [a fire:tv];
}

- (void)refreshList:(AFEList *)l {
  UIStackView *st = l.stack;
  if (!st) return;
  JSValue *r = [_fList callWithArguments:@[ @(l.expr), l.item ?: [self null], @(l.index) ]];
  NSString *sig = [r[@"sig"] toString] ?: @"[]";
  if (l.sig && [sig isEqualToString:l.sig]) return;
  l.sig = sig;
  NSInteger n = MIN(500, [r[@"n"] toInt32]);
  for (UIView *sv in st.arrangedSubviews) { [st removeArrangedSubview:sv]; [sv removeFromSuperview]; }
  l.scope = [AFEScope new];
  NSDictionary *node = l.node;
  if (n == 0 && AFEStr(node[@"empty"]).length) {
    AFELabel *e = [AFELabel new];
    e.text = AFEStr(node[@"empty"]); e.textColor = UIColor.secondaryLabelColor;
    e.textAlignment = NSTextAlignmentCenter; e.numberOfLines = 0;
    [st addArrangedSubview:e];
    return;
  }
  BOOL sep = AFEBool(node[@"separator"], NO);
  NSString *tap = AFEStr(node[@"onTap"]);
  for (NSInteger k = 0; k < n; k++) {
    JSValue *it = [_fListItem callWithArguments:@[ @(l.expr), @(k), l.item ?: [self null], @(l.index) ]];
    UIView *row = [self buildNode:node[@"row"] item:it index:k scope:l.scope axis:0 abs:NO];
    if (tap.length) {
      AFEAction *a = [self actionFor:tap item:it index:k];
      UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:a action:@selector(fire:)];
      g.cancelsTouchesInView = NO;
      [row addGestureRecognizer:g]; row.userInteractionEnabled = YES;
      [self addTarget:a toView:row];
    }
    if (sep && k > 0) {
      UIView *d = [UIView new]; d.backgroundColor = UIColor.separatorColor;
      [d.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;
      [st addArrangedSubview:d];
    }
    [st addArrangedSubview:row];
  }
}

- (void)canvas:(AFECanvas *)c resized:(CGSize)s {
  if (!c.nodeId.length || _stopped) return;
  JSValue *sz = _ctx[@"size"];
  if (sz.isObject) sz[c.nodeId] = @{ @"w": @(s.width), @"h": @(s.height) };
  [self setNeedsRefresh];
}

#pragma mark screens & navigation

- (NSDictionary *)screenById:(NSString *)sid {
  for (id s in ([_spec[@"screens"] isKindOfClass:NSArray.class] ? _spec[@"screens"] : @[]))
    if ([s isKindOfClass:NSDictionary.class] && [AFEStr(s[@"id"]) isEqualToString:sid]) return s;
  return nil;
}

- (AFEScreenVC *)makeScreen:(NSDictionary *)s {
  AFEScreenVC *vc = [AFEScreenVC new];
  vc.engine = self; vc.screen = s ?: @{};
  vc.targets = [NSMutableArray new];
  [_screens addObject:vc];
  NSString *title = AFEStr(s[@"title"]);
  if (title.length && ![title containsString:@"{{"]) vc.title = title;
  return vc;
}

- (void)buildScreen:(AFEScreenVC *)vc {
  NSDictionary *s = vc.screen;
  vc.scope = [AFEScope new];
  NSString *bgs = AFEStr(s[@"background"]);
  vc.view.backgroundColor = [AFEngine colorFromString:bgs] ?: _bg ?: UIColor.systemBackgroundColor;
  if ([bgs containsString:@"{{"]) { NSString *ex = [self templateExpr:bgs]; if (ex) [self bindProp:@"background" expr:ex view:vc.view item:nil index:0 scope:vc.scope]; }
  NSString *title = AFEStr(s[@"title"]);
  if ([title containsString:@"{{"]) {
    NSString *ex = [self templateExpr:title];
    if (ex) {
      AFEBinding *b = [AFEBinding new];
      b.vc = vc; b.prop = @"__title"; b.expr = [self compileExpr:ex];
      [vc.scope.bindings addObject:b];
      [self applyBinding:b initial:YES];
    }
  }
  vc.navigationItem.largeTitleDisplayMode = AFEBool(s[@"largeTitle"], NO) ? UINavigationItemLargeTitleDisplayModeAlways : UINavigationItemLargeTitleDisplayModeNever;
  if (AFEBool(s[@"largeTitle"], NO)) vc.navigationController.navigationBar.prefersLargeTitles = YES;
  NSMutableArray *items = [NSMutableArray new];
  for (id nb in ([s[@"navButtons"] isKindOfClass:NSArray.class] ? s[@"navButtons"] : @[])) {
    if (![nb isKindOfClass:NSDictionary.class]) continue;
    AFEAction *a = [self actionFor:AFEStr(nb[@"action"]) ?: AFEStr(nb[@"onTap"]) item:nil index:0];
    [vc.targets addObject:a];
    UIBarButtonItem *bi = AFEStr(nb[@"sf"]).length
      ? [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:AFEStr(nb[@"sf"])] style:UIBarButtonItemStylePlain target:a action:@selector(fire:)]
      : [[UIBarButtonItem alloc] initWithTitle:AFEStr(nb[@"title"]) ?: @"?" style:UIBarButtonItemStylePlain target:a action:@selector(fire:)];
    [items addObject:bi];
  }
  vc.navigationItem.rightBarButtonItems = items;

  NSMutableDictionary *body = [([s[@"body"] isKindOfClass:NSDictionary.class] ? s[@"body"] : @{ @"type": @"vstack" }) mutableCopy];
  NSString *bt = AFEType(body[@"type"]);
  BOOL full = AFEBool(s[@"fullscreen"], NO);
  UILayoutGuide *g = vc.view.safeAreaLayoutGuide;
  if ([bt isEqualToString:@"scroll"] || [bt isEqualToString:@"canvas"]) {
    if (!body[@"padding"] && [bt isEqualToString:@"scroll"]) body[@"padding"] = @16;
    UIView *content = [self buildNode:body item:nil index:0 scope:vc.scope axis:0 abs:NO];
    if ([content isKindOfClass:UIScrollView.class]) vc.scroll = (UIScrollView *)content;
    [vc.view addSubview:content];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [content.topAnchor constraintEqualToAnchor:full ? vc.view.topAnchor : g.topAnchor],
      [content.leadingAnchor constraintEqualToAnchor:full ? vc.view.leadingAnchor : g.leadingAnchor],
      [content.trailingAnchor constraintEqualToAnchor:full ? vc.view.trailingAnchor : g.trailingAnchor],
      [content.bottomAnchor constraintEqualToAnchor:full ? vc.view.bottomAnchor : g.bottomAnchor],
    ]];
    return;
  }
  if (!body[@"padding"]) body[@"padding"] = @16;
  UIScrollView *sc = [UIScrollView new];
  sc.alwaysBounceVertical = YES;
  sc.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  sc.translatesAutoresizingMaskIntoConstraints = NO;
  [vc.view addSubview:sc];
  vc.scroll = sc;
  [NSLayoutConstraint activateConstraints:@[
    [sc.topAnchor constraintEqualToAnchor:full ? vc.view.topAnchor : g.topAnchor],
    [sc.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
    [sc.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    [sc.bottomAnchor constraintEqualToAnchor:full ? vc.view.bottomAnchor : g.bottomAnchor],
  ]];
  UIView *wrap = [UIView new];
  wrap.translatesAutoresizingMaskIntoConstraints = NO;
  [sc addSubview:wrap];
  NSLayoutConstraint *lowH = [wrap.heightAnchor constraintEqualToAnchor:sc.frameLayoutGuide.heightAnchor];
  lowH.priority = 250;
  [NSLayoutConstraint activateConstraints:@[
    [wrap.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor],
    [wrap.leadingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.leadingAnchor],
    [wrap.trailingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.trailingAnchor],
    [wrap.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor],
    [wrap.widthAnchor constraintEqualToAnchor:sc.frameLayoutGuide.widthAnchor],
    [wrap.heightAnchor constraintGreaterThanOrEqualToAnchor:sc.frameLayoutGuide.heightAnchor],
    lowH,
  ]];
  UIView *content = [self buildNode:body item:nil index:0 scope:vc.scope axis:0 abs:NO];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [wrap addSubview:content];
  BOOL hasSpacer = NO;
  for (id ch in [self kids:body])
    if ([ch isKindOfClass:NSDictionary.class] && [AFEType(ch[@"type"]) isEqualToString:@"spacer"] && !AFEIsNum(ch[@"size"])) hasSpacer = YES;
  NSString *va = AFEStr(body[@"valign"]).lowercaseString;
  NSMutableArray *cs = [@[ [content.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor],
                           [content.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor] ] mutableCopy];
  if (hasSpacer) {
    [cs addObjectsFromArray:@[ [content.topAnchor constraintEqualToAnchor:wrap.topAnchor], [content.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor] ]];
  } else if ([va isEqualToString:@"center"]) {
    [cs addObjectsFromArray:@[ [content.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor],
      [content.topAnchor constraintGreaterThanOrEqualToAnchor:wrap.topAnchor], [content.bottomAnchor constraintLessThanOrEqualToAnchor:wrap.bottomAnchor] ]];
  } else if ([va isEqualToString:@"bottom"]) {
    [cs addObjectsFromArray:@[ [content.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor], [content.topAnchor constraintGreaterThanOrEqualToAnchor:wrap.topAnchor] ]];
  } else {
    [cs addObjectsFromArray:@[ [content.topAnchor constraintEqualToAnchor:wrap.topAnchor], [content.bottomAnchor constraintLessThanOrEqualToAnchor:wrap.bottomAnchor] ]];
  }
  [NSLayoutConstraint activateConstraints:cs];
}

- (UIViewController *)buildRoot {
  NSArray *screens = [_spec[@"screens"] isKindOfClass:NSArray.class] ? _spec[@"screens"] : @[];
  if (!screens.count) {
    UIViewController *e = [UIViewController new];
    e.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *l = [UILabel new];
    l.text = @"Aplicația nu are încă ecrane."; l.textColor = UIColor.secondaryLabelColor;
    l.textAlignment = NSTextAlignmentCenter;
    [e.view addSubview:l];
    [self pin:l in:e.view insets:UIEdgeInsetsZero];
    return e;
  }
  UIViewController *root;
  NSArray *tabs = [_spec[@"tabs"] isKindOfClass:NSArray.class] ? _spec[@"tabs"] : @[];
  NSMutableArray *navs = [NSMutableArray new], *ids = [NSMutableArray new];
  for (id t in tabs) {
    if (![t isKindOfClass:NSDictionary.class]) continue;
    NSString *sid = AFEStr(t[@"screen"]) ?: AFEStr(t[@"id"]);
    NSDictionary *s = [self screenById:sid];
    if (!s) continue;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[self makeScreen:s]];
    UIImage *img = [UIImage systemImageNamed:AFEStr(t[@"sf"]) ?: @"circle"] ?: [UIImage systemImageNamed:@"circle"];
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:AFEStr(t[@"title"]) ?: AFEStr(s[@"title"]) image:img tag:(NSInteger)navs.count];
    [navs addObject:nav]; [ids addObject:sid];
  }
  if (navs.count >= 2) {
    _tabs = [UITabBarController new];
    _tabs.viewControllers = navs;
    _tabIds = ids;
    root = _tabs;
  } else {
    NSDictionary *start = [self screenById:AFEStr(_spec[@"start"])] ?: ([screens.firstObject isKindOfClass:NSDictionary.class] ? screens.firstObject : @{});
    _nav = [[UINavigationController alloc] initWithRootViewController:[self makeScreen:start]];
    root = _nav;
  }
  root.view.tintColor = _tint;
  NSDictionary *theme = [_spec[@"theme"] isKindOfClass:NSDictionary.class] ? _spec[@"theme"] : @{};
  id dark = theme[@"dark"];
  if ([dark isKindOfClass:NSNumber.class]) root.overrideUserInterfaceStyle = [dark boolValue] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
  return root;
}

- (UINavigationController *)currentNav {
  if (_tabs) return [_tabs.selectedViewController isKindOfClass:UINavigationController.class] ? (UINavigationController *)_tabs.selectedViewController : nil;
  return _nav;
}

- (void)go:(NSString *)sid {
  if (_stopped) return;
  NSUInteger ti = _tabIds ? [_tabIds indexOfObject:sid ?: @""] : NSNotFound;
  if (_tabs && ti != NSNotFound) {
    _tabs.selectedIndex = ti;
    [[self currentNav] popToRootViewControllerAnimated:YES];
    return;
  }
  NSDictionary *s = [self screenById:sid];
  if (!s) { [self reportError:[NSString stringWithFormat:@"go(\"%@\"): ecranul nu există.", sid]]; return; }
  [[self currentNav] pushViewController:[self makeScreen:s] animated:YES];
}
- (void)back { [[self currentNav] popViewControllerAnimated:YES]; }

- (UIViewController *)topVC {
  UIViewController *v = _root;
  while (v.presentedViewController) v = v.presentedViewController;
  return v;
}

#pragma mark native services

- (void)alert:(NSString *)t message:(NSString *)m {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:t.length ? t : nil message:m.length ? m : nil preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [[self topVC] presentViewController:a animated:YES completion:nil];
}
- (void)confirm:(NSString *)t message:(NSString *)m cb:(NSInteger)cb {
  __weak AFEngine *w = self;
  UIAlertController *a = [UIAlertController alertControllerWithTitle:t.length ? t : nil message:m.length ? m : nil preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"Anulează" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { [w fireCb:cb value:@NO]; }]];
  [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [w fireCb:cb value:@YES]; }]];
  [[self topVC] presentViewController:a animated:YES completion:nil];
}
- (void)ask:(NSString *)t message:(NSString *)m def:(NSString *)d cb:(NSInteger)cb {
  __weak AFEngine *w = self;
  UIAlertController *a = [UIAlertController alertControllerWithTitle:t.length ? t : nil message:m.length ? m : nil preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.text = d; }];
  __weak UIAlertController *wa = a;
  [a addAction:[UIAlertAction actionWithTitle:@"Anulează" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { [w fireCb:cb value:[NSNull null]]; }]];
  [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
    [w fireCb:cb value:wa.textFields.firstObject.text ?: @""];
  }]];
  [[self topVC] presentViewController:a animated:YES completion:nil];
}
- (void)fireCb:(NSInteger)cb value:(id)v {
  if (_stopped) return;
  [_fCb callWithArguments:@[ @(cb), v ?: [NSNull null] ]];
}
- (void)haptic:(NSString *)k {
  k = k.lowercaseString ?: @"";
  if ([k isEqualToString:@"success"] || [k isEqualToString:@"warning"] || [k isEqualToString:@"error"]) {
    [[UINotificationFeedbackGenerator new] notificationOccurred:[k isEqualToString:@"success"] ? UINotificationFeedbackTypeSuccess :
      [k isEqualToString:@"warning"] ? UINotificationFeedbackTypeWarning : UINotificationFeedbackTypeError];
  } else if ([k isEqualToString:@"selection"]) {
    [[UISelectionFeedbackGenerator new] selectionChanged];
  } else {
    UIImpactFeedbackStyle st = [k isEqualToString:@"heavy"] ? UIImpactFeedbackStyleHeavy : [k isEqualToString:@"medium"] ? UIImpactFeedbackStyleMedium :
      [k isEqualToString:@"soft"] ? UIImpactFeedbackStyleSoft : [k isEqualToString:@"rigid"] ? UIImpactFeedbackStyleRigid : UIImpactFeedbackStyleLight;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:st] impactOccurred];
  }
}
- (void)sound:(NSString *)k {
  NSDictionary *m = @{ @"tap": @1104, @"click": @1123, @"tick": @1103, @"success": @1054, @"error": @1053, @"beep": @1052,
                       @"ding": @1013, @"alarm": @1005, @"tweet": @1016, @"bell": @1013, @"pop": @1105, @"lock": @1100 };
  NSNumber *n = m[k.lowercaseString ?: @""];
  SystemSoundID sid = n ? (SystemSoundID)n.unsignedIntValue : (SystemSoundID)MAX(0, k.intValue);
  if (sid) AudioServicesPlaySystemSound(sid);
}
- (void)toneFreq:(double)f ms:(double)ms volume:(double)vol {
  if (_stopped) return;
  if (!_audio) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    _audio = [AVAudioEngine new];
    _player = [AVAudioPlayerNode new];
    _toneFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
    [_audio attachNode:_player];
    [_audio connect:_player to:_audio.mainMixerNode format:_toneFormat];
  }
  if (!_audio.isRunning) { NSError *e = nil; if (![_audio startAndReturnError:&e]) return; }
  AVAudioFrameCount n = (AVAudioFrameCount)(44100 * MAX(10, MIN(ms, 5000)) / 1000.0);
  AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_toneFormat frameCapacity:n];
  buf.frameLength = n;
  float *d = buf.floatChannelData[0];
  double v = MAX(0, MIN(1, vol)), fr = MAX(20, MIN(f, 20000));
  AVAudioFrameCount ramp = MIN(n / 4, 220);
  for (AVAudioFrameCount i = 0; i < n; i++) {
    double env = 1;
    if (i < ramp) env = (double)i / ramp; else if (i > n - ramp) env = (double)(n - i) / ramp;
    d[i] = (float)(v * env * sin(2 * M_PI * fr * i / 44100.0));
  }
  [_player scheduleBuffer:buf atTime:nil options:0 completionHandler:nil];
  if (!_player.isPlaying) [_player play];
}
- (void)speak:(NSString *)t lang:(NSString *)lang {
  if (!t.length) return;
  if (!_speech) _speech = [AVSpeechSynthesizer new];
  AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:t];
  u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:lang.length ? lang : @"ro-RO"];
  [_speech speakUtterance:u];
}
- (void)toast:(NSString *)t {
  UIView *host = _root.view;
  if (!host || !t.length) return;
  AFELabel *l = [AFELabel new];
  l.text = t; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter;
  l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
  l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
  l.insets = UIEdgeInsetsMake(10, 16, 10, 16);
  l.layer.cornerRadius = 14; l.clipsToBounds = YES;
  l.translatesAutoresizingMaskIntoConstraints = NO;
  [host addSubview:l];
  [NSLayoutConstraint activateConstraints:@[
    [l.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
    [l.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor constant:-60],
    [l.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor constant:-40],
  ]];
  l.alpha = 0;
  [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
    [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL g) { [l removeFromSuperview]; }];
  }];
}
- (void)share:(NSString *)t {
  UIActivityViewController *ac = [[UIActivityViewController alloc] initWithActivityItems:@[ t ?: @"" ] applicationActivities:nil];
  ac.popoverPresentationController.sourceView = _root.view;
  [[self topVC] presentViewController:ac animated:YES completion:nil];
}
- (void)motionStart:(double)hz {
  if (_stopped) return;
  if (!_motion) _motion = [CMMotionManager new];
  NSTimeInterval iv = 1.0 / MAX(1, MIN(hz, 60));
  __weak AFEngine *w = self;
  if (_motion.isDeviceMotionAvailable) {
    _motion.deviceMotionUpdateInterval = iv;
    [_motion startDeviceMotionUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *m, NSError *e) {
      if (!m) return;
      double k = 180.0 / M_PI;
      [w motionData:@{ @"x": @(m.gravity.x), @"y": @(m.gravity.y), @"z": @(m.gravity.z),
                       @"ax": @(m.userAcceleration.x), @"ay": @(m.userAcceleration.y), @"az": @(m.userAcceleration.z),
                       @"pitch": @(m.attitude.pitch * k), @"roll": @(m.attitude.roll * k), @"yaw": @(m.attitude.yaw * k),
                       @"rx": @(m.rotationRate.x), @"ry": @(m.rotationRate.y), @"rz": @(m.rotationRate.z) }];
    }];
  } else if (_motion.isAccelerometerAvailable) {
    _motion.accelerometerUpdateInterval = iv;
    [_motion startAccelerometerUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMAccelerometerData *a, NSError *e) {
      if (!a) return;
      [w motionData:@{ @"x": @(a.acceleration.x), @"y": @(a.acceleration.y), @"z": @(a.acceleration.z), @"pitch": @0, @"roll": @0, @"yaw": @0 }];
    }];
  } else {
    [self reportError:@"Senzorii de mișcare nu sunt disponibili."];
  }
}
- (void)motionData:(NSDictionary *)d { if (!_stopped) [_fMotion callWithArguments:@[ d ]]; }
- (void)motionStop { [_motion stopDeviceMotionUpdates]; [_motion stopAccelerometerUpdates]; }

- (void)addTimer:(NSInteger)tid ms:(double)ms repeat:(BOOL)rep {
  if (_stopped) return;
  [self cancelTimer:tid];
  if (_timers.count > 200) { [self reportError:@"Prea multe timere active (peste 200)."]; return; }
  __weak AFEngine *w = self;
  NSTimer *t = [NSTimer timerWithTimeInterval:MAX(rep ? 0.016 : 0, ms / 1000.0) repeats:rep block:^(NSTimer *tm) { [w fireTimer:tid repeat:rep]; }];
  [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
  _timers[@(tid)] = t;
}
- (void)cancelTimer:(NSInteger)tid {
  [_timers[@(tid)] invalidate];
  [_timers removeObjectForKey:@(tid)];
}
- (void)fireTimer:(NSInteger)tid repeat:(BOOL)rep {
  if (_stopped) return;
  if (!rep) [_timers removeObjectForKey:@(tid)];
  [_fTimer callWithArguments:@[ @(tid), @(rep) ]];
}

- (void)stop {
  if (_stopped) return;
  _stopped = YES;
  for (NSTimer *t in _timers.allValues) [t invalidate];
  [_timers removeAllObjects];
  [self motionStop];
  [_speech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
  [_player stop];
  [_audio stop];
}

- (void)dealloc { [self stop]; }

@end
