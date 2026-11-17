// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre ("2D" / "3D" / "Tap") switches layouts, while pressing and holding it opens the in-game control menu. The choice is kept per game; the first launch uses pad_layout (DM_GAME_PAD_LAYOUT).
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

@interface DmPaddedTipLabel : UILabel
@property(nonatomic) UIEdgeInsets textInsets;
@end
@implementation DmPaddedTipLabel
- (CGRect)textRectForBounds:(CGRect)bounds limitedToNumberOfLines:(NSInteger)numberOfLines {
    CGRect inset=UIEdgeInsetsInsetRect(bounds,self.textInsets);
    CGRect text=[super textRectForBounds:inset limitedToNumberOfLines:numberOfLines];
    text.origin.x-=self.textInsets.left; text.origin.y-=self.textInsets.top;
    text.size.width+=self.textInsets.left+self.textInsets.right;
    text.size.height+=self.textInsets.top+self.textInsets.bottom;
    return text;
}
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect,self.textInsets)];
}
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize inner=CGSizeMake(MAX(0,size.width-self.textInsets.left-self.textInsets.right),
                            MAX(0,size.height-self.textInsets.top-self.textInsets.bottom));
    CGSize measured=[super sizeThatFits:inner];
    return CGSizeMake(measured.width+self.textInsets.left+self.textInsets.right,
                      measured.height+self.textInsets.top+self.textInsets.bottom);
}
@end

@interface DmColorPickerPresentationController : UIPresentationController
@property(nonatomic,strong) UIView *dimmingView;
@end

