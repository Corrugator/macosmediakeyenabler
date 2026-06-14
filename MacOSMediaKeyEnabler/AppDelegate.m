#import "AppDelegate.h"
#import "Music.h"
#import "Spotify.h"
#import <ScriptingBridge/ScriptingBridge.h>
#import <ServiceManagement/ServiceManagement.h>
#import <CoreServices/CoreServices.h>
#import <UserNotifications/UserNotifications.h>

typedef NS_ENUM(NSInteger, MediaKeysPrioritize)
{
    // Normal behavior (without priority; send events to Music and Spotify if both are open)
    MediaKeysPrioritizeNone,
    // If both apps are open, prioritize Music over Spotify
    MediaKeysPrioritizeMusic,
    // If both apps are open, prioritize Spotify over Music
    MediaKeysPrioritizeSpotify
};

typedef NS_ENUM(NSInteger, PauseState)
{
    // pause app
    PauseStateNone,
    // pause app
    PauseStatePause,
    // pause app automatically when Music and Spotify is not running
    PauseStateAutomatic,
};

typedef NS_ENUM(NSInteger, KeyHoldState)
{
    KeyHoldStateNone,
    KeyHoldStateWaiting,
    KeyHoldStateHolding
};

static NSString *kUserDefaultsPriorityOptionKey = @"user_priority_option";
static NSString *kUserDefaultsPauseOptionKey = @"user_pause_option";

PauseState pauseState;
KeyHoldState keyHoldStatus;
MediaKeysPrioritize mediaKeysPriority;

@interface AppDelegate ()
{
    NSStatusItem* statusItem;
    CFMachPortRef eventPort;
    CFRunLoopSourceRef eventPortSource;
    NSMutableArray *priorityOptionItems;
    NSMutableArray *pauseOptionItems;
    NSMenuItem *startupItem;
    NSTimer *tapRetryTimer;
}

@end

@implementation AppDelegate

// Startet die Wiedergabe der Mediathek. Nötig, weil playpause im Zustand
// "stopped" (frisch gestartetes Music ohne aktuellen Titel) wirkungslos ist.
// Läuft asynchron: direkt nach dem Launch ist Music noch nicht per Apple
// Events erreichbar, und der Event-Tap-Callback darf nicht blockieren.
static void startMusicLibraryPlayback(void)
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Music regulär über NSWorkspace starten. Ein impliziter Launch über
        // Apple Events endet während der Startphase in einer unbrauchbar
        // gebundenen ScriptingBridge-Verbindung.
        if (![[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Music"] firstObject])
        {
            NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.Music"];
            if (!url) return;
            NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
            config.activates = NO;
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:config completionHandler:nil];
        }

        for (int attempt = 0; attempt < 30; attempt++)
        {
            NSRunningApplication *app = [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Music"] firstObject];
            if (app.finishedLaunching)
            {
                @try
                {
                    MusicApplication *music = [SBApplication applicationWithBundleIdentifier:@"com.apple.Music"];

                    // Erfolg wird über den Player-Status verifiziert: ein frisch
                    // gestartetes Music nimmt play-Befehle zwar an, verwirft sie
                    // aber stillschweigend, solange die Mediathek noch lädt.
                    // (paused = Titel geladen, der Nutzer war schneller — fertig.)
                    MusicEPlS state = [music playerState];
                    if (state == MusicEPlSPlaying || state == MusicEPlSPaused) return;

                    // count materialisiert das lazy SBElementArray — ohne den
                    // Aufruf liefert der Indexzugriff keine gültige Referenz.
                    SBElementArray<MusicSource *> *sources = [music sources];
                    if ([sources count] > 0)
                    {
                        SBElementArray<MusicLibraryPlaylist *> *playlists = [[sources objectAtIndex:0] libraryPlaylists];
                        if ([playlists count] > 0)
                        {
                            [[playlists objectAtIndex:0] playOnce:NO];
                        }
                    }
                }
                @catch (NSException *e) { /* Music (noch) nicht erreichbar */ }
            }
            usleep(500 * 1000);
        }
        NSLog(@"startMusicLibraryPlayback: Wiedergabe kam nicht zustande, aufgegeben.");
    });
}

