#import "MJMenuIcon.h"
#import "variables.h"
#import "Hammerspoon-Swift.h"

static void reflect_defaults(void);

static NSStatusItem* statusItem;
static NSMenu* menuItemMenu;
static HSShortcutPanelController* shortcutPanelController;

@interface MJMenuIconClickHandler : NSObject
- (void)statusItemClicked:(id)sender;
@end

@implementation MJMenuIconClickHandler
- (void)statusItemClicked:(id)sender {
    NSEvent* event = NSApp.currentEvent;
    if (event.type == NSEventTypeRightMouseUp) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [statusItem popUpStatusItemMenu:menuItemMenu];
#pragma clang diagnostic pop
    } else if (statusItem.button) {
        [shortcutPanelController toggleWithRelativeTo:statusItem.button];
    }
}
@end

static MJMenuIconClickHandler* clickHandler;

void MJMenuIconSetup(NSMenu* menu) {
    menuItemMenu = menu;
    shortcutPanelController = [[HSShortcutPanelController alloc] init];
    clickHandler = [[MJMenuIconClickHandler alloc] init];
    reflect_defaults();
}

BOOL MJMenuIconVisible(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:MJShowMenuIconKey];
}

void MJMenuIconSetVisible(BOOL visible) {
    [[NSUserDefaults standardUserDefaults] setBool:visible
                                            forKey:MJShowMenuIconKey];
    reflect_defaults();
}

static void reflect_defaults(void) {
    if (MJMenuIconVisible()) {
        NSImage* icon = [NSImage imageNamed:@"statusicon"];
        [icon setTemplate:YES];
        
        statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        statusItem.button.image = icon;
        statusItem.button.target = clickHandler;
        statusItem.button.action = @selector(statusItemClicked:);
        [statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
    }
    else {
        if (statusItem) {
            [[NSStatusBar systemStatusBar] removeStatusItem: statusItem];
            statusItem = nil;
        }
    }
}
