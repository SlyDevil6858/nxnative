// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include <stdatomic.h>
#import "DmPadProfiles.h"

extern BOOL front_ios_runtime_fps_enabled(void);
extern BOOL front_ios_runtime_metal_hud_enabled(void);
extern void front_ios_set_runtime_hud(BOOL fps, BOOL metalHUD);

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld

@interface DmGamepad : UIView <UIGestureRecognizerDelegate, UIDocumentPickerDelegate>
- (UIColor *)editorAccentColor;
- (void)beginLauncherEdit;
- (void)toggleEditor;
- (void)saveEdit;
- (void)openMenuFromController;
@end
static __weak DmGamepad *g_view;
static BOOL g_launcher_preview = NO;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    NSMutableDictionary<NSString *, CALayer *> *_skinItems; NSDictionary<NSString *, UIImage *> *_skinImages; BOOL _customSkin; // one image layer per control; native touch hit-testing stays unchanged
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    BOOL _builtInSkinExportChecked;
    NSDictionary<NSString *, UIColor *> *_themeButtonColors;
    NSString *_themeName;
    UIButton *_themeButton;
    NSMutableDictionary *_custom;
    DmPadProfiles *_profiles;
    BOOL _editing, _editWasTap;
    int _selected;
    UITouch *_dragTouch;
    CGPoint _dragStart, _dragHome;
    CGRect _lastSafe;
    UIButton *_chooseButton, *_profileButton, *_saveAsButton;
    UILabel *_menuTip;
    UILongPressGestureRecognizer *_editHold;
    UIView *_tools;
    UISlider *_sizeSlider, *_alphaSlider;
    UISwitch *_fpsSwitch, *_hudSwitch;
    UILabel *_editInfo;
    CAShapeLayer *_editHighlight;
    NSDictionary<NSString *, NSValue *> *_dragAllHomes;
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static UIColor *themeHex(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *hex = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([hex hasPrefix:@"#"]) hex=[hex substringFromIndex:1];
    if (hex.length != 6) return nil;
    unsigned int rgb = 0; NSScanner *scanner = [NSScanner scannerWithString:hex];
    scanner.charactersToBeSkipped=nil;
    if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 255)/255.0 green:((rgb >> 8) & 255)/255.0 blue:(rgb & 255)/255.0 alpha:1];
}
static void theme_init(void) {
    k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45];
    k_line = [UIColor colorWithWhite:1 alpha:0.38]; k_ringFill = [UIColor colorWithWhite:1 alpha:0.06];
    k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
}
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{ theme_init(); });
        [self loadSelectedTheme];
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        _skinItems = [NSMutableDictionary dictionary];
        _customSkin = NO; // Native vector controls are used; the PNG skin system is retired.
        _editHighlight = [CAShapeLayer layer];
        _editHighlight.fillColor = UIColor.clearColor.CGColor;
        _editHighlight.strokeColor = [self editorAccentColor].CGColor;
        _editHighlight.lineWidth = 2.5;
        _editHighlight.hidden = YES;
        [_controls addSublayer:_editHighlight];
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        _profiles = [[DmPadProfiles alloc] initWithDefaults:NSUserDefaults.standardUserDefaults
                                                       game:@DM_GAME_ID];
        [self loadControls];
        [self setupEditor];
        _editHold=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleEditHold:)];
        _editHold.minimumPressDuration=0.6; _editHold.cancelsTouchesInView=YES; _editHold.delegate=self;
        [self addGestureRecognizer:_editHold];
        [self applyLayout];
        if (!g_launcher_preview && ![NSUserDefaults.standardUserDefaults boolForKey:@"DmPadMenuTipShown"]) {
            // A one-time hint points out the 2D / 3D layout button without covering the game.
            _menuTip=[UILabel new];
            _menuTip.text=@"Hold Select on your controller to open the in-game menu\n(or press and hold 2D / 3D on screen)";
            _menuTip.textColor=UIColor.whiteColor;
            _menuTip.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            _menuTip.textAlignment=NSTextAlignmentCenter;
            _menuTip.numberOfLines=2;
            _menuTip.backgroundColor=[UIColor colorWithWhite:0.05 alpha:0.92];
            _menuTip.layer.cornerRadius=9;
            _menuTip.layer.masksToBounds=YES;
            _menuTip.layer.borderWidth=1;
            _menuTip.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;
            _menuTip.alpha=0;
            [self addSubview:_menuTip];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"DmPadMenuTipShown"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ self->_menuTip.alpha=1; }];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.35 animations:^{ self->_menuTip.alpha=0; }
                                     completion:^(__unused BOOL finished) { [self->_menuTip removeFromSuperview]; self->_menuTip=nil; }];
                });
            });
        }
        if (!g_launcher_preview) {
            NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
            [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
            [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
            pads_start();
            [self padsChanged:nil];
            motion_start();
            phone_motion_start(self);
        }
    }
    return self;
}
- (void)loadTouchSkin {
    NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:@"DmTouchControlSkinPath"];
    _customSkin = NO; [_skinItems removeAllObjects];
    if (!path.length) return;
    NSArray<NSString *> *names = @[@"a", @"b", @"x", @"y", @"stick-base", @"stick-knob",
        @"zl", @"l", @"zr", @"r", @"minus", @"plus", @"layout",
        @"dpad-up", @"dpad-down", @"dpad-left", @"dpad-right", @"l3", @"r3", @"right-stick-base", @"right-stick-knob"];
    NSMutableDictionary *images = [NSMutableDictionary dictionary];
    for (NSString *name in names) {
        UIImage *image = [UIImage imageWithContentsOfFile:[path stringByAppendingPathComponent:[name stringByAppendingString:@".png"]]];
        if (image.CGImage) images[name] = image;
    }
    // A skin is accepted only when it has every image needed by both layouts.
    if (images.count != names.count) return;
    _skinImages = images; _customSkin = YES;
    for (NSString *name in names) {
        UIImage *skinImage = (UIImage *)images[name];
        CALayer *layer = [CALayer layer]; layer.contents = (__bridge id)skinImage.CGImage;
        layer.contentsGravity = kCAGravityResize; layer.contentsScale = UIScreen.mainScreen.scale;
        [_controls addSublayer:layer]; _skinItems[name] = layer;
    }
}
- (void)placeSkinItem:(NSString *)name center:(CGPoint)c size:(CGSize)size hidden:(BOOL)hidden {
    CALayer *layer = _skinItems[name]; if (!layer) return;
    layer.frame = CGRectMake(c.x - size.width / 2, c.y - size.height / 2, size.width, size.height);
    layer.hidden = hidden;
    static NSDictionary<NSString *, NSNumber *> *skinIDs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skinIDs=@{@"a":@0,@"b":@1,@"x":@2,@"y":@3,@"l3":@4,@"r3":@5,@"l":@6,@"r":@7,
                  @"zl":@8,@"zr":@9,@"plus":@10,@"minus":@11,@"stick-base":@16,@"stick-knob":@16,@"right-stick-base":@16,@"right-stick-knob":@16,
                  @"dpad-up":@17,@"dpad-down":@17,@"dpad-left":@17,@"dpad-right":@17};
    });
    NSNumber *control=skinIDs[name];
    if (control) layer.opacity=[self opacity:control.intValue];
}
- (void)layoutSkinItems {
    if (!_customSkin) return;
    CGFloat u = self.u;
    for (int b = B_A; b <= B_Y; b++) {
        NSString *name = @[@"a", @"b", @"x", @"y"][b];
        CGFloat d = [self faceRadius:b] * 2;
        [self placeSkinItem:name center:[self facePos:b] size:CGSizeMake(d,d) hidden:_tap];
    }
    CGFloat stickD = [self stickR:0] * 2;
    [self placeSkinItem:@"stick-base" center:self.stickHome size:CGSizeMake(stickD,stickD) hidden:_tap];
    CGFloat knobD = K_KNOB_R * u * [self scale:16] * 2; CGPoint offset = [self knobOffset:0];
    [self placeSkinItem:@"stick-knob" center:CGPointMake(self.stickHome.x+offset.x,self.stickHome.y+offset.y)
        size:CGSizeMake(knobD,knobD) hidden:_tap];
    for (NSString *name in @[@"zl",@"l",@"zr",@"r"]) {
        int b = [name isEqualToString:@"zl"] ? B_ZL : [name isEqualToString:@"l"] ? B_L :
                [name isEqualToString:@"zr"] ? B_ZR : B_R;
        CGFloat d = [self dropR:b] * K_DROP_TIP * 2;
        [self placeSkinItem:name center:[self dropCenter:b] size:CGSizeMake(d,d) hidden:_tap];
    }
    for (NSString *name in @[@"minus",@"plus"]) {
        int b = [name isEqualToString:@"plus"] ? B_PLUS : B_MINUS; CGRect rc = [self pillRect:b];
        [self placeSkinItem:name center:CGPointMake(CGRectGetMidX(rc),CGRectGetMidY(rc)) size:rc.size hidden:_tap];
    }
    CGFloat swapD = K_SWAP_R * u * 2;
    [self placeSkinItem:@"layout" center:self.swapCenter size:CGSizeMake(swapD,swapD) hidden:_tap];
    CGFloat clickD = K_CLICK_R * u * 2;
    CGFloat l3D = clickD * [self scale:B_LS], r3D = clickD * [self scale:B_RS];
    [self placeSkinItem:@"l3" center:[self clickCenter:B_LS] size:CGSizeMake(l3D,l3D) hidden:_tap || !_full];
    [self placeSkinItem:@"r3" center:[self clickCenter:B_RS] size:CGSizeMake(r3D,r3D) hidden:_tap || !_full];
    CGFloat dpadD = self.dpadR * 2; CGPoint dc = self.dpadCenter;
    for (NSString *name in @[@"dpad-up",@"dpad-down",@"dpad-left",@"dpad-right"])
        [self placeSkinItem:name center:dc size:CGSizeMake(dpadD,dpadD) hidden:_tap || !_full];
    CGFloat rightD = [self stickR:1] * 2;
    BOOL rightActive = _full && !_tap && _stick[1] != nil;
    [self placeSkinItem:@"right-stick-base" center:_rCentre size:CGSizeMake(rightD,rightD) hidden:!rightActive];
    [self placeSkinItem:@"right-stick-knob" center:_stickNow[1] size:CGSizeMake(knobD,knobD) hidden:!rightActive];
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _tap;
    _swap.hidden = _swapLabel.hidden = NO;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self loadControls];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (NSString *)controlsLayout { return _full ? @"3D" : @"2D"; }