// Fragt TCC, ob wir die Ziel-App per Apple Events steuern dürfen.
// askUserIfNeeded == NO -> schnell und NICHT blockierend, daher sicher im
// Event-Tap-Callback verwendbar. status-Werte:
//   noErr (0)                      -> erlaubt
//   errAEEventNotPermitted (-1743) -> ausdrücklich verweigert
//   errAEEventWouldRequireUserConsent (-1744) -> noch nicht entschieden
//   procNotFound (-600)            -> Ziel-App läuft nicht
static OSStatus automationStatus(NSString *bundleID, Boolean askUserIfNeeded)
{
    const char *bid = [bundleID UTF8String];
    AEAddressDesc target;
    OSStatus err = AECreateDesc(typeApplicationBundleID, bid, strlen(bid), &target);
    if ( err != noErr ) return err;
    OSStatus status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askUserIfNeeded);
    AEDisposeDesc(&target);
    return status;
}

// Backup-Kernfrage: Würden wir diesen Player steuern wollen, dürfen es aber
// definitiv nicht? Dann darf die Taste nicht verschluckt werden.
static BOOL automationDenied(NSString *bundleID)
{
    return automationStatus(bundleID, false) == errAEEventNotPermitted;
}

// Weist den Nutzer dezent darauf hin, dass die Steuerung wegen fehlender
// Automation-Erlaubnis nicht möglich war. Gedrosselt auf höchstens einmal pro
// 30 s, damit nicht jeder Tastendruck eine Meldung erzeugt. Läuft im
// Event-Tap-Callback (Main-Thread), daher kein Lock nötig.
static void notifyAutomationDenied(NSString *appName)
{
    static NSTimeInterval lastNotified = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if ( now - lastNotified < 30.0 ) return;
    lastNotified = now;

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = NSLocalizedString(@"Mediensteuerung blockiert", @"Notification title when automation permission is missing");
    content.body = [NSString stringWithFormat:
                    NSLocalizedString(@"%@ konnte nicht gesteuert werden – die Automation-Erlaubnis fehlt. Systemeinstellungen → Datenschutz & Sicherheit → Automation.", @"Notification body when automation permission is missing"),
                    appName];

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"automation-denied"
                                                                          content:content
                                                                          trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

static CGEventRef tapEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
    @autoreleasepool
    {
        AppDelegate *self = (__bridge id)refcon;
        
        if(type == kCGEventTapDisabledByTimeout)
        {
            CGEventTapEnable(self->eventPort, TRUE);
            return event;
        }
        
        if(type == kCGEventTapDisabledByUserInput)
        {
            return event;
        }
        
        if(type != NX_SYSDEFINED )
        {
            return event;
        }
        
        NSEvent *nsEvent = nil;
        @try
        {
            nsEvent = [NSEvent eventWithCGEvent:event];
        }
        @catch (NSException * e)
        {
            return event;
        }
        
        if([nsEvent subtype] != 8)
        {
            return event;
        }
        
        int keyCode = (([nsEvent data1] & 0xFFFF0000) >> 16);
        
        if (keyCode != NX_KEYTYPE_PLAY &&
            keyCode != NX_KEYTYPE_FAST &&
            keyCode != NX_KEYTYPE_REWIND &&
            keyCode != NX_KEYTYPE_PREVIOUS &&
            keyCode != NX_KEYTYPE_NEXT)
        {
            return event;
        }
        
        MusicApplication *music = [SBApplication applicationWithBundleIdentifier:@"com.apple.Music"];
        SpotifyApplication *spotify = [SBApplication applicationWithBundleIdentifier:@"com.spotify.client"];

        if ( pauseState == PauseStatePause )
        {
            return event;
        }

        BOOL musicRunning = [music isRunning];
        BOOL spotifyRunning = [spotify isRunning];

        if (!musicRunning && !spotifyRunning)
        {
            // "Pause if no player is running": macOS-Standardverhalten nutzen,
            // damit z.B. Web-Player die Tasten erhalten.
            if (pauseState == PauseStateAutomatic) return event;

            // Ohne explizite Priorität gibt es keinen Player, der gestartet
            // werden soll — Event ans System durchreichen.
            if (mediaKeysPriority == MediaKeysPrioritizeNone) return event;

            // Explizite Priorität: nur die Play-Taste startet den gewählten
            // Player, alle anderen Tasten gehen ans System.
            if (keyCode != NX_KEYTYPE_PLAY) return event;
        }

        // --- Backup: verschluckte Tasten verhindern ---
        // Wir kämen hierher nur, wenn wir laut Modus einen laufenden Player
        // steuern wollen. Fehlt für jeden in Frage kommenden, laufenden Player
        // die Automation-Erlaubnis, reichen wir die Taste ans System durch,
        // statt sie wirkungslos zu schlucken. So bleibt die Mediensteuerung
        // (macOS-Standard, Web-Player) funktionsfähig, selbst wenn die
        // Berechtigung fehlt oder zurückgezogen wurde.
        switch ( mediaKeysPriority )
        {
            case MediaKeysPrioritizeMusic:
                if ( musicRunning && automationDenied(@"com.apple.Music") ) { notifyAutomationDenied(@"Music"); return event; }
                break;
            case MediaKeysPrioritizeSpotify:
                if ( spotifyRunning && automationDenied(@"com.spotify.client") ) { notifyAutomationDenied(@"Spotify"); return event; }
                break;
            case MediaKeysPrioritizeNone:
            {
                BOOL musicDenied   = musicRunning   && automationDenied(@"com.apple.Music");
                BOOL spotifyDenied = spotifyRunning && automationDenied(@"com.spotify.client");
                if ( !(musicRunning && !musicDenied) && !(spotifyRunning && !spotifyDenied) )
                {
                    notifyAutomationDenied( musicDenied ? @"Music" : @"Spotify" );
                    return event;
                }
                break;
            }
        }

        int keyFlags = ([nsEvent data1] & 0x0000FFFF);
        BOOL keyIsPressed = (((keyFlags & 0xFF00) >> 8)) == 0xA;
        
        if (keyIsPressed)
        {
            switch ( mediaKeysPriority )
            {
                case MediaKeysPrioritizeMusic:
                {
                    switch (keyCode)
                    {
                        case NX_KEYTYPE_PLAY:
                        {
                            if (!musicRunning || [music playerState] == MusicEPlSStopped)
                            {
                                startMusicLibraryPlayback();
                            }
                            else
                            {
                                [music playpause];
                            }
                            break;
                        }
                        default:
                        {
                            if (keyHoldStatus == KeyHoldStateNone)
                            {
                                keyHoldStatus = KeyHoldStateWaiting;
                            }
                            else if (keyHoldStatus == KeyHoldStateWaiting)
                            {
                                keyHoldStatus = KeyHoldStateHolding;
                                switch (keyCode)
                                {
                                    case NX_KEYTYPE_NEXT:
                                    case NX_KEYTYPE_FAST:
                                    {
                                        [music fastForward];
                                        break;
                                    }
                                    case NX_KEYTYPE_PREVIOUS:
                                    case NX_KEYTYPE_REWIND:
                                    {
                                        [music rewind];
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    break;
                }
                case MediaKeysPrioritizeSpotify:
                {
                    switch (keyCode)
                    {
                        case NX_KEYTYPE_PLAY:
                        {
                            [spotify playpause];
                            break;
                        }
                        case NX_KEYTYPE_NEXT:
                        case NX_KEYTYPE_FAST:
                        {
                            [spotify nextTrack];
                            break;
                        };
                        case NX_KEYTYPE_PREVIOUS:
                        case NX_KEYTYPE_REWIND:
                        {
                            [spotify previousTrack];
                            break;
                        }
                    }
                    break;
                }
                case MediaKeysPrioritizeNone:
                {
                    switch (keyCode)
                    {
                        case NX_KEYTYPE_PLAY:
                        {
                            if ( spotifyRunning ) [spotify playpause];
                            if ( musicRunning )
                            {
                                if ([music playerState] == MusicEPlSStopped)
                                {
                                    startMusicLibraryPlayback();
                                }
                                else
                                {
                                    [music playpause];
                                }
                            }
                            break;
                        }
                        case NX_KEYTYPE_NEXT:
                        case NX_KEYTYPE_FAST:
                        {
                            if ( spotifyRunning ) [spotify nextTrack];
                            if ( musicRunning ) [music nextTrack];
                            break;
                        }
                        case NX_KEYTYPE_PREVIOUS:
                        case NX_KEYTYPE_REWIND:
                        {
                            if ( spotifyRunning ) [spotify previousTrack];
                            if ( musicRunning ) [music backTrack];
                            break;
                        }
                    }
                    break;
                }
            }
        }
        else
        {
            switch (keyHoldStatus)
            {
                case KeyHoldStateWaiting:
                {
                    if (mediaKeysPriority == MediaKeysPrioritizeMusic)
                    {
                        switch (keyCode)
                        {
                            case NX_KEYTYPE_NEXT:
                            case NX_KEYTYPE_FAST:
                            {
                                [music nextTrack];
                                break;
                            }
                            case NX_KEYTYPE_PREVIOUS:
                            case NX_KEYTYPE_REWIND:
                            {
                                [music backTrack];
                                break;
                            }
                        }
                    }
                    break;
                }
                case KeyHoldStateHolding:
                {
                    // Stop fast forwarding / rewinding
                    
                    if (mediaKeysPriority == MediaKeysPrioritizeMusic)
                    {
                        [music resume];
                    }
                    break;
                }
                case KeyHoldStateNone:
                {
                    break;
                }
            }
            keyHoldStatus = KeyHoldStateNone;
        }
        
        // stop propagation
        
        return NULL;
    }
}

- ( void ) applicationDidFinishLaunching : ( NSNotification*) theNotification
{
    // init containers
    
    priorityOptionItems = [[NSMutableArray alloc] init];
    pauseOptionItems = [[NSMutableArray alloc] init];
    
    // init states
    
    pauseState = PauseStateNone;
    keyHoldStatus = KeyHoldStateNone;
    mediaKeysPriority = MediaKeysPrioritizeNone;
    
    NSNumber *option = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsPriorityOptionKey];
    if ( option )
    {
        mediaKeysPriority = [option integerValue];
    }
    
    option = [[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsPauseOptionKey];
    if ( option )
    {
        pauseState = [option integerValue];
    }
    
    // Version string
    
    NSDictionary *bundleInfo = [[NSBundle mainBundle] infoDictionary];
    NSString *versionString = [NSString stringWithFormat:@"Version %@ (build %@)",
                               bundleInfo[@"CFBundleShortVersionString"],
                               bundleInfo[@"CFBundleVersion"] ];
    
    NSMenu *menu = [ [ NSMenu alloc ] init ];
    [ menu addItemWithTitle : versionString action : nil keyEquivalent : @"" ];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line
    
    [pauseOptionItems addObject:[ menu addItemWithTitle: NSLocalizedString(@"Pause", @"Pause") action : @selector(manualPause) keyEquivalent : @"" ]];
    [pauseOptionItems addObject:[ menu addItemWithTitle: NSLocalizedString(@"Pause if no player is running", @"Pause if no player is running") action : @selector(autoPause) keyEquivalent : @"" ]];
    
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line
    
    [priorityOptionItems addObject:[ menu addItemWithTitle: NSLocalizedString(@"Send events to both players", @"Send events to both players") action : @selector(prioritizeNone) keyEquivalent : @"" ]];
    [priorityOptionItems addObject:[ menu addItemWithTitle: NSLocalizedString(@"Prioritize Music", @"Prioritize Music") action : @selector(prioritizeMusic) keyEquivalent : @"" ]];
    [priorityOptionItems addObject:[ menu addItemWithTitle: NSLocalizedString(@"Prioritize Spotify", @"Prioritize Spotify") action : @selector(prioritizeSpotify) keyEquivalent : @"" ]];

    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    startupItem = [ menu addItemWithTitle:NSLocalizedString(@"Open at login", @"Open at login") action:@selector(toggleStartupItem) keyEquivalent:@""];
    [ menu addItem : [ NSMenuItem separatorItem ] ]; // A thin grey line

    [ menu addItemWithTitle : NSLocalizedString(@"Donate if you like the app", @"Donate if you like the app") action : @selector(support) keyEquivalent : @"" ];
    [ menu addItemWithTitle : NSLocalizedString(@"Check for updates", @"Check for updates") action : @selector(update) keyEquivalent : @"" ];
    [ menu addItemWithTitle : NSLocalizedString(@"Quit", @"Quit") action : @selector(terminate) keyEquivalent : @"" ];
    
    // SF Symbol "pianokeys" — scharf, adaptiv (hell/dunkel) und ohne PNG-Assets.
    NSImage* image = [ NSImage imageWithSystemSymbolName : @"pianokeys" accessibilityDescription : @"macOS Media Key Enabler" ];
    NSImageSymbolConfiguration *symbolConfig = [ NSImageSymbolConfiguration configurationWithPointSize : 15 weight : NSFontWeightRegular ];
    image = [ image imageWithSymbolConfiguration : symbolConfig ];
    [ image setTemplate : YES ];

    statusItem = [ [ NSStatusBar systemStatusBar ] statusItemWithLength : NSVariableStatusItemLength ];
    statusItem.button.toolTip = @"macOS Media Key Enabler";
    statusItem.button.image = image;
    [ statusItem setMenu : menu ];
    
    [self updateStartupItemState];
    [self updatePauseState];
    [self updateOptionState];
    
    NSDictionary *trustOpts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)trustOpts);

    // Automation-Zustimmung früh und einmalig anstoßen (askUserIfNeeded == YES
    // -> kann den Systemdialog zeigen). Bewusst auf einem Hintergrund-Thread,
    // damit ein evtl. blockierender Dialog NICHT den Event-Tap-Callback oder
    // den Main-Thread aufhält. Wirkt nur für bereits laufende Player; ist einer
    // nicht offen, liefert TCC procNotFound und es passiert nichts.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        automationStatus(@"com.apple.Music", true);
        automationStatus(@"com.spotify.client", true);
    });

    // Erlaubnis für die Hinweis-Benachrichtigung anfordern (einmalig).
    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                      completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if ( error ) NSLog(@"Notification-Berechtigung: %@", error);
    }];

    if ( ![self attemptCreateEventTap] ) {
        // Berechtigung fehlt (noch) — z.B. nach einem Rebuild, weil die
        // Ad-hoc-Signatur den TCC-Eintrag entwertet. Periodisch neu versuchen,
        // damit nach der Rechtevergabe kein manueller Neustart nötig ist.
        NSLog(@"CGEventTapCreate failed — Accessibility permission required, retrying every 5s.");
        tapRetryTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(retryCreateEventTap:) userInfo:nil repeats:YES];
    }
}

