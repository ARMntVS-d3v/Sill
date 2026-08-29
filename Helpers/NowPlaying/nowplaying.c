// "Now playing" helper. As of macOS 15.4, mediaremoted only hands Now Playing info to
// processes with a com.apple.* bundle id, so the system's /usr/bin/perl loads this
// library — it has the required entitlement. Verified live on 26.5.2: our own process
// gets nil, perl gets the full dictionary.
//
// Protocol: one line of JSON on stdout per change; commands as lines on stdin
// (play, pause, toggle, next, prev). Lives only while the panel is open — Sill kills the process.

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(uint32_t, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));

static GetInfoFn getInfo;
static GetPlayingFn getPlaying;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;
static GetPIDFn getPID;
static pthread_mutex_t writeLock = PTHREAD_MUTEX_INITIALIZER;

// MediaRemote commands — order taken from the framework's headers
enum { CMD_PLAY = 0, CMD_PAUSE = 1, CMD_TOGGLE = 2, CMD_NEXT = 4, CMD_PREV = 5 };

static void printEscaped(const char *value) {
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        switch (*p) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*p < 0x20) printf("\\u%04x", *p);
            else putchar(*p);
        }
    }
}

static void printString(const char *key, CFDictionaryRef info, CFStringRef cfKey) {
    CFStringRef value = CFDictionaryGetValue(info, cfKey);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
    char *buf = malloc(size);
    if (buf && CFStringGetCString(value, buf, size, kCFStringEncodingUTF8)) {
        printf(",\"%s\":\"", key);
        printEscaped(buf);
        putchar('"');
    }
    free(buf);
}

static void printNumber(const char *key, CFDictionaryRef info, CFStringRef cfKey) {
    CFNumberRef value = CFDictionaryGetValue(info, cfKey);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return;
    double number = 0;
    if (CFNumberGetValue(value, kCFNumberDoubleType, &number)) printf(",\"%s\":%.3f", key, number);
}

static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Track key: shows when something different is now playing, and only then is new
// artwork needed. The daemon sends several notifications per event, and the image
// runs about a hundred kilobytes — no point shipping it every time
static char lastTrackKey[2064];
// The daemon doesn't hand over artwork right away: the first notification for a new
// track arrives without it, the image follows in a later one. So we send it not "on
// track change" but "until sent for this track" — otherwise artwork only showed up
// after reopening the panel
static int artworkSent;
// How many times we've re-requested the dictionary just for the artwork. The daemon
// doesn't always send a notification once the image finishes loading: without polling,
// the track would stay without artwork until the next event
static _Atomic int artworkPolls;
#define ARTWORK_MAX_POLLS 30
#define ARTWORK_POLL_NS (120 * NSEC_PER_MSEC)

static void trackKey(CFDictionaryRef info, char *out, size_t size) {
    out[0] = 0;
    CFStringRef title = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoTitle"));
    CFStringRef album = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoAlbum"));
    // 1024 per part: at 256, two podcast episodes sharing a long title prefix
    // truncated to the same key and shared one artwork
    char titleBuf[1024] = "", albumBuf[1024] = "";
    if (title && CFGetTypeID(title) == CFStringGetTypeID())
        CFStringGetCString(title, titleBuf, sizeof titleBuf, kCFStringEncodingUTF8);
    if (album && CFGetTypeID(album) == CFStringGetTypeID())
        CFStringGetCString(album, albumBuf, sizeof albumBuf, kCFStringEncodingUTF8);
    snprintf(out, size, "%s|%s", titleBuf, albumBuf);
}

// Artwork goes out as base64 on every track change — the image runs about a hundred
// kilobytes, not enough to justify a separate channel
static int printArtwork(CFDictionaryRef info) {
    CFDataRef data = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkData"));
    if (!data || CFGetTypeID(data) != CFDataGetTypeID()) return 0;
    CFIndex length = CFDataGetLength(data);
    if (length <= 0 || length > 4 * 1024 * 1024) return 0;
    const unsigned char *bytes = CFDataGetBytePtr(data);
    fputs(",\"artwork\":\"", stdout);
    for (CFIndex i = 0; i < length; i += 3) {
        unsigned int chunk = bytes[i] << 16;
        if (i + 1 < length) chunk |= bytes[i + 1] << 8;
        if (i + 2 < length) chunk |= bytes[i + 2];
        putchar(alphabet[(chunk >> 18) & 63]);
        putchar(alphabet[(chunk >> 12) & 63]);
        putchar(i + 1 < length ? alphabet[(chunk >> 6) & 63] : '=');
        putchar(i + 2 < length ? alphabet[chunk & 63] : '=');
    }
    putchar('"');
    return 1;
}

// Keep the "playing" flag separate: the dictionary from the callback only lives for
// the duration of that callback, and touching it from a nested async block means
// touching freed memory (caught this as a segfault on the very first live track)
static _Atomic int lastPlaying;
// The process currently holding Now Playing. Sill watches it terminate via
// NSWorkspace: player closed, state gone stale, and that's visible right away
static _Atomic int lastPID;

static void refreshPlaying(void) {
    if (getPlaying) {
        getPlaying(dispatch_get_global_queue(0, 0), ^(Boolean playing) {
            lastPlaying = playing ? 1 : 0;
        });
    }
    if (getPID) {
        getPID(dispatch_get_global_queue(0, 0), ^(int pid) { lastPID = pid; });
    }
}

static void emit(void);