@implementation DmColorPickerPresentationController
- (instancetype)initWithPresentedViewController:(UIViewController *)presented presentingViewController:(UIViewController *)presenting {
    self=[super initWithPresentedViewController:presented presentingViewController:presenting];
    if (self) {
        _dimmingView=[UIView new];
        _dimmingView.backgroundColor=[UIColor colorWithWhite:0 alpha:0.22];
        _dimmingView.alpha=0;
        UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPicker)];
        [_dimmingView addGestureRecognizer:tap];
    }
    return self;
}
- (CGRect)frameOfPresentedViewInContainerView {
    CGRect bounds=self.containerView.bounds;
    CGFloat width=MIN(340,MAX(280,bounds.size.width-32));
    CGFloat height=MIN(520,MAX(380,bounds.size.height-80));
    return CGRectMake(CGRectGetMidX(bounds)-width/2,CGRectGetMidY(bounds)-height/2,width,height);
}
- (void)containerViewWillLayoutSubviews {
    [super containerViewWillLayoutSubviews];
    self.dimmingView.frame=self.containerView.bounds;
    self.presentedView.frame=self.frameOfPresentedViewInContainerView;
    // Give the floating picker a solid dark surface so transparent areas in
    // UIColorPickerViewController do not show the dimmed game underneath.
    self.presentedView.backgroundColor=[UIColor colorWithWhite:0.075 alpha:1.0];
    self.presentedViewController.view.backgroundColor=[UIColor colorWithWhite:0.075 alpha:1.0];
    self.presentedView.layer.cornerRadius=14;
    self.presentedView.layer.borderWidth=1;
    self.presentedView.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.14].CGColor;
    self.presentedView.layer.masksToBounds=YES;
}
- (void)presentationTransitionWillBegin {
    [super presentationTransitionWillBegin];
    self.dimmingView.frame=self.containerView.bounds;
    [self.containerView insertSubview:self.dimmingView atIndex:0];

    // Drive the dimming from the same transition coordinator as the picker,
    // so both animations begin, progress, and finish together.
    id<UIViewControllerTransitionCoordinator> coordinator=self.presentedViewController.transitionCoordinator;
    if (!coordinator) coordinator=self.presentingViewController.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimmingView.alpha=1;
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimmingView.alpha=context.isCancelled ? 0 : 1;
        }];
    } else {
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.dimmingView.alpha=1;
        } completion:nil];
    }
}
- (void)dismissalTransitionWillBegin {
    [super dismissalTransitionWillBegin];

    id<UIViewControllerTransitionCoordinator> coordinator=self.presentedViewController.transitionCoordinator;
    if (!coordinator) coordinator=self.presentingViewController.transitionCoordinator;
    if (coordinator) {
        [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimmingView.alpha=0;
        } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
            self.dimmingView.alpha=context.isCancelled ? 1 : 0;
        }];
    } else {
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self.dimmingView.alpha=0;
        } completion:nil];
    }
}
- (void)dismissPicker {
    [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
}
@end

@interface DmColorPickerTransitionDelegate : NSObject <UIViewControllerTransitioningDelegate>
@end
@implementation DmColorPickerTransitionDelegate
- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                        presentingViewController:(UIViewController *)presenting
                                                            sourceViewController:(UIViewController *)source {
    (void)source;
    return [[DmColorPickerPresentationController alloc] initWithPresentedViewController:presented presentingViewController:presenting];
}
@end

@interface DmGamepad : UIView <UIGestureRecognizerDelegate, UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate>
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
    UITouch *_stick[2]; CGPoint _stickNow[2], _stickTouchOrigin[2]; // touch, current point, and initial anchor for each stick
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
    NSString *_themePath;
    UIButton *_themeButton;
    UIButton *_colorWellButton;
    UIColor *_editorColor;
    UIColorPickerViewController *_editorColorPicker;
    DmColorPickerTransitionDelegate *_colorPickerTransitionDelegate;
    UIView *_colorWellAppearance;
    UIView *_colorWellSwatch;
    CAGradientLayer *_colorWellRainbowBorder;
    UIImageView *_colorWellLockIcon;
    int _colorPickerControl;
    NSInteger _colorTarget; // 0 = fill, 1 = border, 2 = left-stick track
    UIButton *_colorTargetButton;
    NSMutableDictionary *_custom;
    DmPadProfiles *_profiles;
    BOOL _editing, _editWasTap;
    BOOL _launcherPreview;
    int _selected;
    UITouch *_dragTouch;
    CGPoint _dragStart, _dragHome;
    CGRect _lastSafe;
    UIButton *_chooseButton, *_profileButton, *_saveAsButton, *_resetControlButton;
    DmPaddedTipLabel *_menuTip;
    CAShapeLayer *_menuTipBubble;
    BOOL _launcherReopenTip;
    UILongPressGestureRecognizer *_editHold;
    UIView *_tools;
    UISlider *_sizeSlider, *_alphaSlider;
    UIButton *_fpsButton, *_hudButton;
    UIButton *_themeMenuOverlay;
    UIView *_themeMenuPanel;
    UIScrollView *_themeMenuScroll;
    UIButton *_editorPopupOverlay;
    UIView *_editorPopupPanel;
    UIScrollView *_editorPopupScroll;
    UILabel *_editorPopupTitle;
    UILabel *_editInfo;
    CAShapeLayer *_editHighlight;
    NSDictionary<NSString *, NSValue *> *_dragAllHomes;
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_stickTrack, *k_stickBorder, *k_text, *k_textOn;
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
static id themePaletteValue(NSDictionary *palette, NSString *key) {
    id value=palette[key];
    if (value) return value;
    for (id candidate in palette)
        if ([candidate isKindOfClass:NSString.class] && [candidate caseInsensitiveCompare:key]==NSOrderedSame)
            return palette[candidate];
    return nil;
}
static void theme_init(void) {
    k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45];
    k_line = [UIColor colorWithWhite:1 alpha:0.38]; k_ringFill = [UIColor colorWithWhite:1 alpha:0.06];
    k_stickTrack = k_ringFill; k_stickBorder = k_line;
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
        _launcherPreview = g_launcher_preview;
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
        // One shared accent-colour outline surrounds the selected controls.
        // A single opacity pulse keeps every halo fading in and out in sync.
        _editHighlight = [CAShapeLayer layer];
        _editHighlight.fillColor = UIColor.clearColor.CGColor;
        _editHighlight.strokeColor = [self editorAccentColor].CGColor;
        _editHighlight.lineWidth = 3.5;
        _editHighlight.lineCap = kCALineCapRound;
        _editHighlight.lineJoin = kCALineJoinRound;
        _editHighlight.opacity = 1.0;
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
            _menuTip=[DmPaddedTipLabel new];
            _menuTip.text=@"Press and hold the 2D, 3D, or Tap button, or hold Select on your controller, to open the in-game control menu.";
            _menuTip.textColor=UIColor.whiteColor;
            _menuTip.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            _menuTip.textAlignment=NSTextAlignmentCenter;
            _menuTip.numberOfLines=0;
            _menuTip.textInsets=UIEdgeInsetsMake(10,14,10,14);
            UIColor *tipAccent=[self editorAccentColor];
            CGFloat red=0,green=0,blue=0,alpha=1;
            [tipAccent getRed:&red green:&green blue:&blue alpha:&alpha];
            // Keep the popup fill 28% darker, and use a slightly lighter version of the dominant accent for its outline.
            UIColor *tipFill=[UIColor colorWithRed:red*0.72 green:green*0.72 blue:blue*0.72 alpha:alpha];
            CGFloat borderRed=red+(1.0-red)*0.22;
            CGFloat borderGreen=green+(1.0-green)*0.22;
            CGFloat borderBlue=blue+(1.0-blue)*0.22;
            UIColor *tipBorder=[UIColor colorWithRed:borderRed green:borderGreen blue:borderBlue alpha:alpha];
            CGFloat fillLuminance=0.2126*red*0.72+0.7152*green*0.72+0.0722*blue*0.72;
            _menuTip.textColor=fillLuminance>0.58?UIColor.blackColor:UIColor.whiteColor;
            _menuTip.backgroundColor=UIColor.clearColor;
            _menuTip.layer.cornerRadius=0;
            _menuTip.layer.borderWidth=0;
            // The rounded box and pointer share one closed path and one stroke.
            // This removes the overlapping edges that caused a visible seam.
            _menuTipBubble=[CAShapeLayer layer];
            _menuTipBubble.fillColor=tipFill.CGColor;
            _menuTipBubble.strokeColor=tipBorder.CGColor;
            _menuTipBubble.lineWidth=1.5;
            _menuTipBubble.lineJoin=kCALineJoinRound;
            _menuTipBubble.frame=self.bounds;
            _menuTipBubble.opacity=0;
            _menuTip.alpha=0;
            [self.layer addSublayer:_menuTipBubble];
            [self addSubview:_menuTip];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"DmPadMenuTipShown"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ self->_menuTip.alpha=1; }];
                CABasicAnimation *showBubble=[CABasicAnimation animationWithKeyPath:@"opacity"];
                showBubble.fromValue=@0; showBubble.toValue=@1; showBubble.duration=0.25;
                showBubble.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
                self->_menuTipBubble.opacity=1;
                [self->_menuTipBubble addAnimation:showBubble forKey:@"bubbleFade"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self dismissMenuTip];
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
                @"unused12",@"unused13",@"unused14",@"unused15",@"Stick",@"Dpad",@"Layout Switcher"];
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
    return value;
}
- (CGPoint)position:(int)b base:(CGPoint)base {
    NSDictionary *value = _custom[[self controlID:b]];
    CGRect safe = self.safe;
    // Keep the control centre within the safe area, but do not force its full
    // visual bounds inside it. The default left stick intentionally overlaps
    // the side safe-area inset, so a radius-based margin makes it jump on edit.
    // An opacity-only entry has no saved coordinates; treat it as untouched.
    if (![value[@"x"] isKindOfClass:NSNumber.class] || ![value[@"y"] isKindOfClass:NSNumber.class]) value=nil;
    return dm_pad_position(value, base, safe, 0);
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
    if (b == 18) return self.swapCenter;
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
- (void)showLauncherReopenTip {
    [self dismissMenuTip];
    _launcherReopenTip=YES;
    _menuTip=[DmPaddedTipLabel new];
    _menuTip.text=@"To reopen the control config menu, press and hold the layout mode switcher.";
    _menuTip.textColor=UIColor.whiteColor;
    _menuTip.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _menuTip.textAlignment=NSTextAlignmentCenter;
    _menuTip.numberOfLines=0;
    _menuTip.textInsets=UIEdgeInsetsMake(10,14,10,14);
    UIColor *tipAccent=[self editorAccentColor];
    CGFloat red=0,green=0,blue=0,alpha=1;
    [tipAccent getRed:&red green:&green blue:&blue alpha:&alpha];
    UIColor *tipFill=[UIColor colorWithRed:red*0.72 green:green*0.72 blue:blue*0.72 alpha:alpha];
    UIColor *tipBorder=[UIColor colorWithRed:red+(1.0-red)*0.22
                                      green:green+(1.0-green)*0.22
                                       blue:blue+(1.0-blue)*0.22 alpha:alpha];
    CGFloat fillLuminance=0.2126*red*0.72+0.7152*green*0.72+0.0722*blue*0.72;
    _menuTip.textColor=fillLuminance>0.58?UIColor.blackColor:UIColor.whiteColor;
    _menuTip.backgroundColor=UIColor.clearColor;
    _menuTip.layer.cornerRadius=0;
    _menuTip.layer.borderWidth=0;
    _menuTipBubble=[CAShapeLayer layer];
    _menuTipBubble.fillColor=tipFill.CGColor;
    _menuTipBubble.strokeColor=tipBorder.CGColor;
    _menuTipBubble.lineWidth=1.5;
    _menuTipBubble.lineJoin=kCALineJoinRound;
    _menuTipBubble.frame=self.bounds;
    _menuTipBubble.opacity=0;
    _menuTip.alpha=0;
    [self.layer addSublayer:_menuTipBubble];
    [self addSubview:_menuTip];
    [self setNeedsLayout];
    [UIView animateWithDuration:0.25 animations:^{ self->_menuTip.alpha=1; }];
    CABasicAnimation *showBubble=[CABasicAnimation animationWithKeyPath:@"opacity"];
    showBubble.fromValue=@0; showBubble.toValue=@1; showBubble.duration=0.25;
    showBubble.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    _menuTipBubble.opacity=1;
    [_menuTipBubble addAnimation:showBubble forKey:@"bubbleFade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [self dismissMenuTip];
    });
}
- (void)dismissMenuTip {
    if (!_menuTip && !_menuTipBubble) return;
    DmPaddedTipLabel *tip=_menuTip;
    CAShapeLayer *bubble=_menuTipBubble;
    _menuTip=nil;
    _menuTipBubble=nil;
    _launcherReopenTip=NO;
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseOut animations:^{
        tip.alpha=0;
    } completion:^(__unused BOOL finished) {
        [tip removeFromSuperview];
    }];
    CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue=@(bubble.presentationLayer ? ((CAShapeLayer *)bubble.presentationLayer).opacity : bubble.opacity);
    fade.toValue=@0;
    fade.duration=0.16;
    fade.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    bubble.opacity=0;
    [bubble addAnimation:fade forKey:@"bubbleFade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.17*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [bubble removeFromSuperlayer];
    });
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (_editing) { [self editTouches:ts began:YES]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        int hit = _tap ? -1 : [self btnAt:p];
        // Only the Start (+), Select (−), and layout (2D / 3D / Tap) buttons
        // should interrupt the first-launch hint. Ordinary gameplay touches do not.
        if (hit == B_PLUS || hit == B_MINUS || [self inSwap:p]) [self dismissMenuTip];
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
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickTouchOrigin[idx] = p; _stickNow[idx] = idx == 0 ? self.stickHome : p; }
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
        else if (c == C_STICK) {
            int idx=(int)(v >> 8);
            if (idx == 0) {
                // Anchor the left stick at the initial touch point. A finger landing
                // slightly off-centre should not create an unintended rightward input.
                CGPoint home=self.stickHome;
                _stickNow[0]=CGPointMake(home.x+p.x-_stickTouchOrigin[0].x,
                                         home.y+p.y-_stickTouchOrigin[0].y);
            } else {
                _stickNow[1]=p;
                CGFloat d = dist(p, _rCentre), R = [self stickR:1];
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d);
            }
        }
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
    if (b == 18) return K_SWAP_R * self.u;
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
        CGFloat tipWidth=MIN(340, MAX(0,self.bounds.size.width-32));
        CGSize tipSize=[_menuTip sizeThatFits:CGSizeMake(tipWidth,CGFLOAT_MAX)];
        CGFloat tipY=self.safeAreaInsets.top+44;
        if (_launcherReopenTip) {
            tipY=CGRectGetMaxY(CGRectMake(self.swapCenter.x-K_SWAP_R*self.u*1.6,
                                          self.swapCenter.y-K_SWAP_R*self.u*1.6,
                                          K_SWAP_R*self.u*3.2,K_SWAP_R*self.u*3.2))+12;
        }
        _menuTip.frame=CGRectMake((self.bounds.size.width-tipWidth)/2, tipY, tipWidth, tipSize.height);
        CGRect r=_menuTip.frame;
        CGFloat radius=10.0, arrowHalf=10.0, arrowHeight=11.0;
        CGFloat left=CGRectGetMinX(r), right=CGRectGetMaxX(r);
        CGFloat top=CGRectGetMinY(r), bottom=CGRectGetMaxY(r);
        CGFloat mid=CGRectGetMidX(r);
        UIBezierPath *bubble=[UIBezierPath bezierPath];
        [bubble moveToPoint:CGPointMake(left+radius,top)];
        [bubble addLineToPoint:CGPointMake(mid-arrowHalf,top)];
        [bubble addLineToPoint:CGPointMake(mid,top-arrowHeight)];
        [bubble addLineToPoint:CGPointMake(mid+arrowHalf,top)];
        [bubble addLineToPoint:CGPointMake(right-radius,top)];
        [bubble addArcWithCenter:CGPointMake(right-radius,top+radius) radius:radius startAngle:-M_PI_2 endAngle:0 clockwise:YES];
        [bubble addLineToPoint:CGPointMake(right,bottom-radius)];
        [bubble addArcWithCenter:CGPointMake(right-radius,bottom-radius) radius:radius startAngle:0 endAngle:M_PI_2 clockwise:YES];
        [bubble addLineToPoint:CGPointMake(left+radius,bottom)];
        [bubble addArcWithCenter:CGPointMake(left+radius,bottom-radius) radius:radius startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
        [bubble addLineToPoint:CGPointMake(left,top+radius)];
        [bubble addArcWithCenter:CGPointMake(left+radius,top+radius) radius:radius startAngle:M_PI endAngle:3*M_PI_2 clockwise:YES];
        [bubble closePath];
        _menuTipBubble.frame=self.bounds;
        _menuTipBubble.path=bubble.CGPath;
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGRect safe=self.safe;
    if (!CGRectEqualToRect(safe,_lastSafe)) { _lastSafe=safe; if (!_editing) [self reset]; }
    CGFloat toolsContentBottom=0;
    for (UIView *item in _tools.subviews)
        toolsContentBottom=MAX(toolsContentBottom,CGRectGetMaxY(item.frame));
    // Center both editor menus, then shift them slightly downward. The minimum
    // top clearance keeps the 2D / 3D / Tap layout control above the panel.
    CGFloat toolsHeight=ceil(toolsContentBottom+8);
    // Both editor presentations use the same width: the HUD toggles end at
    // x=352, leaving the intended 8-point right inset inside this 360-point panel.
    CGFloat toolsWidth=360;
    CGFloat toolsX=CGRectGetMidX(safe)-toolsWidth/2;
    CGFloat topClearance=(K_PILL_Y+K_SWAP_R+8)*u;
    CGFloat centeredY=CGRectGetMidY(safe)-toolsHeight/2+18;
    CGFloat minToolsY=CGRectGetMinY(safe)+topClearance;
    CGFloat maxToolsY=MAX(minToolsY,CGRectGetMaxY(safe)-toolsHeight-4);
    CGFloat toolsY=MIN(MAX(centeredY,minToolsY),maxToolsY);
    _tools.frame=CGRectMake(toolsX,toolsY,toolsWidth,toolsHeight);
    _themeMenuOverlay.frame=self.bounds;
    if (!_themeMenuOverlay.hidden) {
        CGRect anchor=[_themeButton convertRect:_themeButton.bounds toView:self];
        CGFloat panelHeight=_themeMenuPanel.bounds.size.height;
        CGFloat panelX=MIN(MAX(8,CGRectGetMidX(anchor)-_themeMenuPanel.bounds.size.width/2),MAX(8,self.bounds.size.width-_themeMenuPanel.bounds.size.width-8));
        CGFloat below=CGRectGetMaxY(anchor)+6;
        CGFloat panelY=(below+panelHeight<=self.bounds.size.height-8)?below:MAX(8,CGRectGetMinY(anchor)-panelHeight-6);
        _themeMenuPanel.frame=CGRectMake(panelX,panelY,_themeMenuPanel.bounds.size.width,panelHeight);
        [_themeMenuOverlay bringSubviewToFront:_themeMenuPanel];
    }
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
        _editHighlight.frame = _controls.bounds;
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
        _key[b].strokeColor = [self themeBorderColorForButton:b].CGColor;
        _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor;
        _key[b].opacity = [self opacity:(b >= B_LEFT ? 17 : b)];
    }
    _ring.opacity = _knob.opacity = [self opacity:16];
    _ring.fillColor = k_stickTrack.CGColor;
    _ring.strokeColor = k_stickBorder.CGColor; _knob.strokeColor = k_stickBorder.CGColor;
    CAShapeLayer *innerRing=(CAShapeLayer *)_knob.sublayers.firstObject;
    innerRing.strokeColor=k_stickBorder.CGColor;
    _swap.fillColor = [self themeColorForButton:B_N pressed:_swapHeld].CGColor;
    _swap.strokeColor = [self themeBorderColorForButton:B_N].CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
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
        // Remove the retired Well built-in copied into Documents by older builds.
        [fm removeItemAtURL:[dir URLByAppendingPathComponent:@"Well" isDirectory:YES] error:nil];
        NSURL *bundled=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES];
        NSURL *forestSource=[bundled URLByAppendingPathComponent:@"FOREST" isDirectory:YES];
        NSURL *forestDestination=[dir URLByAppendingPathComponent:@"FOREST" isDirectory:YES];
        NSURL *forestDeletionMarker=[dir URLByAppendingPathComponent:@".FOREST.deleted"];
        if (![fm fileExistsAtPath:forestDestination.path] && ![fm fileExistsAtPath:forestDeletionMarker.path])
            [fm copyItemAtURL:forestSource toURL:forestDestination error:nil];
        // Keep the writable FOREST copy; remove identical legacy copies of the protected built-ins.
        NSArray<NSURL *> *bundledFolders=[fm contentsOfDirectoryAtURL:bundled
            includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *folder in bundledFolders) {
            NSNumber *isDirectory=nil; [folder getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
            if (!isDirectory.boolValue || [folder.lastPathComponent caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) continue;
            NSURL *legacy=[dir URLByAppendingPathComponent:folder.lastPathComponent isDirectory:YES];
            NSData *bundledJSON=[NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"theme.json"]];
            NSData *legacyJSON=[NSData dataWithContentsOfURL:[legacy URLByAppendingPathComponent:@"theme.json"]];
            if (bundledJSON && [bundledJSON isEqualToData:legacyJSON]) [fm removeItemAtURL:legacy error:nil];
        }
    }
    return dir;
}
- (NSURL *)themeJSONURLInFolder:(NSURL *)folder {
    NSArray<NSURL *> *items=[NSFileManager.defaultManager contentsOfDirectoryAtURL:folder
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL *item in items)
        if ([item.lastPathComponent caseInsensitiveCompare:@"theme.json"]==NSOrderedSame) return item;
    return [folder URLByAppendingPathComponent:@"theme.json"];
}
- (NSDictionary *)validThemeJSONAtFolder:(NSURL *)folder {
    NSData *data=[NSData dataWithContentsOfURL:[self themeJSONURLInFolder:folder]];
    NSDictionary *json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSDictionary *palette=[json isKindOfClass:NSDictionary.class]?json[@"palette"]:nil;
    if (![palette isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"idle",@"pressed",@"outline",@"ringFill",@"text",@"pressedText"])
        if (!themeHex(themePaletteValue(palette,key))) return nil;
    return json;
}
- (BOOL)loadThemeAtPath:(NSString *)path {
    if (!path.length) return NO;
    NSData *data=[NSData dataWithContentsOfURL:[self themeJSONURLInFolder:[NSURL fileURLWithPath:path isDirectory:YES]]];
    if (!data) return NO;
    NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *palette=json[@"palette"], *buttons=json[@"buttons"];
    if (![palette isKindOfClass:NSDictionary.class]) return NO;
    UIColor *idle=themeHex(themePaletteValue(palette,@"idle")), *pressed=themeHex(themePaletteValue(palette,@"pressed"));
    UIColor *outline=themeHex(themePaletteValue(palette,@"outline")), *ring=themeHex(themePaletteValue(palette,@"ringFill"));
    UIColor *text=themeHex(themePaletteValue(palette,@"text")), *pressedText=themeHex(themePaletteValue(palette,@"pressedText"));
    if (!idle || !pressed || !outline || !ring || !text || !pressedText) return NO;
    NSMutableDictionary *parsed=[NSMutableDictionary dictionary];
    if ([buttons isKindOfClass:NSDictionary.class]) for (NSString *key in buttons) {
        UIColor *color=themeHex(buttons[key]); if (color) parsed[key]=color;
    }
    k_idle=[idle colorWithAlphaComponent:0.36]; k_on=[pressed colorWithAlphaComponent:0.92];
    k_line=[outline colorWithAlphaComponent:0.88]; k_ringFill=[ring colorWithAlphaComponent:0.25];
    k_stickTrack=[(themeHex(buttons[@"StickTrack"]) ?: ring) colorWithAlphaComponent:0.25];
    k_stickBorder=[(themeHex(buttons[@"StickBorder"]) ?: outline) colorWithAlphaComponent:0.88];
    k_text=[text colorWithAlphaComponent:0.96]; k_textOn=pressedText;
    _themeButtonColors=parsed;
    _themePath=[path copy];
    _themeName=[json[@"name"] isKindOfClass:NSString.class] && [json[@"name"] length] ? json[@"name"] : path.lastPathComponent;
    return YES;
}
- (BOOL)loadSelectedTheme {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSString *path=[defaults stringForKey:k_theme_path_key];
    // FOREST ships in the bundle as a seed, but its active copy lives in
    // Documents so users can edit, rename, and delete it like an imported theme.
    if (path.length && [[NSURL fileURLWithPath:path].lastPathComponent caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) {
        NSURL *writableForest=[[self themesDirectoryCreating:YES] URLByAppendingPathComponent:@"FOREST" isDirectory:YES];
        if ([NSFileManager.defaultManager fileExistsAtPath:writableForest.path])
            path=writableForest.path;
    }
    if (path.length && [self loadThemeAtPath:path]) {
        [defaults setObject:path forKey:k_theme_path_key];
        return YES;
    }

    [defaults removeObjectForKey:k_theme_path_key];
    NSURL *bundledRoot=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES];
    NSURL *animalWell=[bundledRoot URLByAppendingPathComponent:@"ANIMAL WELL" isDirectory:YES];
    if ([self loadThemeAtPath:animalWell.path]) {
        [defaults setObject:animalWell.path forKey:k_theme_path_key];
        [defaults setObject:_themeName ?: @"ANIMAL WELL" forKey:k_theme_name_key];
        return YES;
    }
    [defaults setObject:@"ANIMAL WELL" forKey:k_theme_name_key];
    _themeName=@"ANIMAL WELL"; _themeButtonColors=@{}; theme_init(); return NO;
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
    if (b==B_N) base=_themeButtonColors[@"Layout"];
    if (!base) return pressed ? k_on : k_idle;
    return [base colorWithAlphaComponent:pressed ? 0.92 : 0.36];
}
- (UIColor *)themeBorderColorForButton:(int)b {
    NSString *key=nil;
    switch (b) {
        case B_A:key=@"A";break; case B_B:key=@"B";break; case B_X:key=@"X";break; case B_Y:key=@"Y";break;
        case B_LS:case B_RS:key=@"Stick";break; case B_L:key=@"L";break; case B_R:key=@"R";break;
        case B_ZL:key=@"ZL";break; case B_ZR:key=@"ZR";break; case B_PLUS:key=@"Plus";break;
        case B_MINUS:key=@"Minus";break; default:if (b>=B_LEFT) key=@"Dpad";break;
    }
    if (b==B_N) key=@"Layout";
    UIColor *color=key ? _themeButtonColors[[@"Border" stringByAppendingString:key]] : nil;
    return color ?: k_line;
}
- (NSString *)borderColorKeyForControl:(int)control {
    NSString *key=[self themeColorKeyForControl:control];
    if (!key.length) return nil;
    if (control==16) return @"StickBorder";
    return [@"Border" stringByAppendingString:key];
}
- (NSString *)colorTargetName {
    switch (_colorTarget) {
        case 1:return @"Border Color";
        case 2:return @"Left Stick Track";
        case 3:return @"Text Color";
        case 4:return @"Pressed Text";
        default:return @"Fill Color";
    }
}
- (UIColor *)currentColorForEditorSelection {
    if (_colorTarget==3) return k_text;
    if (_colorTarget==4) return k_textOn;
    if (_colorTarget==2) return _themeButtonColors[@"StickTrack"] ?: k_stickTrack;
    if (_colorTarget==1) {
        if (_selected<0) return _themeButtonColors[@"BorderA"] ?: k_line;
        NSString *key=[self borderColorKeyForControl:_selected];
        UIColor *saved=key ? _themeButtonColors[key] : nil;
        if (saved) return saved;
        return (_selected==16) ? k_stickBorder : k_line;
    }
    if (_selected<0) return _themeButtonColors[@"A"] ?: k_idle;
    NSString *key=[self themeColorKeyForControl:_selected];
    return key ? (_themeButtonColors[key] ?: k_idle) : nil;
}
- (BOOL)isBuiltInThemeSelected {
    if (!_themePath.length) return YES;
    // Decide from the actual selected theme files, not their folder name or
    // location. Imported themes (including nested folders) are writable;
    // bundled themes are read-only.
    NSURL *folder=[NSURL fileURLWithPath:_themePath isDirectory:YES];
    NSURL *manifest=[self themeJSONURLInFolder:folder];
    NSFileManager *fm=NSFileManager.defaultManager;
    BOOL writableFolder=[fm isWritableFileAtPath:folder.path];
    BOOL writableManifest=[fm fileExistsAtPath:manifest.path] && [fm isWritableFileAtPath:manifest.path];
    return !(writableFolder && writableManifest);
}
- (void)applyThemePath:(NSString *)path name:(NSString *)name {
    if (![self loadThemeAtPath:path]) return;
    [NSUserDefaults.standardUserDefaults setObject:path forKey:k_theme_path_key];
    [NSUserDefaults.standardUserDefaults setObject:_themeName ?: name forKey:k_theme_name_key];
    [self refresh]; [self setNeedsLayout]; [self layoutIfNeeded]; [self updateEditor];
}
- (void)toggleThemeMenu {
    if (_themeMenuOverlay.hidden) {
        [self updateThemeMenu];
        _themeMenuOverlay.hidden=NO;
        [self setNeedsLayout];
        [self layoutIfNeeded];
        [_themeMenuOverlay bringSubviewToFront:_themeMenuPanel];
    } else {
        [self closeThemeMenu];
    }
}
- (void)closeThemeMenu {
    _themeMenuOverlay.hidden=YES;
}
- (void)updateThemeMenu {
    NSString *current=[NSUserDefaults.standardUserDefaults stringForKey:k_theme_name_key] ?: @"ANIMAL WELL";
    [_themeButton setTitle:[NSString stringWithFormat:@"Theme: %@ ▾",current] forState:UIControlStateNormal];
    for (UIView *view in _themeMenuScroll.subviews) [view removeFromSuperview];

    NSURL *documentsRoot=[self themesDirectoryCreating:YES];
    NSURL *bundledRoot=[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES];
    NSArray<NSURL *> *bundledFolders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:bundledRoot
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSArray<NSURL *> *importedFolders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:documentsRoot
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    BOOL hasDocumentsForest=NO;
    for (NSURL *folder in importedFolders) if ([folder.lastPathComponent caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) { hasDocumentsForest=YES; break; }
    BOOL forestWasDeleted=[NSFileManager.defaultManager fileExistsAtPath:[[documentsRoot URLByAppendingPathComponent:@".FOREST.deleted"] path]];
    NSMutableArray<NSURL *> *visibleBundled=[NSMutableArray array];
    for (NSURL *folder in bundledFolders) {
        if ((hasDocumentsForest || forestWasDeleted) && [folder.lastPathComponent caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) continue;
        [visibleBundled addObject:folder];
    }
    NSArray<NSURL *> *unsortedFolders=[visibleBundled arrayByAddingObjectsFromArray:importedFolders];
    NSArray<NSURL *> *folders=[unsortedFolders sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        NSString *(^normalizedName)(NSString *) = ^NSString *(NSString *value) {
            NSString *name=[[value uppercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
            name=[name stringByReplacingOccurrencesOfString:@"-" withString:@" "];
            for (NSString *suffix in @[@" SKIN", @" THEME"]) if ([name hasSuffix:suffix])
                name=[[name substringToIndex:name.length-suffix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        };
        NSInteger (^priority)(NSURL *) = ^NSInteger(NSURL *folder) {
            NSString *folderName=normalizedName(folder.lastPathComponent);
            NSDictionary *json=[self validThemeJSONAtFolder:folder];
            NSString *themeName=normalizedName([json[@"name"] isKindOfClass:NSString.class] ? json[@"name"] : folder.lastPathComponent);
            if ([folderName isEqualToString:@"ANIMAL WELL"] || [themeName isEqualToString:@"ANIMAL WELL"]) return 0;
            if ([folderName isEqualToString:@"CLASSIC"] || [themeName isEqualToString:@"CLASSIC"]) return 1;
            return 2;
        };
        NSInteger lp=priority(left),rp=priority(right);
        if(lp<rp)return NSOrderedAscending;if(lp>rp)return NSOrderedDescending;
        NSDictionary *lj=[self validThemeJSONAtFolder:left],*rj=[self validThemeJSONAtFolder:right];
        NSString *ln=[lj[@"name"] isKindOfClass:NSString.class]?lj[@"name"]:left.lastPathComponent;
        NSString *rn=[rj[@"name"] isKindOfClass:NSString.class]?rj[@"name"]:right.lastPathComponent;
        NSComparisonResult byName=[ln localizedCaseInsensitiveCompare:rn];
        return byName==NSOrderedSame?[left.path localizedCaseInsensitiveCompare:right.path]:byName;
    }];

    CGFloat rowHeight=40;
    NSUInteger row=0;
    for (NSURL *folder in folders) {
        BOOL isDir=NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:folder.path isDirectory:&isDir] || !isDir) continue;
        NSDictionary *json=[self validThemeJSONAtFolder:folder];
        if (!json) continue;
        NSString *path=folder.standardizedURL.path;
        NSString *title=[json[@"name"] isKindOfClass:NSString.class] && [json[@"name"] length] ? json[@"name"] : folder.lastPathComponent;
        UIButton *pick=[UIButton buttonWithType:UIButtonTypeSystem];
        pick.frame=CGRectMake(0,row*rowHeight,212,rowHeight);
        [pick setTitle:title forState:UIControlStateNormal];
        pick.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
        pick.contentEdgeInsets=UIEdgeInsetsMake(0,8,0,0);
        pick.titleLabel.font=[UIFont systemFontOfSize:14];
        pick.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        pick.tintColor=UIColor.whiteColor;
        if ([current isEqualToString:title]) [pick setTitle:[title stringByAppendingString:@"  ✓"] forState:UIControlStateNormal];
        pick.accessibilityLabel=[NSString stringWithFormat:@"Select %@",title];
        __weak typeof(self) weakSelf=self;
        [pick addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            (void)action;
            [weakSelf applyThemePath:path name:title];
            [weakSelf closeThemeMenu];
        }] forControlEvents:UIControlEventTouchUpInside];
        [_themeMenuScroll addSubview:pick];

        NSString *folderName=folder.lastPathComponent;
        BOOL protectedTheme=[folderName caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
            [folderName caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame ||
            [title caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
            [title caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame;
        // Only direct child folders in the app's imported-themes directory are custom themes.
        // Do not gate the actions on isWritableFileAtPath: that check can incorrectly return
        // false for app-managed/document-provider files even when the app can edit them.
        BOOL isImportedTheme=NO;
        for (NSURL *importedFolder in importedFolders) {
            if ([importedFolder.standardizedURL.path isEqualToString:folder.standardizedURL.path]) {
                isImportedTheme=YES;
                break;
            }
        }
        NSURL *manifestURL=[self themeJSONURLInFolder:folder];
        BOOL manifestExists=manifestURL && [NSFileManager.defaultManager fileExistsAtPath:manifestURL.path];
        if (isImportedTheme && manifestExists && !protectedTheme) {
            // Match the launcher's plain 32x32 pencil and trash actions exactly.
            // This selector is shared by the pre-launch preview and live editor.
            UIImageSymbolConfiguration *actionSymbol=[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];

            UIButton *rename=[UIButton buttonWithType:UIButtonTypeCustom];
            rename.frame=CGRectMake(216,row*rowHeight+4,32,32);
            rename.backgroundColor=UIColor.clearColor;
            [rename setImage:[[UIImage systemImageNamed:@"pencil" withConfiguration:actionSymbol] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
            rename.tintColor=[UIColor colorWithWhite:1 alpha:0.82];
            rename.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;
            rename.contentVerticalAlignment=UIControlContentVerticalAlignmentCenter;
            rename.adjustsImageWhenHighlighted=NO;
            rename.accessibilityLabel=[NSString stringWithFormat:@"Rename %@",title];
            NSString *renamePath=[path copy],*renameName=[title copy];
            [rename addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                (void)action;
                [weakSelf closeThemeMenu];
                [weakSelf renameThemeAtPath:renamePath name:renameName];
            }] forControlEvents:UIControlEventTouchUpInside];
            [_themeMenuScroll addSubview:rename];

            UIButton *remove=[UIButton buttonWithType:UIButtonTypeCustom];
            remove.frame=CGRectMake(252,row*rowHeight+4,32,32);
            remove.backgroundColor=UIColor.clearColor;
            [remove setImage:[[UIImage systemImageNamed:@"trash" withConfiguration:actionSymbol] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
            remove.tintColor=[UIColor colorWithRed:0.55 green:0.08 blue:0.08 alpha:1];
            remove.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;
            remove.contentVerticalAlignment=UIControlContentVerticalAlignmentCenter;
            remove.adjustsImageWhenHighlighted=NO;
            remove.accessibilityLabel=[NSString stringWithFormat:@"Delete %@",title];
            NSString *deletePath=[path copy],*deleteName=[title copy];
            [remove addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                (void)action;
                [weakSelf closeThemeMenu];
                [weakSelf confirmDeleteThemeAtPath:deletePath name:deleteName];
            }] forControlEvents:UIControlEventTouchUpInside];
            [_themeMenuScroll addSubview:remove];
        }
        UIView *separator=[[UIView alloc] initWithFrame:CGRectMake(0,(row+1)*rowHeight-1,288,0.5)];
        separator.backgroundColor=[UIColor colorWithWhite:1 alpha:0.12];
        [_themeMenuScroll addSubview:separator];
        row++;
    }
    CGFloat contentHeight=row*rowHeight;
    _themeMenuScroll.contentSize=CGSizeMake(288,contentHeight);
    _themeMenuScroll.frame=CGRectMake(8,8,288,MIN(contentHeight,240));
    _themeMenuPanel.frame=CGRectMake(0,0,304,MIN(contentHeight,240)+16);
}
- (void)renameThemeAtPath:(NSString *)path name:(NSString *)name {
    NSURL *documentsRoot=[self themesDirectoryCreating:YES].standardizedURL;
    NSURL *folder=[NSURL fileURLWithPath:path].standardizedURL;
    NSString *documentsPrefix=[documentsRoot.path stringByAppendingString:@"/"];
    if (![folder.path hasPrefix:documentsPrefix] ||
        [folder.lastPathComponent caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
        [folder.lastPathComponent caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame ||
        [name caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
        [name caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame) return;

    UIAlertController *prompt=[UIAlertController alertControllerWithTitle:@"Rename Theme"
        message:@"Choose a new name for this custom theme." preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text=name;
        field.clearButtonMode=UITextFieldViewModeWhileEditing;
        field.autocapitalizationType=UITextAutocapitalizationTypeWords;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakPrompt=prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *newName=[weakPrompt.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!newName.length || [newName caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
            [newName caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame) return;
        NSURL *manifestURL=[self themeJSONURLInFolder:folder];
        NSString *manifestPath=manifestURL.path;
        NSMutableDictionary *json=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifestPath]
            options:NSJSONReadingMutableContainers error:nil] mutableCopy];
        if (!json) return;
        json[@"name"]=newName;
        NSData *data=[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (!data || ![data writeToFile:manifestPath atomically:YES]) return;
        NSString *selectedPath=[NSURL fileURLWithPath:self->_themePath ?: @""].standardizedURL.path;
        if ([selectedPath isEqualToString:folder.path]) {
            self->_themeName=newName;
            [NSUserDefaults.standardUserDefaults setObject:newName forKey:k_theme_name_key];
        }
        [self updateThemeMenu];
        [self updateEditor];
    }]];
    UIViewController *presenter=[self editorPresenter];
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented) return;

    // UIAlertController does not reliably focus its text field when launched from
    // the gamepad's custom overlay. Explicitly request focus after presentation so
    // the software keyboard appears in both the pre-launch and live editors.
    [presenter presentViewController:prompt animated:YES completion:^{
        UITextField *field=prompt.textFields.firstObject;
        [field becomeFirstResponder];
    }];
}
- (void)confirmDeleteThemeAtPath:(NSString *)path name:(NSString *)name {
    NSURL *documentsRoot=[self themesDirectoryCreating:YES];
    NSURL *target=[NSURL fileURLWithPath:path].standardizedURL;
    NSString *folderName=target.lastPathComponent;
    BOOL isDirectDocumentsTheme=NO;
    NSArray<NSURL *> *importedFolders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:documentsRoot
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *folder in importedFolders) {
        if ([folder.standardizedURL.path isEqualToString:target.path]) { isDirectDocumentsTheme=YES; break; }
    }
    if (!isDirectDocumentsTheme ||
        [folderName caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
        [folderName caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame ||
        [name caseInsensitiveCompare:@"ANIMAL WELL"]==NSOrderedSame ||
        [name caseInsensitiveCompare:@"CLASSIC"]==NSOrderedSame) return;

    UIAlertController *alert=[UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?",name]
        message:@"This removes the theme folder from the app's TouchControlThemes folder in Files."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSError *error=nil;
        if (![NSFileManager.defaultManager removeItemAtURL:target error:&error]) {
            UIAlertController *failure=[UIAlertController alertControllerWithTitle:@"Could Not Delete Theme"
                message:error.localizedDescription ?: @"The theme folder could not be deleted."
                preferredStyle:UIAlertControllerStyleAlert];
            [failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [[self editorPresenter] presentViewController:failure animated:YES completion:nil];
            return;
        }
        if ([folderName caseInsensitiveCompare:@"FOREST"]==NSOrderedSame) {
            NSURL *marker=[documentsRoot URLByAppendingPathComponent:@".FOREST.deleted"];
            if (![[NSData data] writeToURL:marker atomically:YES]) {
                LOG("touch theme: FOREST removed, but its deletion marker could not be written");
            }
        }
        NSString *selectedPath=[NSUserDefaults.standardUserDefaults stringForKey:k_theme_path_key];
        if ([selectedPath isEqualToString:path] || [selectedPath isEqualToString:target.path]) {
            NSURL *animalWell=[[[NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"TouchControlThemes" isDirectory:YES]
                URLByAppendingPathComponent:@"ANIMAL WELL" isDirectory:YES] standardizedURL];
            [self applyThemePath:animalWell.path name:@"ANIMAL WELL"];
        } else {
            [self updateThemeMenu];
        }
    }]];
    [[self editorPresenter] presentViewController:alert animated:YES completion:nil];
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
    __block NSString *installedPath=nil, *installedName=nil, *failure=nil;
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordinationError=nil;
    [coordinator coordinateReadingItemAtURL:source options:0 error:&coordinationError byAccessor:^(NSURL *readableSource) {
        NSFileManager *fm=NSFileManager.defaultManager;
        // Accept a theme folder or a parent containing exactly one theme. Coordinate reads
        // through the Files provider so iCloud/On My iPhone folders are fully materialized.
        NSURL *themeFolder=readableSource;
        NSDictionary *json=[self validThemeJSONAtFolder:themeFolder];
        if (!json) {
            NSMutableArray<NSURL *> *valid=[NSMutableArray array];
            NSDirectoryEnumerator<NSURL *> *enumerator=[fm enumeratorAtURL:readableSource
                includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles
                errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return YES; }];
            for (NSURL *entry in enumerator) {
                if ([entry.lastPathComponent caseInsensitiveCompare:@"theme.json"]!=NSOrderedSame) continue;
                NSURL *candidate=[entry URLByDeletingLastPathComponent];
                if ([self validThemeJSONAtFolder:candidate] &&
                    ![valid containsObject:candidate]) [valid addObject:candidate];
            }
            if (valid.count==1) {
                themeFolder=valid.firstObject;
                json=[self validThemeJSONAtFolder:themeFolder];
            } else if (valid.count>1) {
                failure=@"More than one valid theme was found. Select the folder for a single theme and try again.";
                return;
            }
        }
        if (!json) {
            failure=@"No valid theme.json was found. The selected theme must contain all six palette colors: idle, pressed, outline, ringFill, text, and pressedText.";
            return;
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
        NSURL *root=[self themesDirectoryCreating:YES];
        NSURL *destination=[root URLByAppendingPathComponent:safeName isDirectory:YES];
        NSURL *staging=[root URLByAppendingPathComponent:[NSString stringWithFormat:@".import-%@",[NSUUID UUID].UUIDString] isDirectory:YES];
        NSError *copyError=nil;
        if (![fm copyItemAtURL:themeFolder toURL:staging error:&copyError]) {
            failure=[NSString stringWithFormat:@"The theme files could not be read or copied. %@",copyError.localizedDescription ?: @""];
            return;
        }
        // Canonicalize the manifest filename so the runtime loader always finds it.
        NSURL *manifest=[self themeJSONURLInFolder:staging];
        NSURL *canonical=[staging URLByAppendingPathComponent:@"theme.json"];
        if (![manifest.lastPathComponent isEqualToString:@"theme.json"] &&
            ![fm moveItemAtURL:manifest toURL:canonical error:&copyError]) {
            [fm removeItemAtURL:staging error:nil];
            failure=[NSString stringWithFormat:@"The theme manifest could not be normalized. %@",copyError.localizedDescription ?: @""];
            return;
        }
        NSURL *backup=[root URLByAppendingPathComponent:[NSString stringWithFormat:@".backup-%@",[NSUUID UUID].UUIDString] isDirectory:YES];
        BOOL hadExisting=[fm fileExistsAtPath:destination.path];
        if (hadExisting && ![fm moveItemAtURL:destination toURL:backup error:&copyError]) {
            [fm removeItemAtURL:staging error:nil];
            failure=[NSString stringWithFormat:@"The existing theme could not be safely replaced. %@",copyError.localizedDescription ?: @""];
            return;
        }
        if (![fm moveItemAtURL:staging toURL:destination error:&copyError]) {
            if (hadExisting) [fm moveItemAtURL:backup toURL:destination error:nil];
            [fm removeItemAtURL:staging error:nil];
            failure=[NSString stringWithFormat:@"The imported theme could not be installed. %@",copyError.localizedDescription ?: @""];
            return;
        }
        if (hadExisting) [fm removeItemAtURL:backup error:nil];
        installedPath=destination.path;
        installedName=safeName;
    }];
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (coordinationError) failure=[NSString stringWithFormat:@"The selected folder could not be accessed. %@",coordinationError.localizedDescription];
    if (installedPath) {
        [self applyThemePath:installedPath name:installedName];
        return;
    }
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Theme Import Failed"
        message:failure ?: @"The selected folder could not be imported." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self editorPresenter] presentViewController:alert animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }

// ---- In-game touch-control editor and named profiles ----
- (NSString *)themeColorKeyForControl:(int)control {
    if (control==16) return @"Stick";
    if (control==17) return @"Dpad";
    if (control==18) return @"Layout";
    switch (control) {
        case B_A:return @"A"; case B_B:return @"B"; case B_X:return @"X"; case B_Y:return @"Y";
        case B_LS:case B_RS:return @"Stick"; case B_L:return @"L"; case B_R:return @"R";
        case B_ZL:return @"ZL"; case B_ZR:return @"ZR"; case B_PLUS:return @"Plus";
        case B_MINUS:return @"Minus";
        default:return nil;
    }
}
- (NSString *)hexForColor:(UIColor *)color {
    CGFloat red=0,green=0,blue=0,alpha=1;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"FFFFFF";
    return [NSString stringWithFormat:@"%02X%02X%02X",(int)round(red*255),(int)round(green*255),(int)round(blue*255)];
}
- (void)persistCustomTheme {
    if (!_themePath.length) return;
    NSURL *documents=[self themesDirectoryCreating:YES];
    NSString *prefix=[documents.standardizedURL.path stringByAppendingString:@"/"];
    if (![[ _themePath stringByStandardizingPath] hasPrefix:prefix]) return;
    NSString *jsonPath=[_themePath stringByAppendingPathComponent:@"theme.json"];
    NSMutableDictionary *json=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:jsonPath] options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    if (!json) return;
    NSMutableDictionary *buttons=[json[@"buttons"] isKindOfClass:NSDictionary.class]?[json[@"buttons"] mutableCopy]:[NSMutableDictionary dictionary];
    for (NSString *key in _themeButtonColors) buttons[key]=[self hexForColor:_themeButtonColors[key]];
    json[@"buttons"]=buttons;
    NSMutableDictionary *palette=[json[@"palette"] isKindOfClass:NSDictionary.class]?[json[@"palette"] mutableCopy]:[NSMutableDictionary dictionary];
    palette[@"text"]=[self hexForColor:k_text];
    palette[@"pressedText"]=[self hexForColor:k_textOn];
    json[@"palette"]=palette;
    NSData *data=[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToFile:jsonPath atomically:YES];
    [self updateThemeMenu];
}
- (void)refreshColorWellAppearance {
    if (!_colorWellAppearance || !_colorWellRainbowBorder || !_colorWellSwatch) return;
    _colorWellAppearance.frame=_colorWellButton.frame;
    _colorWellRainbowBorder.frame=_colorWellAppearance.bounds;
    CGRect bounds=_colorWellAppearance.bounds;
    CGFloat border=2.0;
    UIBezierPath *borderPath=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(bounds,1,1) cornerRadius:5];
    CAShapeLayer *mask=[CAShapeLayer layer];
    mask.frame=bounds;
    mask.path=borderPath.CGPath;
    mask.fillColor=UIColor.clearColor.CGColor;
    mask.strokeColor=UIColor.whiteColor.CGColor;
    mask.lineWidth=border;
    _colorWellRainbowBorder.mask=mask;
    _colorWellSwatch.frame=CGRectInset(bounds,5,5);
    _colorWellSwatch.backgroundColor=_editorColor ?: k_idle;
}
- (void)openEditorColorPicker {
    if (!_colorWellButton.enabled) return;
    UIColorPickerViewController *picker=[UIColorPickerViewController new];
    picker.delegate=self;
    picker.supportsAlpha=NO;
    picker.selectedColor=_editorColor ?: k_idle;
    picker.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    // Use a genuinely compact floating presentation: page sheets can still
    // expand to the full iPhone width even when preferredContentSize is set.
    picker.preferredContentSize=CGSizeMake(340, 520);
    picker.modalPresentationStyle=UIModalPresentationCustom;
    picker.modalTransitionStyle=UIModalTransitionStyleCrossDissolve;
    _colorPickerTransitionDelegate=[DmColorPickerTransitionDelegate new];
    picker.transitioningDelegate=_colorPickerTransitionDelegate;

    _editorColorPicker=picker;
    [[self editorPresenter] presentViewController:picker animated:YES completion:nil];
}
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    [self applyEditorColor:viewController.selectedColor];
}
- (void)applyEditorColor:(UIColor *)color {
    if (!color) return;
    NSMutableDictionary *colors=[_themeButtonColors mutableCopy] ?: [NSMutableDictionary dictionary];
    if (_colorTarget==3) {
        k_text=[color colorWithAlphaComponent:0.96];
    } else if (_colorTarget==4) {
        k_textOn=color;
    } else if (_colorTarget==2) {
        // The track is an independent layer and never changes the stick fill or border.
        colors[@"StickTrack"]=color;
        k_stickTrack=[color colorWithAlphaComponent:0.25];
    } else if (_colorTarget==1) {
        if (_colorPickerControl<0) {
            for (int control=0;control<18;control++) if ([self editable:control]) {
                NSString *key=[self borderColorKeyForControl:control];
                if (key.length) colors[key]=color;
            }
            colors[@"BorderLayout"]=color;
        } else {
            NSString *key=[self borderColorKeyForControl:_colorPickerControl];
            if (!key.length) return;
            colors[key]=color;
            if (_colorPickerControl==16) k_stickBorder=[color colorWithAlphaComponent:0.88];
        }
        if (_colorPickerControl<0) k_stickBorder=[color colorWithAlphaComponent:0.88];
    } else {
        if (_colorPickerControl<0) {
            for (int control=0;control<18;control++) if ([self editable:control]) {
                NSString *key=[self themeColorKeyForControl:control];
                if (key.length) colors[key]=color;
            }
            colors[@"Layout"]=color;
        } else {
            NSString *key=[self themeColorKeyForControl:_colorPickerControl];
            if (!key.length) return;
            colors[key]=color;
        }
    }
    _themeButtonColors=colors;
    _editorColor=color;
    [self refreshColorWellAppearance];
    [self refresh];
    [self persistCustomTheme];
}
- (void)createCustomTheme {
    NSURL *root=[self themesDirectoryCreating:YES];
    UIAlertController *prompt=[UIAlertController alertControllerWithTitle:@"Create Custom Theme"
        message:@"This creates an editable copy of the current theme in TouchControlThemes."
        preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder=@"Theme name";
        field.text=@"My Custom Theme";
        field.autocapitalizationType=UITextAutocapitalizationTypeWords;
    }];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name=[prompt.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-"];
        NSMutableString *safe=[NSMutableString string];
        for (NSUInteger i=0;i<name.length;i++) { unichar ch=[name characterAtIndex:i]; [safe appendFormat:@"%C",[allowed characterIsMember:ch]?ch:'_']; }
        NSString *folderName=[safe stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ._"]];
        if (!folderName.length) folderName=@"My Custom Theme";
        NSURL *destination=[root URLByAppendingPathComponent:folderName isDirectory:YES];
        NSUInteger suffix=2;
        while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
            destination=[root URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %lu",folderName,(unsigned long)suffix++] isDirectory:YES];
        }
        NSDictionary *source=[self validThemeJSONAtFolder:[NSURL fileURLWithPath:_themePath ?: @""]];
        NSMutableDictionary *json=source?[source mutableCopy]:[NSMutableDictionary dictionary];
        if (!json.count) {
            json[@"palette"]=@{@"idle":@"FFFFFF",@"pressed":@"FFFFFF",@"outline":@"FFFFFF",@"ringFill":@"FFFFFF",@"text":@"FFFFFF",@"pressedText":@"000000"};
        }
        json[@"name"]=folderName;
        NSError *error=nil;
        if (![NSFileManager.defaultManager createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self showThemeCreationError:error.localizedDescription]; return;
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:&error];
        if (!data || ![data writeToURL:[destination URLByAppendingPathComponent:@"theme.json"] options:NSDataWritingAtomic error:&error]) {
            [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
            [self showThemeCreationError:error.localizedDescription]; return;
        }
        [self applyThemePath:destination.path name:folderName];
        [self updateEditor];
    }]];
    [[self editorPresenter] presentViewController:prompt animated:YES completion:nil];
}
- (void)showThemeCreationError:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could Not Create Theme" message:message ?: @"The theme could not be saved." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [[self editorPresenter] presentViewController:alert animated:YES completion:nil];
}