- (BOOL)attemptCreateEventTap
{
    if ( eventPort ) return YES;

    eventPort = CGEventTapCreate( kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, NX_SYSDEFINEDMASK, tapEventCallback, (__bridge void * _Nullable)(self));
    if ( !eventPort ) {
        eventPort = CGEventTapCreate( kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, NX_SYSDEFINEDMASK, tapEventCallback, (__bridge void * _Nullable)(self));
    }
    if ( !eventPort ) return NO;

    eventPortSource = CFMachPortCreateRunLoopSource( kCFAllocatorSystemDefault, eventPort, 0 );
    [self startEventSession];
    return YES;
}

- (void)retryCreateEventTap:(NSTimer *)timer
{
    if ( [self attemptCreateEventTap] ) {
        [tapRetryTimer invalidate];
        tapRetryTimer = nil;
    }
}

- ( void ) startEventSession
{
    if (!eventPortSource) return;
    if (pauseState != PauseStatePause && !CFRunLoopContainsSource(CFRunLoopGetMain(), eventPortSource, kCFRunLoopCommonModes)) {
        CFRunLoopAddSource( CFRunLoopGetMain(), eventPortSource, kCFRunLoopCommonModes );
        CGEventTapEnable( eventPort, true );
    }
}

- ( void ) stopEventSession
{
    if (!eventPortSource) return;
    if (CFRunLoopContainsSource(CFRunLoopGetMain(), eventPortSource, kCFRunLoopCommonModes)) {
        CGEventTapEnable( eventPort, false );
        CFRunLoopRemoveSource( CFRunLoopGetMain(), eventPortSource, kCFRunLoopCommonModes );
    }
}

