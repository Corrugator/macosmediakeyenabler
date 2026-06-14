//
//  main.m
//
//  Created by Milan Toth on 2016. 12. 19..
//  Copyright © 2016. Milan Toth. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Headless-Helfer: registriert/entfernt das Login-Item über die
        // App-eigene SMAppService-API (gleicher Mechanismus wie der Menüpunkt
        // "Open at login") und beendet sich sofort – ohne UI/Event-Tap.
        for (int i = 1; i < argc; i++) {
            BOOL reg = (strcmp(argv[i], "--register-login-item") == 0);
            BOOL unreg = (strcmp(argv[i], "--unregister-login-item") == 0);
            if (reg || unreg) {
                NSError *error = nil;
                SMAppService *service = [SMAppService mainAppService];
                if (reg) [service registerAndReturnError:&error];
                else     [service unregisterAndReturnError:&error];
                if (error) {
                    fprintf(stderr, "login item %s failed: %s\n",
                            reg ? "register" : "unregister",
                            error.localizedDescription.UTF8String);
                    return 1;
                }
                fprintf(stdout, "login item %s ok (status=%ld)\n",
                        reg ? "registered" : "unregistered",
                        (long)[SMAppService mainAppService].status);
                return 0;
            }
        }
    }
    return NSApplicationMain(argc, argv);
}