- (NSString *)controlID:(int)b {
    static NSArray<NSString *> *ids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ids = @[@"A",@"B",@"X",@"Y",@"L3",@"R3",@"L",@"R",@"ZL",@"ZR",@"Plus",@"Minus",
                @"unused12",@"unused13",@"unused14",@"unused15",@"Stick",@"Dpad"];
    });
    return b >= 0 && b < (int)ids.count ? ids[b] : @"";
}
- (void)loadControls {
    _custom = [[_profiles controls:self.controlsLayout slot:_profiles.selected] mutableCopy];
    if (!_custom) _custom = [NSMutableDictionary dictionary];
}
- (CGFloat)scale:(int)b {
    NSNumber *n = _custom[[self controlID:b]][@"scale"];
    return n ? n.doubleValue : 1.0;
}
- (float)opacity:(int)b {
    NSNumber *n = _custom[[self controlID:b]][@"alpha"];
    float value = n ? n.floatValue : 1.0f;
    return _editing ? fmaxf(value, 0.35f) : value;
}
- (CGPoint)position:(int)b base:(CGPoint)base {
    NSDictionary *value = _custom[[self controlID:b]];
    CGRect safe = self.safe;
    CGFloat margin = (b == 16 ? K_STICK_R : b == 17 ? K_DPAD_R : isDrop(b) ? 38 : isClick(b) ? 22 : 28) * self.u * [self scale:b];
    // An opacity-only entry can exist from earlier buggy builds. It has no saved
    // coordinates, so treat it as an untouched control instead of interpreting
    // missing x/y as zero (which teleports it to the safe area's top-left).
    if (![value[@"x"] isKindOfClass:NSNumber.class] || ![value[@"y"] isKindOfClass:NSNumber.class]) value=nil;
    return dm_pad_position(value, base, safe, margin);
}
- (CGFloat)faceRadius:(int)b { return self.faceR * [self scale:b]; }
- (CGPoint)baseFacePos:(int)b {
    CGPoint center = self.faceCenter; CGFloat gap = self.faceGap;
    switch (b) {
        case B_A: return CGPointMake(center.x + gap, center.y);
        case B_B: return CGPointMake(center.x, center.y + gap);
        case B_X: return CGPointMake(center.x, center.y - gap);
        default: return CGPointMake(center.x - gap, center.y);
    }
}
- (CGPoint)facePos:(int)b { return [self position:b base:[self baseFacePos:b]]; }
- (CGPoint)baseStickHome {
    CGRect s = self.corner;
    return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u);
}
- (CGPoint)stickHome { return [self position:16 base:[self baseStickHome]]; }
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R * [self scale:16]) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)baseDpadCenter {
    CGRect s = self.corner; CGFloat u = self.u;
    return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u);
}
- (CGPoint)dpadCenter { return [self position:17 base:[self baseDpadCenter]]; }
- (CGFloat)dpadR { return K_DPAD_R * self.u * [self scale:17]; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)baseDropCenter:(int)b {
    CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u,
                CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u);
}
- (CGPoint)dropCenter:(int)b { return [self position:b base:[self baseDropCenter:b]]; }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u * [self scale:b]; }
- (CGPoint)baseClickCenter:(int)b {
    CGRect s = self.safe; CGFloat u = self.u;
    return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u);
}
- (CGPoint)clickCenter:(int)b { return [self position:b base:[self baseClickCenter:b]]; }
- (CGRect)basePillRect:(int)b {
    CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint center = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u,
                                  CGRectGetMinY(s) + K_PILL_Y * u);
    return CGRectMake(center.x - w / 2, center.y - h / 2, w, h);
}
- (CGRect)pillRect:(int)b {
    CGRect base = [self basePillRect:b];
    CGPoint center = [self position:b base:CGPointMake(CGRectGetMidX(base), CGRectGetMidY(base))];
    CGFloat factor = [self scale:b];
    return CGRectMake(center.x - base.size.width * factor / 2,
                      center.y - base.size.height * factor / 2,
                      base.size.width * factor, base.size.height * factor);
}
- (CGPoint)controlCenter:(int)b {
    if (b == 16) return self.stickHome;
    if (b == 17) return self.dpadCenter;
    if (b < 4) return [self facePos:b];
    if (isDrop(b)) return [self dropCenter:b];
    if (isClick(b)) return [self clickCenter:b];
    CGRect rect = [self pillRect:b];
    return CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
}
- (BOOL)editable:(int)b { return b < 12 ? (_full || !fullOnly(b)) : b == 16 || (b == 17 && _full); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * [self scale:b] * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= [self faceRadius:b] * 1.25) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (_editing) { [self editTouches:ts began:YES]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self]; int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (_editing) { [self editTouches:ts began:NO]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    if (_editing) { if ([ts containsObject:_dragTouch]) _dragTouch=nil; return; }
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}