- (void)applyThemeSelectorPopupStyle:(UIView *)panel {
    panel.backgroundColor=[UIColor colorWithWhite:0.035 alpha:0.98];
    panel.layer.cornerRadius=10;
    panel.layer.borderWidth=1;
    panel.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.16].CGColor;
    panel.clipsToBounds=YES;
    panel.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
}
- (UIButton *)editorButton:(NSString *)title action:(SEL)action frame:(CGRect)frame parent:(UIView *)parent {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem]; button.frame=frame;
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.96];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal]; button.layer.cornerRadius=6;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:button]; return button;
}
- (void)setupEditor {
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.tintColor=UIColor.whiteColor;
    _tools=[UIView new];
    _tools.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    _tools.tintColor=UIColor.whiteColor;
    _tools.backgroundColor=UIColor.systemBackgroundColor;
    _tools.layer.cornerRadius=10;
    [self addSubview:_tools]; _tools.hidden=YES;
    _profileButton=[self editorButton:@"Profile" action:@selector(showProfilePopup) frame:CGRectMake(8,8,220,32) parent:_tools];
    _profileButton.titleLabel.adjustsFontSizeToFitWidth=YES; _profileButton.titleLabel.minimumScaleFactor=0.75;
    _saveAsButton=[self editorButton:@"Save as…" action:@selector(showSaveAsPopup) frame:CGRectMake(236,8,116,32) parent:_tools];
    [self editorButton:@"Save" action:@selector(saveEdit) frame:CGRectMake(8,48,90,32) parent:_tools];
    [self editorButton:@"Cancel" action:@selector(cancelEdit) frame:CGRectMake(110,48,132,32) parent:_tools];
    [self editorButton:@"Reset all" action:@selector(resetAllControls) frame:CGRectMake(252,48,100,32) parent:_tools];
    _chooseButton=[self editorButton:@"A ▾" action:@selector(showControlPopup) frame:CGRectMake(8,86,120,30) parent:_tools];
    _colorWellButton=[UIButton buttonWithType:UIButtonTypeCustom];
    _colorWellButton.frame=CGRectMake(136,86,100,30);
    _colorWellButton.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.96];
    _colorWellButton.layer.cornerRadius=6;
    _colorWellButton.clipsToBounds=YES;
    _colorWellButton.accessibilityLabel=@"Choose control color";
    [_colorWellButton addTarget:self action:@selector(openEditorColorPicker) forControlEvents:UIControlEventTouchUpInside];
    [_tools addSubview:_colorWellButton];
    _colorTargetButton=[self editorButton:@"Fill Color ▾" action:@selector(showColorTargetPopup)
        frame:CGRectMake(244,86,108,30) parent:_tools];
    _colorTargetButton.titleLabel.adjustsFontSizeToFitWidth=YES;
    _colorTargetButton.titleLabel.minimumScaleFactor=0.68;

    // The custom rectangular button owns the full hit area; this view supplies
    // the rectangular rainbow border and color swatch artwork.
    _colorWellAppearance=[UIView new];
    _colorWellAppearance.frame=_colorWellButton.frame;
    _colorWellAppearance.backgroundColor=[UIColor colorWithWhite:0.12 alpha:1];
    _colorWellAppearance.layer.cornerRadius=6;
    _colorWellAppearance.clipsToBounds=YES;
    // Keep the decorative face non-interactive so the full rectangular button receives taps.
    _colorWellAppearance.userInteractionEnabled=NO;
    _colorWellAppearance.isAccessibilityElement=NO;
    [_tools addSubview:_colorWellAppearance];

    _colorWellRainbowBorder=[CAGradientLayer layer];
    _colorWellRainbowBorder.colors=@[
        (id)[UIColor colorWithRed:1 green:0.20 blue:0.20 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:0.72 blue:0.16 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.25 green:0.85 blue:0.35 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.18 green:0.65 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.62 green:0.35 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:0.20 blue:0.20 alpha:1].CGColor
    ];
    _colorWellRainbowBorder.startPoint=CGPointMake(0,0.5);
    _colorWellRainbowBorder.endPoint=CGPointMake(1,0.5);
    [_colorWellAppearance.layer addSublayer:_colorWellRainbowBorder];

    _colorWellSwatch=[UIView new];
    _colorWellSwatch.frame=CGRectInset(_colorWellButton.bounds,4,4);
    _colorWellSwatch.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _colorWellSwatch.layer.cornerRadius=3;
    _colorWellSwatch.clipsToBounds=YES;
    [_colorWellAppearance addSubview:_colorWellSwatch];

    _colorWellLockIcon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill"]];
    _colorWellLockIcon.frame=CGRectMake(174,91,24,20);
    _colorWellLockIcon.contentMode=UIViewContentModeScaleAspectFit;
    _colorWellLockIcon.tintColor=UIColor.whiteColor;
    _colorWellLockIcon.backgroundColor=UIColor.clearColor;
    _colorWellLockIcon.layer.cornerRadius=0;
    _colorWellLockIcon.clipsToBounds=NO;
    _colorWellLockIcon.userInteractionEnabled=NO;
    _colorWellLockIcon.hidden=YES;
    [_tools addSubview:_colorWellLockIcon];
    [_tools bringSubviewToFront:_colorWellLockIcon];
    _resetControlButton=[self editorButton:@"Reset control" action:@selector(resetControl) frame:CGRectMake(260,220,92,32) parent:_tools];
    _sizeSlider=[[UISlider alloc] initWithFrame:CGRectMake(78,120,274,30)];
    _sizeSlider.minimumValue=0.5; _sizeSlider.maximumValue=2;
    _alphaSlider=[[UISlider alloc] initWithFrame:CGRectMake(78,152,274,30)];
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
    _editInfo=[[UILabel alloc] initWithFrame:CGRectMake(8,184,344,32)];
    _editInfo.numberOfLines=2; _editInfo.font=[UIFont systemFontOfSize:11];
    _editInfo.textColor=UIColor.whiteColor; [_tools addSubview:_editInfo];
    _themeButton=[self editorButton:@"Theme: ANIMAL WELL ▾" action:@selector(toggleThemeMenu) frame:CGRectMake(8,220,164,32) parent:_tools];
    _themeMenuOverlay=[UIButton buttonWithType:UIButtonTypeCustom];
    _themeMenuOverlay.backgroundColor=UIColor.clearColor;
    _themeMenuOverlay.hidden=YES;
    [_themeMenuOverlay addTarget:self action:@selector(closeThemeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_themeMenuOverlay];
    _themeMenuPanel=[UIView new];
    [self applyThemeSelectorPopupStyle:_themeMenuPanel];
    [_themeMenuOverlay addSubview:_themeMenuPanel];
    _themeMenuScroll=[UIScrollView new];
    _themeMenuScroll.showsVerticalScrollIndicator=YES;
    [_themeMenuPanel addSubview:_themeMenuScroll];

    // Match the theme selector's dark, bordered, rounded appearance for editor popups.
    _editorPopupOverlay=[UIButton buttonWithType:UIButtonTypeCustom];
    _editorPopupOverlay.backgroundColor=UIColor.clearColor;
    _editorPopupOverlay.hidden=YES;
    [_editorPopupOverlay addTarget:self action:@selector(closeEditorPopup) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_editorPopupOverlay];
    _editorPopupPanel=[UIView new];
    [self applyThemeSelectorPopupStyle:_editorPopupPanel];
    _editorPopupPanel.userInteractionEnabled=YES;
    [_editorPopupOverlay addSubview:_editorPopupPanel];
    _editorPopupTitle=[UILabel new];
    _editorPopupTitle.textColor=UIColor.whiteColor;
    _editorPopupTitle.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _editorPopupTitle.frame=CGRectMake(12,6,280,30);
    [_editorPopupPanel addSubview:_editorPopupTitle];
    _editorPopupScroll=[UIScrollView new];
    _editorPopupScroll.showsVerticalScrollIndicator=YES;
    [_editorPopupPanel addSubview:_editorPopupScroll];

    UIButton *importThemeButton=[self editorButton:@"Import…" action:@selector(importThemeFolder) frame:CGRectMake(180,220,72,32) parent:_tools];
    importThemeButton.titleLabel.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    UIButton *createThemeButton=[self editorButton:@"Create theme" action:@selector(createCustomTheme)
        frame:CGRectMake(8,258,_launcherPreview ? 344 : 248,32) parent:_tools];
    createThemeButton.titleLabel.adjustsFontSizeToFitWidth=YES;
    importThemeButton.titleLabel.adjustsFontSizeToFitWidth=YES;
    importThemeButton.titleLabel.minimumScaleFactor=0.8;
    importThemeButton.titleLabel.lineBreakMode=NSLineBreakByClipping;

    // Runtime HUD toggles are only available in the live control editor.
    _fpsButton=[UIButton buttonWithType:UIButtonTypeSystem];
    _fpsButton.hidden=_launcherPreview;
    _fpsButton.frame=CGRectMake(264,258,40,32);
    _fpsButton.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.96];
    _fpsButton.layer.cornerRadius=6;
    _fpsButton.accessibilityLabel=@"FPS counter";
    _fpsButton.accessibilityHint=@"Toggle the FPS counter";
    [_fpsButton setImage:[UIImage systemImageNamed:@"speedometer"] forState:UIControlStateNormal];
    _fpsButton.imageView.contentMode=UIViewContentModeScaleAspectFit;
    _fpsButton.tintColor=UIColor.whiteColor;
    [_fpsButton addTarget:self action:@selector(toggleFPSCounter) forControlEvents:UIControlEventTouchUpInside];
    [_tools addSubview:_fpsButton];

    _hudButton=[UIButton buttonWithType:UIButtonTypeSystem];
    _hudButton.hidden=_launcherPreview;
    _hudButton.frame=CGRectMake(312,258,40,32);
    _hudButton.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.96];
    _hudButton.layer.cornerRadius=6;
    _hudButton.accessibilityLabel=@"Performance HUD";
    _hudButton.accessibilityHint=@"Toggle the performance HUD";
    [_hudButton setImage:[UIImage systemImageNamed:@"chart.bar.xaxis"] forState:UIControlStateNormal];
    _hudButton.imageView.contentMode=UIViewContentModeScaleAspectFit;
    _hudButton.tintColor=UIColor.whiteColor;
    [_hudButton addTarget:self action:@selector(togglePerformanceHUD) forControlEvents:UIControlEventTouchUpInside];
    [_tools addSubview:_hudButton];
    [self refreshHUDToggleButtons];
}
- (void)refreshHUDToggleButtons {
    BOOL fps=front_ios_runtime_fps_enabled();
    BOOL hud=front_ios_runtime_metal_hud_enabled();
    UIColor *normal=[UIColor colorWithWhite:0.12 alpha:0.96];
    UIColor *enabled=[UIColor colorWithRed:0.16 green:0.34 blue:0.20 alpha:1];
    _fpsButton.backgroundColor=fps ? enabled : normal;
    _hudButton.backgroundColor=hud ? enabled : normal;
    _fpsButton.tintColor=UIColor.whiteColor;
    _hudButton.tintColor=UIColor.whiteColor;
    _fpsButton.accessibilityValue=fps?@"On":@"Off";
    _hudButton.accessibilityValue=hud?@"On":@"Off";
}
- (void)toggleFPSCounter {
    BOOL fps=!front_ios_runtime_fps_enabled();
    front_ios_set_runtime_hud(fps,front_ios_runtime_metal_hud_enabled());
    [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    [self refreshHUDToggleButtons];
}
- (void)togglePerformanceHUD {
    BOOL hud=!front_ios_runtime_metal_hud_enabled();
    front_ios_set_runtime_hud(front_ios_runtime_fps_enabled(),hud);
    [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    [self refreshHUDToggleButtons];
}
- (void)closeEditorPopup { _editorPopupOverlay.hidden=YES; }
- (void)showEditorPopupWithTitle:(NSString *)title items:(NSArray<NSDictionary *> *)items {
    for (UIView *view in _editorPopupScroll.subviews) [view removeFromSuperview];
    _editorPopupTitle.text=title;
    CGFloat rowHeight=40, width=304, contentHeight=items.count*rowHeight;
    CGFloat visibleHeight=MIN(contentHeight,240);
    _editorPopupPanel.frame=CGRectMake(0,0,width,visibleHeight+50);
    _editorPopupTitle.frame=CGRectMake(12,6,width-24,30);
    _editorPopupScroll.frame=CGRectMake(8,40,width-16,visibleHeight);
    _editorPopupScroll.contentSize=CGSizeMake(width-16,contentHeight);
    [items enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        (void)stop;
        UIButton *row=[UIButton buttonWithType:UIButtonTypeSystem];
        row.frame=CGRectMake(0,idx*rowHeight,width-16,rowHeight);
        row.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeft;
        row.contentEdgeInsets=UIEdgeInsetsMake(0,10,0,10);
        row.titleLabel.font=[UIFont systemFontOfSize:14];
        row.titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        row.tintColor=UIColor.whiteColor;
        [row setTitle:item[@"title"] forState:UIControlStateNormal];
        void (^handler)(void)=item[@"handler"];
        [row addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            (void)action; [self closeEditorPopup]; if (handler) handler();
        }] forControlEvents:UIControlEventTouchUpInside];
        [_editorPopupScroll addSubview:row];
        if (idx+1<items.count) {
            UIView *separator=[[UIView alloc] initWithFrame:CGRectMake(0,(idx+1)*rowHeight-0.5,width-16,0.5)];
            separator.backgroundColor=[UIColor colorWithWhite:1 alpha:0.12];
            [_editorPopupScroll addSubview:separator];
        }
    }];
    _editorPopupOverlay.frame=self.bounds;
    _editorPopupPanel.center=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.safe));
    _editorPopupOverlay.hidden=NO;
    [self bringSubviewToFront:_editorPopupOverlay];
    [_editorPopupOverlay bringSubviewToFront:_editorPopupPanel];
}
- (void)showColorTargetPopup {
    NSArray<NSString *> *names=@[@"Fill Color",@"Border Color",@"Left Stick Track",@"Text Color",@"Pressed Text"];
    NSMutableArray *items=[NSMutableArray array];
    for (NSInteger target=0;target<names.count;target++) {
        NSInteger selectedTarget=target;
        NSString *title=target==_colorTarget ? [names[target] stringByAppendingString:@"  ✓"] : names[target];
        [items addObject:@{@"title":title,@"handler":[^{ self->_colorTarget=selectedTarget; [self updateEditor]; } copy]}];
    }
    [self showEditorPopupWithTitle:@"Color target" items:items];
}
- (void)showControlPopup {
    NSMutableArray *items=[NSMutableArray array];
    [items addObject:@{@"title":@"All controls", @"handler":[^{ self->_selected=-1; [self updateEditor]; } copy]}];
    for (int b=0;b<18;b++) if ([self editable:b]) {
        int selected=b;
        [items addObject:@{@"title":[self controlID:b], @"handler":[^{ self->_selected=selected; [self updateEditor]; } copy]}];
    }
    [items addObject:@{@"title":@"Layout Switcher", @"handler":[^{ self->_selected=18; [self updateEditor]; } copy]}];
    [self showEditorPopupWithTitle:@"Select control" items:items];
}
- (void)showProfilePopup {
    NSMutableArray *items=[NSMutableArray array];
    for (NSInteger slot=0;slot<4;slot++) {
        NSInteger target=slot; NSString *name=[_profiles name:slot];
        NSString *title=slot==_profiles.selected ? [name stringByAppendingString:@"  ✓"] : name;
        [items addObject:@{@"title":title, @"handler":[^{ [self selectProfile:target]; } copy]}];
    }
    [items addObject:@{@"title":@"Rename profile…", @"handler":[^{ [self renameProfile]; } copy]}];
    [self showEditorPopupWithTitle:@"Control profiles" items:items];
}
- (void)showSaveAsPopup {
    NSMutableArray *items=[NSMutableArray array];
    for (NSInteger slot=0;slot<4;slot++) if (slot!=_profiles.selected) {
        NSInteger target=slot; NSString *name=[_profiles name:slot];
        [items addObject:@{@"title":name, @"handler":[^{
            NSString *message=[NSString stringWithFormat:@"Replace %@ with this profile?",[self->_profiles name:target]];
            [self confirm:message actionTitle:@"Save copy" action:^{
                [self reset]; self->_dragTouch=nil;
                [self->_profiles copySlot:self->_profiles.selected to:target draft:self->_custom layout:self.controlsLayout];
                [self loadControls]; [self updateEditor]; [self setNeedsLayout];
            }];
        } copy]}];
    }
    if (!items.count) [items addObject:@{@"title":@"No other profile slots", @"handler":[^{} copy]}];
    [self showEditorPopupWithTitle:@"Save a copy to" items:items];
}
- (void)updateEditor {
    [self updateProfileMenu];
    [self updateThemeMenu];
    BOOL styleOnly=(_selected==18);
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
        _sizeSlider.value=styleOnly?1:[self scale:_selected];
        NSNumber *alpha=_custom[[self controlID:_selected]][@"alpha"];
        _alphaSlider.value=styleOnly?1:(alpha?alpha.floatValue:1);
    }
    _sizeSlider.enabled=!styleOnly;
    _alphaSlider.enabled=!styleOnly;
    _resetControlButton.enabled=!styleOnly;
    _editInfo.text=styleOnly ? @"Layout Switcher · Style only. Position and size are locked." :
        [NSString stringWithFormat:@"Size %.0f%% · Opacity %.0f%%\nDrag a control to move it.",_sizeSlider.value*100,_alphaSlider.value*100];
    // The control picker is shown by the custom rounded popup above.
    NSString *colorKey=_selected<0 ? nil : [self themeColorKeyForControl:_selected];
    _colorPickerControl=_selected;
    UIColor *wellColor=[self currentColorForEditorSelection];
    [_colorTargetButton setTitle:[NSString stringWithFormat:@"%@ ▾",[self colorTargetName]] forState:UIControlStateNormal];
    _editorColor=wellColor;
    [self refreshColorWellAppearance];
    BOOL builtInTheme=[self isBuiltInThemeSelected];
    BOOL hasColorTarget=(_colorTarget==2 ? _selected!=18 : (_selected<0 || colorKey!=nil || _colorTarget>=3));
    _colorWellButton.enabled=(hasColorTarget && !builtInTheme);
    _colorTargetButton.enabled=!builtInTheme;
    _colorTargetButton.alpha=builtInTheme?0.55:1.0;
    // The visual rectangle must stay transparent to hit-testing so the native
    // UIColorWell underneath receives taps in both editor presentations.
    _colorWellAppearance.userInteractionEnabled=NO;
    _colorWellButton.accessibilityLabel=builtInTheme ? @"Control color locked for built-in themes" :
        (_selected<0 ? @"Choose all controls color" :
         (colorKey ? [NSString stringWithFormat:@"Choose %@ color", [self controlID:_selected]] : @"Choose control color"));
    _colorWellLockIcon.hidden=!builtInTheme;
    [_tools bringSubviewToFront:_colorWellButton];
    [_tools bringSubviewToFront:_colorWellAppearance];
    [_tools bringSubviewToFront:_colorWellLockIcon];
    [self setNeedsLayout];
}
- (UIViewController *)editorPresenter {
    UIResponder *responder=self;
    while (responder && ![responder isKindOfClass:UIViewController.class]) responder=responder.nextResponder;
    UIViewController *presenter=(UIViewController *)responder;
    // The gamepad view is sometimes hosted below a custom window/controller whose
    // responder chain does not include its presenting view controller.
    if (!presenter) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow && window.rootViewController) { presenter=window.rootViewController; break; }
            }
            if (presenter) break;
        }
    }
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
    [_saveAsButton setTitle:@"Save as…" forState:UIControlStateNormal];
}
- (void)beginLauncherEdit {
    // The launcher preview is not a live gamepad session. Keep editing available
    // even when a physical controller is connected to the phone.
    _padOff=NO;
    [self toggleEditor];
}
- (void)toggleEditor {
    if (_editing) {
        BOOL wasVisible=!_tools.hidden;
        _tools.hidden=!_tools.hidden;
        // In the pre-launch editor, show this hint the first time its settings
        // panel is dismissed. The layout-mode switcher is the way to reopen it.
        if (_launcherPreview && wasVisible && _tools.hidden &&
            ![NSUserDefaults.standardUserDefaults boolForKey:@"DmPadLauncherConfigMenuReopenTipShown"]) {
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"DmPadLauncherReopenTipShown"];
            [self showLauncherReopenTip];
        }
        return;
    }
    _editWasTap=_tap;
    if (_tap) { _tap=NO; [self loadControls]; [self applyLayout]; }
    [self reset]; _editing=YES; _controls.hidden=_padOff; _selected=B_A; _tools.hidden=NO;
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @0.22;
        pulse.toValue = @1.0;
        pulse.duration = 0.34;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_editHighlight addAnimation:pulse forKey:@"synchronizedPulse"];
    }
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
    _editHighlight.hidden=YES;
    [_editHighlight removeAnimationForKey:@"synchronizedPulse"];
    [self setNeedsLayout];
}
- (void)saveEdit { [_profiles save:_custom layout:self.controlsLayout slot:_profiles.selected]; [self finishEdit]; }
- (void)cancelEdit { [self loadControls]; [self finishEdit]; }
- (void)resetAllControls { [_custom removeAllObjects]; [self updateEditor]; [self setNeedsLayout]; }
- (void)resetControl {
    if (_selected==18) return;
    if (_selected<0) {
        for (int b=0;b<18;b++) if ([self editable:b]) [_custom removeObjectForKey:[self controlID:b]];
    } else [_custom removeObjectForKey:[self controlID:_selected]];
    [self updateEditor]; [self setNeedsLayout];
}
- (void)storeControlAt:(CGPoint)point {
    if (_selected==18) return;
    CGRect safe=self.safe; if (safe.size.width<=0 || safe.size.height<=0) return;
    if (_selected<0 && _dragAllHomes.count) {
        CGPoint delta=CGPointMake(point.x-_dragHome.x,point.y-_dragHome.y);
        for (NSString *key in _dragAllHomes) {
            CGPoint home=_dragAllHomes[key].CGPointValue;
            // Clamp only the centre, not the control's full radius. Default
            // controls are deliberately allowed to overlap the safe-area edge.
            CGPoint moved=dm_pad_clamp(CGPointMake(home.x+delta.x,home.y+delta.y),safe,0);
            NSMutableDictionary *value=[_custom[key] mutableCopy] ?: [NSMutableDictionary dictionary];
            value[@"x"]=@((moved.x-safe.origin.x)/safe.size.width);
            value[@"y"]=@((moved.y-safe.origin.y)/safe.size.height);
            _custom[key]=value;
        }
    } else {
        point=dm_pad_clamp(point,safe,0);
        _custom[[self controlID:_selected]]=@{@"x":@((point.x-safe.origin.x)/safe.size.width),
            @"y":@((point.y-safe.origin.y)/safe.size.height),@"scale":@(_sizeSlider.value),@"alpha":@(_alphaSlider.value)};
    }
    [self setNeedsLayout]; [self refresh];
}
- (void)adjustControl {
    if (_selected==18) return;
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
    if (_selected==18) return;
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
    if (gestureRecognizer!=_editHold || _padOff || _editing) return NO;
    return [self inSwap:[touch locationInView:self]];
}
- (void)handleEditHold:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan && !_padOff && !_editing) {
        [self dismissMenuTip];
        [self toggleEditor];
    }
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
        if (dist(start,self.swapCenter)<=MAX(44*self.u,K_SWAP_R*self.u+12*self.u)) {
            _selected=18; _dragAllHomes=nil; [self updateEditor]; return;
        }
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
@property(nonatomic,strong) UIView *backgroundDimmer;
@end
@implementation DmPadLauncherEditorController
- (void)viewDidLoad {
    [super viewDidLoad];
    // The editor itself is transparent. The real launcher remains underneath;
    // its own background artwork is dimmed by an overlay added to the launcher view.
    self.view.backgroundColor=UIColor.clearColor;
    self.view.opaque=NO;
    self.view.alpha=0;

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
    if (!_backgroundDimmer) {
        _backgroundDimmer=[UIView new];
        _backgroundDimmer.backgroundColor=[UIColor colorWithWhite:0 alpha:0.68];
        _backgroundDimmer.alpha=0;
        _backgroundDimmer.translatesAutoresizingMaskIntoConstraints=NO;
        [launcher addSubview:_backgroundDimmer];
        [NSLayoutConstraint activateConstraints:@[
            [_backgroundDimmer.leadingAnchor constraintEqualToAnchor:launcher.leadingAnchor],
            [_backgroundDimmer.trailingAnchor constraintEqualToAnchor:launcher.trailingAnchor],
            [_backgroundDimmer.topAnchor constraintEqualToAnchor:launcher.topAnchor],
            [_backgroundDimmer.bottomAnchor constraintEqualToAnchor:launcher.bottomAnchor]
        ]];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"DmPadLauncherEditorVisibilityChanged" object:nil userInfo:@{@"editing":@YES}];
    [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha=1;
        self.backgroundDimmer.alpha=1;
    } completion:^(__unused BOOL finished) {
        [self.pad beginLauncherEdit];
    }];
}
- (void)closeEditor {
    [_pad saveEdit];
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionCurveEaseInOut animations:^{
        self.view.alpha=0;
        self.backgroundDimmer.alpha=0;
    } completion:^(__unused BOOL finished) {
        [NSNotificationCenter.defaultCenter postNotificationName:@"DmPadLauncherEditorVisibilityChanged" object:nil userInfo:@{@"editing":@NO}];
        [self.backgroundDimmer removeFromSuperview];
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