- ( void ) terminate
{
    [ NSApp terminate : nil ];
}

- ( void ) support
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: @"https://paypal.me/milgra"]];
}

- ( void ) update
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString: @"https://github.com/Corrugator/macosmediakeyenabler/releases"]];
}


#pragma mark - App priorization

- (void)prioritizeNone
{
    mediaKeysPriority = MediaKeysPrioritizeNone;
    [[NSUserDefaults standardUserDefaults] setObject:@(mediaKeysPriority) forKey:kUserDefaultsPriorityOptionKey];
    [self updateOptionState];
}

- (void)prioritizeMusic
{
    mediaKeysPriority = MediaKeysPrioritizeMusic;
    [[NSUserDefaults standardUserDefaults] setObject:@(mediaKeysPriority) forKey:kUserDefaultsPriorityOptionKey];
    [self updateOptionState];
}

- (void)prioritizeSpotify
{
    mediaKeysPriority = MediaKeysPrioritizeSpotify;
    [[NSUserDefaults standardUserDefaults] setObject:@(mediaKeysPriority) forKey:kUserDefaultsPriorityOptionKey];
    [self updateOptionState];
}

- (void)manualPause
{
    if ( pauseState != PauseStatePause )
    {
        pauseState = PauseStatePause;
        [self stopEventSession];
    }
    else
    {
        pauseState = PauseStateNone;
        [self startEventSession];
    }

    [[NSUserDefaults standardUserDefaults] setObject:@(pauseState) forKey:kUserDefaultsPauseOptionKey];
    [self updatePauseState];
}