// Export native artwork by rendering a copy of the complete control layer tree.
// Individual CAShapeLayers rely on the parent coordinate space; archiving a single
// shape layer loses that context and produces blank PNGs. Only the copied siblings
// are hidden, never the live controls.
- (void)exportBuiltInSkin {
    if (self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    [CATransaction flush];
    NSArray<NSString *> *names = @[@"a", @"b", @"x", @"y", @"stick-base", @"stick-knob", @"zl", @"l", @"zr", @"r", @"minus", @"plus", @"layout", @"dpad-up", @"dpad-down", @"dpad-left", @"dpad-right", @"l3", @"r3", @"right-stick-base", @"right-stick-knob"];
    NSMutableDictionary<NSString *, NSValue *> *rects = [NSMutableDictionary dictionary];
    CGFloat pad = 5 * self.u;
    for (int b = B_A; b <= B_Y; b++) {
        CGPoint p = [self facePos:b]; CGFloat r = self.faceR;
        rects[@[@"a", @"b", @"x", @"y"][b]] = [NSValue valueWithCGRect:CGRectInset(CGRectMake(p.x-r,p.y-r,2*r,2*r),-pad,-pad)];
    }
    CGPoint sh = self.stickHome; CGFloat sr = [self stickR:0];
    rects[@"stick-base"] = [NSValue valueWithCGRect:CGRectInset(CGRectMake(sh.x-sr,sh.y-sr,2*sr,2*sr),-pad,-pad)];
    CGFloat kr = K_KNOB_R * self.u; CGPoint ko = [self knobOffset:0];
    CGPoint kc = CGPointMake(sh.x+ko.x,sh.y+ko.y);
    rects[@"stick-knob"] = [NSValue valueWithCGRect:CGRectInset(CGRectMake(kc.x-kr,kc.y-kr,2*kr,2*kr),-pad,-pad)];
    for (NSString *name in @[@"zl", @"l", @"zr", @"r"]) {
        int b = [name isEqual:@"zl"]?B_ZL:[name isEqual:@"l"]?B_L:[name isEqual:@"zr"]?B_ZR:B_R;
        CGPoint p=[self dropCenter:b]; CGFloat r=[self dropR:b]*K_DROP_TIP;
        rects[name]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(p.x-r,p.y-r,2*r,2*r),-pad,-pad)];
    }
    for (NSString *name in @[@"minus", @"plus"]) {
        int b=[name isEqual:@"plus"]?B_PLUS:B_MINUS;
        rects[name]=[NSValue valueWithCGRect:CGRectInset([self pillRect:b],-pad,-pad)];
    }
    CGFloat swapR=K_SWAP_R*self.u; CGPoint sp=self.swapCenter;
    rects[@"layout"]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(sp.x-swapR,sp.y-swapR,2*swapR,2*swapR),-pad,-pad)];
    CGFloat clickR=K_CLICK_R*self.u;
    for (NSString *name in @[@"l3", @"r3"]) {
        CGPoint p=[self clickCenter:[name isEqual:@"l3"]?B_LS:B_RS];
        rects[name]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(p.x-clickR,p.y-clickR,2*clickR,2*clickR),-pad,-pad)];
    }
    CGFloat dr=self.dpadR; CGPoint dc=self.dpadCenter;
    rects[@"dpad-up"]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(dc.x-dr,dc.y-dr,2*dr,dr+pad),-pad,-pad)];
    rects[@"dpad-down"]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(dc.x-dr,dc.y,2*dr,dr+pad),-pad,-pad)];
    rects[@"dpad-left"]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(dc.x-dr,dc.y-dr,dr+pad,2*dr),-pad,-pad)];
    rects[@"dpad-right"]=[NSValue valueWithCGRect:CGRectInset(CGRectMake(dc.x,dc.y-dr,dr+pad,2*dr),-pad,-pad)];

    NSMutableDictionary<NSString *, CALayer *> *sources=[NSMutableDictionary dictionary];
    for (int b=B_A; b<=B_Y; b++) sources[@[@"a", @"b", @"x", @"y"][b]]=_key[b];
    sources[@"stick-base"]=_ring; sources[@"stick-knob"]=_knob;
    sources[@"zl"]=_key[B_ZL]; sources[@"l"]=_key[B_L]; sources[@"zr"]=_key[B_ZR]; sources[@"r"]=_key[B_R];
    sources[@"minus"]=_key[B_MINUS]; sources[@"plus"]=_key[B_PLUS]; sources[@"layout"]=_swap;
    sources[@"dpad-up"]=_key[B_UP]; sources[@"dpad-down"]=_key[B_DOWN];
    sources[@"dpad-left"]=_key[B_LEFT]; sources[@"dpad-right"]=_key[B_RIGHT];
    sources[@"l3"]=_key[B_LS]; sources[@"r3"]=_key[B_RS];

    NSURL *docs=[NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *folder=[[docs URLByAppendingPathComponent:@"TouchControlSkins" isDirectory:YES] URLByAppendingPathComponent:@"Default" isDirectory:YES];
    NSError *dirError=nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        LOG("touch skin export: cannot create folder: %s", dirError.localizedDescription.UTF8String ?: "?");
        return;
    }
    // Export once per version. This also regenerates the earlier blank PNGs, but
    // never overwrites a Default skin that the user has already edited.
    NSURL *versionURL=[folder URLByAppendingPathComponent:@".export-version"];
    NSString *exportVersion=[NSString stringWithContentsOfURL:versionURL encoding:NSUTF8StringEncoding error:nil];
    if ([exportVersion isEqualToString:@"2"]) {
        LOG("touch skin export: Default PNGs already exported; preserving user edits");
        return;
    }
    NSError *archiveError=nil;
    NSData *archive=[NSKeyedArchiver archivedDataWithRootObject:_controls requiringSecureCoding:NO error:&archiveError];
    if (!archive) {
        LOG("touch skin export: could not copy control layer tree: %s", archiveError.localizedDescription.UTF8String ?: "?");
        return;
    }

    NSMutableArray<NSString *> *failed=[NSMutableArray array];
    CGFloat scale=UIScreen.mainScreen.scale;
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];
    format.scale=scale; format.opaque=NO;

    for (NSString *name in names) {
        // The right stick uses the same native artwork as the left stick; it is
        // normally gesture-driven and has no separately drawn native control.
        NSString *renderName = [name isEqual:@"right-stick-base"] ? @"stick-base" :
                               [name isEqual:@"right-stick-knob"] ? @"stick-knob" : name;
        CALayer *source=sources[renderName];
        NSUInteger index=[_controls.sublayers indexOfObjectIdenticalTo:source];
        CGRect cropRect=CGRectIntersection(rects[renderName].CGRectValue,self.bounds);
        if (!source || index==NSNotFound || CGRectIsEmpty(cropRect)) { [failed addObject:name]; continue; }

        NSError *copyError=nil;
        CALayer *canvas=[CALayer layer];
        canvas.frame=self.bounds; canvas.bounds=self.bounds;
        CALayer *copiedRoot=[NSKeyedUnarchiver unarchiveTopLevelObjectWithData:archive error:&copyError];
        if (!copiedRoot || index >= copiedRoot.sublayers.count) { [failed addObject:name]; continue; }
        copiedRoot.frame=self.bounds; copiedRoot.bounds=self.bounds; copiedRoot.hidden=NO;
        NSArray<CALayer *> *copiedChildren=[copiedRoot.sublayers copy];
        CALayer *target=copiedChildren[index];
        for (CALayer *sibling in copiedChildren) sibling.hidden = (sibling != target);
        target.hidden=NO;
        [canvas addSublayer:copiedRoot];

        UIImage *whole=[[[UIGraphicsImageRenderer alloc] initWithSize:self.bounds.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [canvas renderInContext:ctx.CGContext];
        }];
        CGRect pixels=CGRectMake(floor(cropRect.origin.x*scale),
                                 floor((self.bounds.size.height-CGRectGetMaxY(cropRect))*scale),
                                 ceil(cropRect.size.width*scale),ceil(cropRect.size.height*scale));
        CGImageRef cropped=CGImageCreateWithImageInRect(whole.CGImage,pixels);
        if (!cropped) { [failed addObject:name]; continue; }
        UIImage *piece=[UIImage imageWithCGImage:cropped scale:1 orientation:UIImageOrientationUp];
        CGImageRelease(cropped);
        UIGraphicsImageRendererFormat *outFormat=[UIGraphicsImageRendererFormat defaultFormat];
        outFormat.scale=1; outFormat.opaque=NO;
        UIImage *png=[[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256,256) format:outFormat] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGFloat factor=MIN(256.0/piece.size.width,256.0/piece.size.height);
            CGSize size=CGSizeMake(piece.size.width*factor,piece.size.height*factor);
            [piece drawInRect:CGRectMake((256-size.width)/2,(256-size.height)/2,size.width,size.height)];
        }];
        NSData *data=UIImagePNGRepresentation(png);
        if (!data || ![data writeToURL:[folder URLByAppendingPathComponent:[name stringByAppendingString:@".png"]] options:NSDataWritingAtomic error:nil]) [failed addObject:name];
    }
    if (failed.count) {
        LOG("touch skin export: failed controls: %s", [failed componentsJoinedByString:@", "].UTF8String);
    } else {
        [@"2" writeToURL:versionURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        LOG("touch skin export: wrote 21 isolated PNGs to Documents/TouchControlSkins/Default");
    }
}
- (CGFloat)editHighlightRadiusForControl:(int)b {
    if (b == 16) return [self stickR:0];
    if (b == 17) return self.dpadR;
    if (b < 4) return [self faceRadius:b];
    if (isDrop(b)) return [self dropR:b] * K_DROP_TIP;
    if (isClick(b)) return K_CLICK_R * self.u * [self scale:b];
    return MAX([self pillRect:b].size.width, [self pillRect:b].size.height) / 2;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    if (_menuTip) {
        CGFloat tipWidth=MIN(300, self.bounds.size.width-32);
        _menuTip.frame=CGRectMake((self.bounds.size.width-tipWidth)/2, self.safeAreaInsets.top+44, tipWidth, 42);
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGRect safe=self.safe;
    if (!CGRectEqualToRect(safe,_lastSafe)) { _lastSafe=safe; if (!_editing) [self reset]; }
    _tools.frame=CGRectMake(CGRectGetMidX(safe)-160,CGRectGetMidY(safe)-164,320,328);
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, [self faceRadius:b])); placeLabel(_label[b], c, 20 * u * [self scale:b]); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u * [self scale:b])); placeLabel(_label[b], c, 16 * u * [self scale:b]);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u * [self scale:b])); placeLabel(_label[b], c, 13 * u * [self scale:b]);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u * [self scale:b]);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u * [self scale:17], K_ARM_IN * u * [self scale:17], arms[i].angle, 6 * u * [self scale:17]));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u * [self scale:16]; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [self layoutSkinItems];
    if (_editing) {
        CGMutablePathRef outlines = CGPathCreateMutable();
        if (_selected < 0) {
            // "All controls" uses the same circular selection halo around every editable control.
            for (int b = 0; b < 18; b++) if ([self editable:b]) {
                CGPoint center = [self controlCenter:b];
                CGFloat radius = [self editHighlightRadiusForControl:b] + 7 * u;
                CGPathAddEllipseInRect(outlines, NULL,
                    CGRectMake(center.x - radius, center.y - radius, 2 * radius, 2 * radius));
            }
        } else {
            CGPoint center = [self controlCenter:_selected];
            CGFloat radius = [self editHighlightRadiusForControl:_selected] + 7 * u;
            CGPathAddEllipseInRect(outlines, NULL,
                CGRectMake(center.x - radius, center.y - radius, 2 * radius, 2 * radius));
        }
        _editHighlight.path = outlines;
        CGPathRelease(outlines);
        _editHighlight.hidden = NO;
    } else {
        _editHighlight.hidden = YES;
    }
    [CATransaction commit];
    [self refresh];

}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) {
        BOOL on = (all >> b) & 1;
        _key[b].fillColor = [self themeColorForButton:b pressed:on].CGColor;
        _key[b].strokeColor = k_line.CGColor;
        _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor;
        _key[b].opacity = [self opacity:(b >= B_LEFT ? 17 : b)];
    }
    _ring.opacity = _knob.opacity = [self opacity:16];
    _ring.fillColor = k_ringFill.CGColor;
    _ring.strokeColor = k_line.CGColor; _knob.strokeColor = k_line.CGColor;
    CAShapeLayer *innerRing=(CAShapeLayer *)_knob.sublayers.firstObject;
    innerRing.strokeColor=k_line.CGColor;
    _swap.fillColor = [self themeColorForButton:B_N pressed:_swapHeld].CGColor;
    _swap.strokeColor = k_line.CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    // Keep the 2D / 3D / TAP layout control above every other touch-control layer.
    [_controls addSublayer:_swap];
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = [self themeColorForButton:B_LS pressed:_stick[0] != nil].CGColor;
    [CATransaction commit];
}