static void emit(void) {
    if (!getInfo) return;
    refreshPlaying();
    getInfo(dispatch_get_global_queue(0, 0), ^(CFDictionaryRef info) {
        {
            pthread_mutex_lock(&writeLock);
            int empty = !info || CFDictionaryGetCount(info) == 0;
            if (empty) {
                // Player is gone — the next track should arrive with its own artwork
                lastTrackKey[0] = 0;
                artworkSent = 0;
                artworkPolls = 0;
                printf("{\"playing\":false,\"empty\":true}\n");
            } else {
                // Playback rate is more accurate than the flag: 0 means paused, whatever the daemon thinks
                CFNumberRef rateValue = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                double rate = -1;
                if (rateValue && CFGetTypeID(rateValue) == CFNumberGetTypeID()) {
                    CFNumberGetValue(rateValue, kCFNumberDoubleType, &rate);
                }
                Boolean playing = rate >= 0 ? rate > 0 : lastPlaying != 0;
                char key[2064];
                trackKey(info, key, sizeof key);
                Boolean sameTrack = strcmp(key, lastTrackKey) == 0;
                if (!sameTrack) {
                    strncpy(lastTrackKey, key, sizeof lastTrackKey - 1);
                    artworkSent = 0;
                    artworkPolls = 0;
                }
                printf("{\"playing\":%s", playing ? "true" : "false");
                printString("title", info, CFSTR("kMRMediaRemoteNowPlayingInfoTitle"));
                printString("artist", info, CFSTR("kMRMediaRemoteNowPlayingInfoArtist"));
                printString("album", info, CFSTR("kMRMediaRemoteNowPlayingInfoAlbum"));
                printNumber("duration", info, CFSTR("kMRMediaRemoteNowPlayingInfoDuration"));
                printNumber("elapsed", info, CFSTR("kMRMediaRemoteNowPlayingInfoElapsedTime"));
                printNumber("rate", info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                // The moment elapsed refers to. Without it, position is computed from
                // when the message was delivered and lags: the player sends the
                // track's elapsed time, but the notification arrives a minute later
                CFDateRef stamp = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoTimestamp"));
                if (stamp && CFGetTypeID(stamp) == CFDateGetTypeID()) {
                    printf(",\"timestamp\":%.3f", CFDateGetAbsoluteTime(stamp) + kCFAbsoluteTimeIntervalSince1970);
                }
                if (lastPID > 0) printf(",\"pid\":%d", (int)lastPID);
                if (!artworkSent && printArtwork(info)) artworkSent = 1;
                printf("}\n");
            }
            fflush(stdout);
            pthread_mutex_unlock(&writeLock);

            // No artwork yet — check back again in a moment. That way the tile gets
            // the image as soon as it appears, instead of on a wait timeout
            if (!empty && !artworkSent && artworkPolls < ARTWORK_MAX_POLLS) {
                artworkPolls++;
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, ARTWORK_POLL_NS),
                    dispatch_get_global_queue(0, 0), ^{ emit(); });
            }
        }
    });
}

static void changed(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                    const void *object, CFDictionaryRef userInfo) {
    emit();
}

static void *listenStdin(void *unused) {
    char line[64];
    while (fgets(line, sizeof line, stdin)) {
        if (!sendCommand) continue;
        // Seeking isn't a command, it's setting a position: "seek 83.5"
        if (strncmp(line, "seek ", 5) == 0) {
            if (setElapsed) setElapsed(atof(line + 5));
            continue;
        }
        // Ask for the state again. A notification that the player closed doesn't
        // always arrive: without re-asking, the tile keeps showing a track that's gone
        if (strncmp(line, "refresh", 7) == 0) {
            emit();
            continue;
        }
        uint32_t command;
        if (strncmp(line, "toggle", 6) == 0) command = CMD_TOGGLE;
        else if (strncmp(line, "play", 4) == 0) command = CMD_PLAY;
        else if (strncmp(line, "pause", 5) == 0) command = CMD_PAUSE;
        else if (strncmp(line, "next", 4) == 0) command = CMD_NEXT;
        else if (strncmp(line, "prev", 4) == 0) command = CMD_PREV;
        else continue;
        sendCommand(command, NULL);
    }
    // stdin closed — Sill is gone, nothing left for the helper to do
    exit(0);
}

static void *start(void *unused) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!handle) {
        printf("{\"error\":\"MediaRemote failed to open\"}\n");
        fflush(stdout);
        return NULL;
    }
    getInfo = (GetInfoFn)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (GetPlayingFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCommand = (SendCommandFn)dlsym(handle, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(handle, "MRMediaRemoteSetElapsedTime");
    getPID = (GetPIDFn)dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
    RegisterFn registerNotifications =
        (RegisterFn)dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPlaying || !registerNotifications) {
        printf("{\"error\":\"missing MediaRemote symbols\"}\n");
        fflush(stdout);
        return NULL;
    }

    registerNotifications(dispatch_get_global_queue(0, 0));
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    CFNotificationCenterAddObserver(center, NULL, changed,
        CFSTR("kMRMediaRemoteNowPlayingInfoDidChangeNotification"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, changed,
        CFSTR("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    // The source itself changed — player closed or another one launched
    CFNotificationCenterAddObserver(center, NULL, changed,
        CFSTR("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    // Playback state: stopped, interrupted, finished. Verified via dlsym — these
    // constants exist in the framework, but we weren't subscribed to them
    CFNotificationCenterAddObserver(center, NULL, changed,
        CFSTR("kMRMediaRemoteNowPlayingApplicationPlaybackStateDidChangeNotification"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, changed,
        CFSTR("kMRMediaRemoteNowPlayingApplicationClientStateDidChange"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, changed,
        CFSTR("kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    pthread_t reader;
    pthread_create(&reader, NULL, listenStdin, NULL);
    pthread_detach(reader);

    emit();
    CFRunLoopRun();
    return NULL;
}

__attribute__((constructor)) static void loaded(void) {
    pthread_t thread;
    pthread_create(&thread, NULL, start, NULL);
    pthread_detach(thread);
}