- (void)autoPause
{
    if ( pauseState != PauseStateAutomatic )
    {
        pauseState = PauseStateAutomatic;
    }
    else
    {
        pauseState = PauseStateNone;
    }
    [[NSUserDefaults standardUserDefaults] setObject:@(pauseState) forKey:kUserDefaultsPauseOptionKey];
    [self updatePauseState];
    
    [self startEventSession];
}

#pragma mark - Startup Item
- (void)toggleStartupItem {
    SMAppService *service = [SMAppService mainAppService];
    NSError *error = nil;
    if ( service.status == SMAppServiceStatusEnabled ) {
        [service unregisterAndReturnError:&error];
    }
    else {
        [service registerAndReturnError:&error];
    }
    if ( error ) {
        NSLog(@"SMAppService toggle failed: %@", error);
    }

    [self updateStartupItemState];
}

#pragma mark - UI refresh

- (void)updateOptionState
{
    // Verify if a choice was selected, otherwise mark "None" as the default
    
    NSNumber *option = [[NSUserDefaults standardUserDefaults] valueForKey:kUserDefaultsPriorityOptionKey];
    if ( option )
    {
        mediaKeysPriority = [option integerValue];
    }
    
    // Mark with a tick the selected item from priority options
    
    for ( NSUInteger index = 0, num = priorityOptionItems.count; index < num; index++ )
    {
        NSMenuItem *item = priorityOptionItems[index];
        [item setState:( index == mediaKeysPriority ? NSControlStateValueOn : NSControlStateValueOff )];
    }
}

- (void)updatePauseState
{
    NSMenuItem *item0 = pauseOptionItems[0];
    NSMenuItem *item1 = pauseOptionItems[1];
    
    [item0 setState: pauseState == PauseStatePause ? NSControlStateValueOn : NSControlStateValueOff];
    [item1 setState: pauseState == PauseStateAutomatic ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)updateStartupItemState {
    BOOL enabled = [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    [startupItem setState: enabled ? NSControlStateValueOn : NSControlStateValueOff];
}

@end