static NSString *const k_theme_path_key = @"DmTouchControlThemePath";
static NSString *const k_theme_name_key = @"DmTouchControlThemeName";
- (NSURL *)themesDirectoryCreating:(BOOL)create {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *docs=[fm URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
    NSURL *dir=[docs URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES];
    if (create) {
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];

        // Also install themes shipped in the app's TouchControlThemes resource folder.
        // This matters when the game starts directly and never visits the launcher,
        // which normally performs this copy. Never overwrite a theme the user placed
        // in Documents/TouchControlThemes themselves.
        NSURL *bundled=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES];
        NSArray<NSURL *> *bundledFolders=[fm contentsOfDirectoryAtURL:bundled
            includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *folder in bundledFolders) {
            NSNumber *isDirectory=nil;
            [folder getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if (!isDirectory.boolValue) continue;
            NSURL *destination=[dir URLByAppendingPathComponent:folder.lastPathComponent isDirectory:YES];
            if ([fm fileExistsAtPath:destination.path]) continue;
            NSError *error=nil;
            if (![fm copyItemAtURL:folder toURL:destination error:&error])
                NSLog(@"Could not install bundled touch theme %@: %@",folder.lastPathComponent,error.localizedDescription);
        }
    }
    return dir;
}
- (NSDictionary *)validThemeJSONAtFolder:(NSURL *)folder {
    NSData *data=[NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"theme.json"]];
    NSDictionary *json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSDictionary *palette=[json isKindOfClass:NSDictionary.class]?json[@"palette"]:nil;
    if (![palette isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"idle",@"pressed",@"outline",@"ringFill",@"text",@"pressedText"])
        if (!themeHex(palette[key])) return nil;
    return json;
}
- (BOOL)loadThemeAtPath:(NSString *)path {
    if (!path.length) return NO;
    NSData *data=[NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"theme.json"]];
    if (!data) return NO;
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *palette=json[@"palette"], *buttons=json[@"buttons"];
    if (![palette isKindOfClass:NSDictionary.class]) return NO;
    UIColor *idle=themeHex(palette[@"idle"]), *pressed=themeHex(palette[@"pressed"]);
    UIColor *outline=themeHex(palette[@"outline"]), *ring=themeHex(palette[@"ringFill"]);
    UIColor *text=themeHex(palette[@"text"]), *pressedText=themeHex(palette[@"pressedText"]);
    if (!idle || !pressed || !outline || !ring || !text || !pressedText) return NO;
    NSMutableDictionary *parsed=[NSMutableDictionary dictionary];
    if ([buttons isKindOfClass:NSDictionary.class]) for (NSString *key in buttons) {
        UIColor *color=themeHex(buttons[key]); if (color) parsed[key]=color;
    }
    k_idle=[idle colorWithAlphaComponent:0.36]; k_on=[pressed colorWithAlphaComponent:0.92];
    k_line=[outline colorWithAlphaComponent:0.88]; k_ringFill=[ring colorWithAlphaComponent:0.25];
    k_text=[text colorWithAlphaComponent:0.96]; k_textOn=pressedText;
    _themeButtonColors=parsed;
    _themeName=[json[@"name"] isKindOfClass:NSString.class] && [json[@"name"] length] ? json[@"name"] : path.lastPathComponent;
    return YES;
}
- (BOOL)loadSelectedTheme {
    NSString *path=[NSUserDefaults.standardUserDefaults stringForKey:k_theme_path_key];
    if (path.length && [self loadThemeAtPath:path]) return YES;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:k_theme_path_key];
    [NSUserDefaults.standardUserDefaults setObject:@"Classic" forKey:k_theme_name_key];
    _themeName=@"Classic"; _themeButtonColors=@{}; theme_init(); return NO;
}
- (UIColor *)themeColorForButton:(int)b pressed:(BOOL)pressed {
    NSString *key=nil;
    switch (b) {
        case B_A:key=@"A";break; case B_B:key=@"B";break; case B_X:key=@"X";break; case B_Y:key=@"Y";break;
        case B_LS:case B_RS:key=@"Stick";break; case B_L:key=@"L";break; case B_R:key=@"R";break;
        case B_ZL:key=@"ZL";break; case B_ZR:key=@"ZR";break; case B_PLUS:key=@"Plus";break;
        case B_MINUS:key=@"Minus";break; default:if (b>=B_LEFT) key=@"Dpad";break;
    }
    UIColor *base=key ? _themeButtonColors[key] : nil;
    if (!base && b==B_N) base=_themeButtonColors[@"Layout"];
    if (!base) return pressed ? k_on : k_idle;
    return [base colorWithAlphaComponent:pressed ? 0.92 : 0.36];
}
- (void)applyThemePath:(NSString *)path name:(NSString *)name {
    if (![self loadThemeAtPath:path]) return;
    [NSUserDefaults.standardUserDefaults setObject:path forKey:k_theme_path_key];
    [NSUserDefaults.standardUserDefaults setObject:_themeName ?: name forKey:k_theme_name_key];
    [self refresh]; [self setNeedsLayout]; [self layoutIfNeeded]; [self updateEditor];
}
- (void)updateThemeMenu {
    NSString *current=[NSUserDefaults.standardUserDefaults stringForKey:k_theme_name_key] ?: @"Classic";
    [_themeButton setTitle:[NSString stringWithFormat:@"Theme: %@ ▾",current] forState:UIControlStateNormal];
    NSMutableArray *items=[NSMutableArray array];
    UIAction *classic=[UIAction actionWithTitle:@"Classic" image:nil identifier:nil handler:^(__unused UIAction *a) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:k_theme_path_key];
        [NSUserDefaults.standardUserDefaults setObject:@"Classic" forKey:k_theme_name_key];
        self->_themeName=@"Classic"; self->_themeButtonColors=@{}; theme_init();
        [self refresh]; [self updateEditor];
    }];
    classic.state=[current isEqualToString:@"Classic"]?UIMenuElementStateOn:UIMenuElementStateOff; [items addObject:classic];
    NSArray<NSURL *> *folders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[self themesDirectoryCreating:YES]
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL *folder in folders) {
        BOOL isDir=NO; if (![NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&isDir] || !isDir) continue;
        NSString *themePath=folder.path;
        NSData *data=[NSData dataWithContentsOfFile:[themePath stringByAppendingPathComponent:@"theme.json"]];
        NSDictionary *json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        json=[self validThemeJSONAtFolder:folder];
        if (!json) continue;
        NSString *title=[json[@"name"] isKindOfClass:NSString.class] && [json[@"name"] length] ? json[@"name"] : folder.lastPathComponent;
        UIAction *pick=[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *a) {
            [self applyThemePath:themePath name:title];
        }];
        pick.state=[current isEqualToString:title]?UIMenuElementStateOn:UIMenuElementStateOff; [items addObject:pick];
    }
    _themeButton.menu=[UIMenu menuWithTitle:@"Touch Control Theme" children:items];
    _themeButton.showsMenuAsPrimaryAction=YES;
}
- (void)importThemeFolder {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"] inMode:UIDocumentPickerModeOpen];
    picker.delegate=self;
    UIViewController *presenter=[self editorPresenter];
    if (presenter) [presenter presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *source=urls.firstObject; if (!source) return;
    BOOL scoped=[source startAccessingSecurityScopedResource];
    @try {
        // Accept either the individual theme folder or a parent folder containing exactly one
        // valid theme folder (for example, importing TouchControlThemes/Forest).
        NSURL *themeFolder=source;
        NSDictionary *json=[self validThemeJSONAtFolder:themeFolder];
        if (!json) {
            NSMutableArray<NSURL *> *valid=[NSMutableArray array];
            NSDirectoryEnumerator<NSURL *> *enumerator=[NSFileManager.defaultManager enumeratorAtURL:source
                includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles
                errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return YES; }];
            for (NSURL *entry in enumerator) {
                if (![entry.lastPathComponent isEqualToString:@"theme.json"]) continue;
                NSURL *candidate=[entry URLByDeletingLastPathComponent];
                if ([self validThemeJSONAtFolder:candidate] && ![valid containsObject:candidate]) [valid addObject:candidate];
            }
            if (valid.count==1) {
                themeFolder=valid.firstObject;
                json=[self validThemeJSONAtFolder:themeFolder];
            }
        }
        if (!json) {
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Invalid Theme Folder"
                message:@"Choose a theme folder containing theme.json with all six palette colors. You can also choose a parent folder if it contains one theme folder."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [[self editorPresenter] presentViewController:alert animated:YES completion:nil]; return;
        }
        NSString *folderName=[json[@"name"] isKindOfClass:NSString.class] && [json[@"name"] length]?json[@"name"]:themeFolder.lastPathComponent;
        NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-"];
        NSMutableString *safeBuffer=[NSMutableString string];
        for (NSUInteger i=0;i<folderName.length;i++) {
            unichar ch=[folderName characterAtIndex:i];
            [safeBuffer appendFormat:@"%C",[allowed characterIsMember:ch] ? ch : '_'];
        }
        NSString *safeName=[safeBuffer stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ._"]];
        if (!safeName.length) safeName=@"Imported Theme";
        NSURL *destination=[[self themesDirectoryCreating:YES] URLByAppendingPathComponent:safeName isDirectory:YES];
        NSFileManager *fm=NSFileManager.defaultManager; NSError *error=nil;
        if ([fm fileExistsAtPath:destination.path]) [fm removeItemAtURL:destination error:nil];
        if (![fm copyItemAtURL:themeFolder toURL:destination error:&error]) {
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Theme Import Failed" message:error.localizedDescription
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [[self editorPresenter] presentViewController:alert animated:YES completion:nil]; return;
        }
        [self applyThemePath:destination.path name:safeName];
    } @finally { if (scoped) [source stopAccessingSecurityScopedResource]; }
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }

// ---- In-game touch-control editor and named profiles ----
- (UIButton *)editorButton:(NSString *)title action:(SEL)action frame:(CGRect)frame parent:(UIView *)parent {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; button.frame=frame;
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.96];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; button.layer.cornerRadius=6;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:button]; return button;
}
- (void)setupEditor {
    _tools=[UIView new]; _tools.backgroundColor=[UIColor colorWithWhite:0 alpha:0.92]; _tools.layer.cornerRadius=10;
    [self addSubview:_tools]; _tools.hidden=YES;
    _profileButton=[self editorButton:@"Profile" action:NULL frame:CGRectMake(8,8,192,32) parent:_tools];
    _profileButton.titleLabel.adjustsFontSizeToFitWidth=YES; _profileButton.titleLabel.minimumScaleFactor=0.75;
    _saveAsButton=[self editorButton:@"Save as…" action:NULL frame:CGRectMake(208,8,104,32) parent:_tools];
    [self editorButton:@"Save" action:@selector(saveEdit) frame:CGRectMake(8,48,90,32) parent:_tools];
    [self editorButton:@"Cancel" action:@selector(cancelEdit) frame:CGRectMake(110,48,90,32) parent:_tools];
    [self editorButton:@"Reset all" action:@selector(resetAllControls) frame:CGRectMake(212,48,100,32) parent:_tools];
    _chooseButton=[self editorButton:@"A ▾" action:NULL frame:CGRectMake(8,86,145,30) parent:_tools];
    [self editorButton:@"Reset control" action:@selector(resetControl) frame:CGRectMake(163,86,149,30) parent:_tools];
    _sizeSlider=[[UISlider alloc] initWithFrame:CGRectMake(78,120,230,30)];
    _sizeSlider.minimumValue=0.5; _sizeSlider.maximumValue=2;
    _alphaSlider=[[UISlider alloc] initWithFrame:CGRectMake(78,152,230,30)];
    _alphaSlider.minimumValue=0; _alphaSlider.maximumValue=1;
    UIColor *accent=[self editorAccentColor];
    // Match SwiftUI Slider.tint(accentColor): tint only the filled track.
    _sizeSlider.minimumTrackTintColor=accent;
    _alphaSlider.minimumTrackTintColor=accent;
    [_sizeSlider addTarget:self action:@selector(adjustControl) forControlEvents:UIControlEventValueChanged];
    [_alphaSlider addTarget:self action:@selector(adjustOpacityControl) forControlEvents:UIControlEventValueChanged];
    [_tools addSubview:_sizeSlider]; [_tools addSubview:_alphaSlider];
    for (int i=0;i<2;i++) {
        UILabel *labelView=[[UILabel alloc] initWithFrame:CGRectMake(8,120+32*i,70,30)];
        labelView.text=i?@"Opacity":@"Size"; labelView.textColor=UIColor.whiteColor;
        labelView.font=[UIFont systemFontOfSize:13]; [_tools addSubview:labelView];
    }
    _editInfo=[[UILabel alloc] initWithFrame:CGRectMake(8,184,304,32)];
    _editInfo.numberOfLines=2; _editInfo.font=[UIFont systemFontOfSize:11];
    _editInfo.textColor=UIColor.whiteColor; [_tools addSubview:_editInfo];
    _themeButton=[self editorButton:@"Theme: Classic ▾" action:NULL frame:CGRectMake(8,220,190,32) parent:_tools];
    UIButton *importThemeButton=[self editorButton:@"Import Theme…" action:@selector(importThemeFolder) frame:CGRectMake(204,220,108,32) parent:_tools];
    importThemeButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    importThemeButton.titleLabel.adjustsFontSizeToFitWidth=YES;
    importThemeButton.titleLabel.minimumScaleFactor=0.8;
    importThemeButton.titleLabel.lineBreakMode=NSLineBreakByClipping;

    UILabel *fpsTitle=[[UILabel alloc] initWithFrame:CGRectMake(10,260,210,28)];
    fpsTitle.text=@"FPS counter"; fpsTitle.textColor=UIColor.whiteColor;
    fpsTitle.font=[UIFont systemFontOfSize:13]; [_tools addSubview:fpsTitle];
    _fpsSwitch=[[UISwitch alloc] initWithFrame:CGRectMake(254,258,52,31)];
    _fpsSwitch.on=front_ios_runtime_fps_enabled();
    [_fpsSwitch addTarget:self action:@selector(editorHUDChanged) forControlEvents:UIControlEventValueChanged];
    [_tools addSubview:_fpsSwitch];

    UILabel *hudTitle=[[UILabel alloc] initWithFrame:CGRectMake(10,294,210,28)];
    hudTitle.text=@"Performance HUD"; hudTitle.textColor=UIColor.whiteColor;
    hudTitle.font=[UIFont systemFontOfSize:13]; [_tools addSubview:hudTitle];
    _hudSwitch=[[UISwitch alloc] initWithFrame:CGRectMake(254,292,52,31)];
    _hudSwitch.on=front_ios_runtime_metal_hud_enabled();
    [_hudSwitch addTarget:self action:@selector(editorHUDChanged) forControlEvents:UIControlEventValueChanged];
    [_tools addSubview:_hudSwitch];
}
- (void)editorHUDChanged {
    front_ios_set_runtime_hud(_fpsSwitch.on, _hudSwitch.on);
}
- (void)updateEditor {
    [self updateProfileMenu];
    [self updateThemeMenu];
    if (_selected<0) {
        CGFloat scale=0,alpha=0; NSInteger count=0;
        for (int b=0;b<18;b++) if ([self editable:b]) {
            scale += [self scale:b];
            NSNumber *saved=_custom[[self controlID:b]][@"alpha"];
            alpha += saved ? saved.floatValue : 1.0;
            count++;
        }
        _sizeSlider.value=count?scale/count:1;
        _alphaSlider.value=count?alpha/count:1;
        [_chooseButton setTitle:@"All controls ▾" forState:UIControlStateNormal];
    } else {
        [_chooseButton setTitle:[NSString stringWithFormat:@"%@ ▾",[self controlID:_selected]] forState:UIControlStateNormal];
        _sizeSlider.value=[self scale:_selected];
        NSNumber *alpha=_custom[[self controlID:_selected]][@"alpha"];
        _alphaSlider.value=alpha?alpha.floatValue:1;
    }
    _editInfo.text=[NSString stringWithFormat:@"Size %.0f%% · Opacity %.0f%%\nDrag a control to move it.",_sizeSlider.value*100,_alphaSlider.value*100];
    NSMutableArray *actions=[NSMutableArray array];
    [actions addObject:[UIAction actionWithTitle:@"All controls" image:nil identifier:nil
        handler:^(__kindof UIAction *action) { (void)action; self->_selected=-1; [self updateEditor]; }]];
    for (int b=0;b<18;b++) if ([self editable:b]) {
        int selected=b;
        [actions addObject:[UIAction actionWithTitle:[self controlID:b] image:nil identifier:nil
            handler:^(__kindof UIAction *action) { (void)action; self->_selected=selected; [self updateEditor]; }]];
    }
    _chooseButton.menu=[UIMenu menuWithTitle:@"Select control" children:actions];
    _chooseButton.showsMenuAsPrimaryAction=YES; [self setNeedsLayout];
}
- (UIViewController *)editorPresenter {
    UIResponder *responder=self;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder=responder.nextResponder;
    UIViewController *presenter=(UIViewController *)responder;
    while (presenter.presentedViewController) presenter=presenter.presentedViewController;
    return presenter;
}
- (void)confirm:(NSString *)message actionTitle:(NSString *)title action:(void (^)(void))done {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:message message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { done(); }]];
    UIViewController *presenter=[self editorPresenter];
    if (presenter) [presenter presentViewController:alert animated:YES completion:nil]; else done();
}
- (void)selectProfile:(NSInteger)slot {
    if (slot==_profiles.selected) return;
    void (^change)(void)=^{ [self reset]; self->_dragTouch=nil; [self->_profiles select:slot]; [self loadControls]; [self updateEditor]; [self setNeedsLayout]; };
    if (![_custom isEqual:[_profiles controls:self.controlsLayout slot:_profiles.selected]])
        [self confirm:@"Discard unsaved changes?" actionTitle:@"Switch profile" action:change];
    else change();
}
- (void)renameProfile {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Name this profile"
        message:@"Use 1–32 characters (for example, Large buttons)." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text=[self->_profiles name:self->_profiles.selected]; field.clearButtonMode=UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (![self->_profiles rename:self->_profiles.selected name:weakAlert.textFields.firstObject.text ?: @""])
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,@"Use a name between 1 and 32 characters.");
        [self updateEditor];
    }]];
    UIViewController *presenter=[self editorPresenter];
    if (presenter) [presenter presentViewController:alert animated:YES completion:nil];
}
- (void)updateProfileMenu {
    [_profileButton setTitle:[NSString stringWithFormat:@"%@ ▾",[_profiles name:_profiles.selected]] forState:UIControlStateNormal];
    NSMutableArray *profiles=[NSMutableArray array], *copies=[NSMutableArray array];
    for (NSInteger slot=0;slot<4;slot++) {
        NSInteger target=slot;
        UIAction *pick=[UIAction actionWithTitle:[_profiles name:slot] image:nil identifier:nil
            handler:^(__unused UIAction *action) { [self selectProfile:target]; }];
        pick.state=slot==_profiles.selected?UIMenuElementStateOn:UIMenuElementStateOff; [profiles addObject:pick];
        if (slot!=_profiles.selected) [copies addObject:[UIAction actionWithTitle:[_profiles name:slot] image:nil identifier:nil
            handler:^(__unused UIAction *action) {
                NSString *message=[NSString stringWithFormat:@"Replace %@ with this profile?",[self->_profiles name:target]];
                [self confirm:message actionTitle:@"Save copy" action:^{
                    [self reset]; self->_dragTouch=nil;
                    [self->_profiles copySlot:self->_profiles.selected to:target draft:self->_custom layout:self.controlsLayout];
                    [self loadControls]; [self updateEditor]; [self setNeedsLayout];
                }];
            }]];
    }
    UIAction *rename=[UIAction actionWithTitle:@"Rename…" image:nil identifier:nil
        handler:^(__unused UIAction *action) { [self renameProfile]; }];
    [profiles addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[rename]]];
    _profileButton.menu=[UIMenu menuWithTitle:@"Control profiles" children:profiles]; _profileButton.showsMenuAsPrimaryAction=YES;
    _saveAsButton.menu=[UIMenu menuWithTitle:@"Save a copy to" children:copies]; _saveAsButton.showsMenuAsPrimaryAction=YES;
}
- (void)beginLauncherEdit {
    // The launcher preview is not a live gamepad session. Keep editing available
    // even when a physical controller is connected to the phone.
    _padOff=NO;
    [self toggleEditor];
}
- (void)toggleEditor {
    if (_editing) { _tools.hidden=!_tools.hidden; return; }
    _editWasTap=_tap;
    if (_tap) { _tap=NO; [self loadControls]; [self applyLayout]; }
    [self reset]; _editing=YES; _controls.hidden=_padOff; _selected=B_A; _tools.hidden=NO;
    [self updateEditor]; [self setNeedsLayout];
}
- (void)openMenuFromController {
    if (_padOff && !_editing) [self toggleEditor];
    else if (_editing) [self toggleEditor];
}
- (void)finishEdit {
    [self reset]; _editing=NO;
    if (_editWasTap) { _tap=YES; [self applyLayout]; }
    _tools.hidden=YES; _controls.hidden=_padOff;
    _editHighlight.hidden=YES; [self setNeedsLayout];
}
- (void)saveEdit { [_profiles save:_custom layout:self.controlsLayout slot:_profiles.selected]; [self finishEdit]; }
- (void)cancelEdit { [self loadControls]; [self finishEdit]; }
- (void)resetAllControls { [_custom removeAllObjects]; [self updateEditor]; [self setNeedsLayout]; }
- (void)resetControl {
    if (_selected<0) {
        for (int b=0;b<18;b++) if ([self editable:b]) [_custom removeObjectForKey:[self controlID:b]];
    } else [_custom removeObjectForKey:[self controlID:_selected]];
    [self updateEditor]; [self setNeedsLayout];
}
- (void)storeControlAt:(CGPoint)point {
    CGRect safe=self.safe; if (safe.size.width<=0 || safe.size.height<=0) return;
    if (_selected<0 && _dragAllHomes.count) {
        CGPoint delta=CGPointMake(point.x-_dragHome.x,point.y-_dragHome.y);
        for (NSString *key in _dragAllHomes) {
            int b=(int)[key integerValue]; CGPoint home=_dragAllHomes[key].CGPointValue;
            CGFloat margin=(b==16?K_STICK_R:b==17?K_DPAD_R:isDrop(b)?38:isClick(b)?22:28)*self.u*[self scale:b];
            CGPoint moved=dm_pad_clamp(CGPointMake(home.x+delta.x,home.y+delta.y),safe,margin);
            NSMutableDictionary *value=[_custom[key] mutableCopy] ?: [NSMutableDictionary dictionary];
            value[@"x"]=@((moved.x-safe.origin.x)/safe.size.width);
            value[@"y"]=@((moved.y-safe.origin.y)/safe.size.height);
            _custom[key]=value;
        }
    } else {
        CGFloat margin=(_selected==16?K_STICK_R:_selected==17?K_DPAD_R:isDrop(_selected)?38:isClick(_selected)?22:28)*self.u*_sizeSlider.value;
        point=dm_pad_clamp(point,safe,margin);
        _custom[[self controlID:_selected]]=@{@"x":@((point.x-safe.origin.x)/safe.size.width),
            @"y":@((point.y-safe.origin.y)/safe.size.height),@"scale":@(_sizeSlider.value),@"alpha":@(_alphaSlider.value)};
    }
    [self setNeedsLayout]; [self refresh];
}
- (void)adjustControl {
    float requestedScale=_sizeSlider.value;
    if (_selected<0) {
        for (int b=0;b<18;b++) if ([self editable:b]) {
            NSString *key=[self controlID:b]; NSMutableDictionary *value=[_custom[key] mutableCopy] ?: [NSMutableDictionary dictionary];
            value[@"scale"]=@(requestedScale); _custom[key]=value;
        }
    } else {
        NSString *key=[self controlID:_selected];
        NSMutableDictionary *value=[_custom[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        value[@"scale"]=@(requestedScale); _custom[key]=value;
    }
    _editInfo.text=[NSString stringWithFormat:@"Size %.0f%% · Opacity %.0f%%\nDrag a control to move it.",requestedScale*100,_alphaSlider.value*100];
    [self setNeedsLayout]; [self layoutIfNeeded]; [self refresh];
}
- (void)adjustOpacityControl {
    float requestedAlpha=_alphaSlider.value;
    if (_selected<0) {
        for (int b=0;b<18;b++) if ([self editable:b]) {
            NSString *key=[self controlID:b]; NSMutableDictionary *value=[_custom[key] mutableCopy] ?: [NSMutableDictionary dictionary];
            value[@"alpha"]=@(requestedAlpha); _custom[key]=value;
        }
    } else {
        NSString *key=[self controlID:_selected];
        NSMutableDictionary *value=[_custom[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        value[@"alpha"]=@(requestedAlpha); _custom[key]=value;
    }
    _editInfo.text=[NSString stringWithFormat:@"Size %.0f%% · Opacity %.0f%%\nDrag a control to move it.",_sizeSlider.value*100,requestedAlpha*100];
    [self refresh];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer!=_editHold || _padOff || _editing || _tap) return NO;
    return [self inSwap:[touch locationInView:self]];
}
- (void)handleEditHold:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan && !_padOff && !_tap && !_editing) [self toggleEditor];
}
- (UIColor *)editorAccentColor {
    UIImage *icon=[UIImage imageNamed:@"AppIcon"];
    if (!icon) {
        NSDictionary *icons=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleIcons"];
        NSDictionary *primary=icons[@"CFBundlePrimaryIcon"];
        NSArray *files=primary[@"CFBundleIconFiles"];
        if (files.count) icon=[UIImage imageNamed:files.lastObject];
    }
    CGImageRef cg=icon.CGImage; if (!cg) return [UIColor colorWithRed:0.25 green:0.48 blue:0.85 alpha:1];
    const size_t width=32,height=32,bpp=4,bpr=width*bpp;
    uint8_t pixels[height*bpr]; memset(pixels,0,sizeof pixels);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(pixels,width,height,8,bpr,space,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space); if (!context) return [UIColor colorWithRed:0.25 green:0.48 blue:0.85 alpha:1];
    CGContextSetInterpolationQuality(context,kCGInterpolationLow);
    CGContextDrawImage(context,CGRectMake(0,0,width,height),cg); CGContextRelease(context);
    NSMutableDictionary<NSNumber *,NSMutableArray<NSNumber *> *> *buckets=[NSMutableDictionary dictionary];
    for (NSUInteger offset=0;offset<sizeof pixels;offset+=bpp) {
        int alpha=pixels[offset+3]; if(alpha<=64) continue;
        int red=pixels[offset],green=pixels[offset+1],blue=pixels[offset+2];
        int brightness=(red*299+green*587+blue*114)/1000;
        int maximum=MAX(red,MAX(green,blue)),minimum=MIN(red,MIN(green,blue));
        if(brightness<=18||brightness>=248||maximum-minimum<=18) continue;
        int key=((red>>3)<<10)|((green>>3)<<5)|(blue>>3);
        NSNumber *bucketKey=@(key); NSMutableArray *bucket=buckets[bucketKey];
        if(!bucket){bucket=[NSMutableArray arrayWithObjects:@0,@0,@0,@0,nil];buckets[bucketKey]=bucket;}
        bucket[0]=@([bucket[0] intValue]+red); bucket[1]=@([bucket[1] intValue]+green);
        bucket[2]=@([bucket[2] intValue]+blue); bucket[3]=@([bucket[3] intValue]+1);
    }
    NSArray *dominant=nil;
    for(NSArray *bucket in buckets.allValues) if(!dominant||[bucket[3] intValue]>[dominant[3] intValue]) dominant=bucket;
    if(!dominant||![dominant[3] intValue]) return [UIColor colorWithRed:0.25 green:0.48 blue:0.85 alpha:1];
    CGFloat divisor=[dominant[3] doubleValue]*255.0;
    return [UIColor colorWithRed:[dominant[0] doubleValue]/divisor
                           green:[dominant[1] doubleValue]/divisor
                            blue:[dominant[2] doubleValue]/divisor alpha:1];
}
- (void)editTouches:(NSSet<UITouch *> *)touches began:(BOOL)began {
    if (began && !_dragTouch) {
        UITouch *touch=touches.anyObject; CGPoint start=[touch locationInView:self];
        CGFloat best=44*self.u; NSInteger closest=-1;
        for (int b=0;b<18;b++) if ([self editable:b]) {
            CGFloat distance=dist(start,[self controlCenter:b]);
            if (distance<best) { best=distance; closest=b; }
        }
        if (closest<0) return;
        BOOL allSelected=(_selected<0);
        _dragTouch=touch; _dragStart=start; _dragHome=[self controlCenter:(int)closest];
        if (allSelected) {
            NSMutableDictionary *homes=[NSMutableDictionary dictionary];
            for (int b=0;b<18;b++) if ([self editable:b]) homes[[self controlID:b]]=[NSValue valueWithCGPoint:[self controlCenter:b]];
            _dragAllHomes=[homes copy];
        } else { _selected=(int)closest; _dragAllHomes=nil; }
        [self updateEditor]; return;
    }
    if (_dragTouch && [touches containsObject:_dragTouch]) {
        CGPoint point=[_dragTouch locationInView:self];
        [self storeControlAt:CGPointMake(_dragHome.x+point.x-_dragStart.x,_dragHome.y+point.y-_dragStart.y)];
    }
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_watch_select(GCController *c) {
    GCControllerButtonInput *select=c.extendedGamepad.buttonOptions;
    if (!select) return;
    __weak GCControllerButtonInput *weakSelect=select;
    select.pressedChangedHandler=^(__kindof GCControllerButtonInput *button, float value, BOOL pressed) {
        (void)button; (void)value;
        if (!pressed) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GCControllerButtonInput *held=weakSelect;
            if (held && held.isPressed) [g_view openMenuFromController];
        });
    };
}
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); pad_watch_select(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c); pad_watch_select(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_padOff=any; self->_controls.hidden=any;
        if (any && self->_editing) [self finishEdit];
        [self reset];
    });   // the touch gamepad hides while any controller is in use
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

