#import <Foundation/Foundation.h>
#import "include/AudioGuard.h"

bool IridiumRunCatchingNSException(void (^block)(void), char *reason, size_t capacity) {
    @try {
        block();
        return true;
    } @catch (NSException *exception) {
        if (reason != NULL && capacity > 0) {
            NSString *text = exception.reason.length > 0 ? exception.reason : exception.name;
            if (text == nil) { text = @"Unknown audio error"; }
            if (![text getCString:reason maxLength:capacity encoding:NSUTF8StringEncoding]) {
                reason[0] = '\0';
            }
        }
        return false;
    }
}
