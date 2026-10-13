// PeakyMedia — a tiny dylib that streams Now Playing info as JSON lines.
//
// Since macOS 15.4, MediaRemote only answers processes Apple trusts, so a normal
// app gets nil back. /usr/bin/perl is Apple-signed and *is* trusted, so Peaky
// launches perl, perl loads this dylib via DynaLoader and calls peaky_stream().
//
// stdout: one JSON object per line (state updates)
// stdin:  commands — play | pause | toggle | next | prev | seek <seconds>

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);

static MRGetInfoFn getInfo;
static MRGetPIDFn getPID;
static MRGetPlayingFn getPlaying;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;

static NSData *lastArtwork;
static BOOL emitPending;
static dispatch_source_t stdinSource;
static dispatch_source_t resyncTimer;
static NSMutableString *inputBuffer;

static void writeLine(NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void copyString(NSDictionary *info, NSString *key, NSMutableDictionary *out, NSString *name) {
    id v = info[key];
    if ([v isKindOfClass:NSString.class]) out[name] = v;
}

static void copyNumber(NSDictionary *info, NSString *key, NSMutableDictionary *out, NSString *name) {
    id v = info[key];
    if ([v isKindOfClass:NSNumber.class]) out[name] = v;
}

static void emitNow(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        getPID(q, ^(int pid) {
            getPlaying(q, ^(Boolean playing) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                o[@"playing"] = @(playing ? YES : NO);
                o[@"pid"] = @(pid);
                copyString(info, @"kMRMediaRemoteNowPlayingInfoTitle", o, @"title");
                copyString(info, @"kMRMediaRemoteNowPlayingInfoArtist", o, @"artist");
                copyString(info, @"kMRMediaRemoteNowPlayingInfoAlbum", o, @"album");
                copyNumber(info, @"kMRMediaRemoteNowPlayingInfoDuration", o, @"duration");
                copyNumber(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime", o, @"elapsed");
                copyNumber(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", o, @"rate");
                id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([ts isKindOfClass:NSDate.class]) o[@"timestamp"] = @([(NSDate *)ts timeIntervalSince1970]);

                id art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class] && [(NSData *)art length] > 0) {
                    if (![art isEqualToData:lastArtwork]) {
                        lastArtwork = art;
                        o[@"artwork"] = [(NSData *)art base64EncodedStringWithOptions:0];
                    } else {
                        o[@"artworkSame"] = @YES;
                    }
                } else {
                    o[@"noArtwork"] = @YES;
                }
                writeLine(o);
            });
        });
    });
}

// MediaRemote fires several notifications per track change; coalesce them.
static void scheduleEmit(void) {
    if (emitPending) return;
    emitPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emitPending = NO;
        emitNow();
    });
}

static void handleCommand(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"play"]) sendCommand(0, nil);
    else if ([cmd isEqualToString:@"pause"]) sendCommand(1, nil);
    else if ([cmd isEqualToString:@"toggle"]) sendCommand(2, nil);
    else if ([cmd isEqualToString:@"next"]) sendCommand(4, nil);
    else if ([cmd isEqualToString:@"prev"]) sendCommand(5, nil);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) setElapsed([parts[1] doubleValue]);
    else if ([cmd isEqualToString:@"refresh"]) { lastArtwork = nil; }
    scheduleEmit();
}

void peaky_stream(void) {
    @autoreleasepool {
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!mr) { writeLine(@{@"error": @"MediaRemote not found"}); exit(1); }
        getInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        getPID = (MRGetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
        getPlaying = (MRGetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        sendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
        setElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        MRRegisterFn reg = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!getInfo || !getPID || !getPlaying || !sendCommand || !setElapsed || !reg) {
            writeLine(@{@"error": @"MediaRemote symbols missing"});
            exit(1);
        }

        reg(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *n) { scheduleEmit(); }];
        }

        inputBuffer = [NSMutableString string];
        stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(stdinSource, ^{
            char buf[1024];
            ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
            if (n <= 0) exit(0); // Peaky went away
            NSString *chunk = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
            if (chunk) [inputBuffer appendString:chunk];
            NSRange r;
            while ((r = [inputBuffer rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [inputBuffer substringToIndex:r.location];
                [inputBuffer deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
                line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (line.length) handleCommand(line);
            }
        });
        dispatch_resume(stdinSource);

        // Belt and braces: resync every 15s in case a notification is missed.
        resyncTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(resyncTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), 15 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(resyncTimer, ^{ scheduleEmit(); });
        dispatch_resume(resyncTimer);

        emitNow();
    }
    CFRunLoopRun();
}