@interface DmPadLauncherEditorController : UIViewController
@property(nonatomic,strong) DmGamepad *pad;
@property(nonatomic,strong) UIButton *closeButton;
@property(nonatomic,strong) UIImageView *backgroundImageView;
@property(nonatomic,strong) UIView *backgroundDimmer;
@end
@implementation DmPadLauncherEditorController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.blackColor;
    self.view.alpha=0;

    // Reuse the launcher's artwork, but leave only a faint trace of it under the editor.
    NSURL *backgroundURL=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"dm/launcher-custom-background.png"];
    UIImage *background=backgroundURL ? [UIImage imageWithContentsOfFile:backgroundURL.path] : nil;
    if (background) {
        // Match LauncherView's resizable, scaled-to-fill image: pin both layers to
        // the full-screen view bounds so safe-area insets cannot shift the crop.
        _backgroundImageView=[UIImageView new];
        _backgroundImageView.image=background;
        _backgroundImageView.contentMode=UIViewContentModeScaleAspectFill;
        _backgroundImageView.clipsToBounds=YES;
        _backgroundImageView.translatesAutoresizingMaskIntoConstraints=NO;
        [self.view addSubview:_backgroundImageView];
        _backgroundDimmer=[UIView new];
        _backgroundDimmer.backgroundColor=[UIColor colorWithWhite:0 alpha:0.86];
        _backgroundDimmer.translatesAutoresizingMaskIntoConstraints=NO;
        [self.view addSubview:_backgroundDimmer];
        [NSLayoutConstraint activateConstraints:@[
            [_backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [_backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [_backgroundDimmer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [_backgroundDimmer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [_backgroundDimmer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [_backgroundDimmer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
        ]];
    }

    g_launcher_preview=YES;
    _pad=[[DmGamepad alloc] initWithFrame:self.view.bounds];
    g_launcher_preview=NO;
    _pad.backgroundColor=UIColor.clearColor;
    _pad.opaque=NO;
    _pad.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_pad];
    _closeButton=[UIButton buttonWithType:UIButtonTypeSystem];
    _closeButton.frame=CGRectMake(0,0,76,36);
    _closeButton.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleBottomMargin;
    [_closeButton setTitle:@"Done" forState:UIControlStateNormal];
    UIColor *doneAccent=[_pad editorAccentColor];
    CGFloat red=0, green=0, blue=0, alpha=1;
    [doneAccent getRed:&red green:&green blue:&blue alpha:&alpha];
    CGFloat luminance=0.2126*red+0.7152*green+0.0722*blue;
    [_closeButton setTitleColor:(luminance>0.58?UIColor.blackColor:UIColor.whiteColor) forState:UIControlStateNormal];
    _closeButton.backgroundColor=doneAccent;
    _closeButton.layer.cornerRadius=7;
    [_closeButton addTarget:self action:@selector(closeEditor) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_closeButton];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _pad.frame=self.view.bounds;
    _closeButton.frame=CGRectMake(CGRectGetWidth(self.view.bounds)-88, self.view.safeAreaInsets.top+8, 76, 36);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UIView *launcher=self.presentingViewController.view;
    [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha=1;
        launcher.alpha=0;
    } completion:^(__unused BOOL finished) {
        [self.pad beginLauncherEdit];
    }];
}
- (void)closeEditor {
    [_pad saveEdit];
    UIView *launcher=self.presentingViewController.view;
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha=0;
        launcher.alpha=1;
    } completion:^(__unused BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }];
}
@end

void dm_gamepad_present_launcher_editor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window=nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) { window=candidate; break; }
            if (window) break;
        }
        UIViewController *presenter=window.rootViewController;
        while (presenter.presentedViewController) presenter=presenter.presentedViewController;
        if (!presenter) return;
        DmPadLauncherEditorController *editor=[DmPadLauncherEditorController new];
        editor.modalPresentationStyle=UIModalPresentationOverFullScreen;
        editor.modalTransitionStyle=UIModalTransitionStyleCrossDissolve;
        presenter.view.alpha=1;
        [presenter presentViewController:editor animated:NO completion:nil];
    });
}

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
