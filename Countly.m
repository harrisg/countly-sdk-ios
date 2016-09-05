// Countly.m
//
// This code is provided under the MIT License.
//
// Please visit www.count.ly for more information.

#pragma mark - Countly Core

#import "CountlyCommon.h"

@interface Countly ()
{
    NSTimeInterval unsentSessionLength;
    NSTimer *timer;
    NSTimeInterval lastTime;
    BOOL isSuspended;
}
@end

@implementation Countly

+ (instancetype)sharedInstance
{
    static Countly *s_sharedCountly = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{s_sharedCountly = self.new;});
    return s_sharedCountly;
}

- (instancetype)init
{
    if (self = [super init])
    {
        timer = nil;
        isSuspended = NO;
        unsentSessionLength = 0;

#if (TARGET_OS_IOS  || TARGET_OS_TV)
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(didEnterBackgroundCallBack:)
                                                   name:UIApplicationDidEnterBackgroundNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(willEnterForegroundCallBack:)
                                                   name:UIApplicationWillEnterForegroundNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(willTerminateCallBack:)
                                                   name:UIApplicationWillTerminateNotification
                                                 object:nil];
#elif TARGET_OS_OSX
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(willTerminateCallBack:)
                                                   name:NSApplicationWillTerminateNotification
                                                 object:nil];
#endif
    }

    return self;
}

- (void)setNewDeviceID:(NSString *)deviceID onServer:(BOOL)onServer
{
#if TARGET_OS_IOS
    BOOL isSameIDFA = [deviceID isEqualToString:CLYIDFA] &&
                      [CountlyDeviceInfo.sharedInstance.deviceID isEqualToString:ASIdentifierManager.sharedManager.advertisingIdentifier.UUIDString];

    BOOL isSameIDFV = [deviceID isEqualToString:CLYIDFV] &&
                      [CountlyDeviceInfo.sharedInstance.deviceID isEqualToString:UIDevice.currentDevice.identifierForVendor.UUIDString];

    BOOL isSameOpen = [deviceID isEqualToString:CLYOpenUDID] &&
                      [CountlyDeviceInfo.sharedInstance.deviceID isEqualToString:[Countly_OpenUDID value]];

    if(isSameIDFA || isSameIDFV || isSameOpen)
        return;

#elif TARGET_OS_OSX
    if([deviceID isEqualToString:CLYOpenUDID] &&
       [CountlyDeviceInfo.sharedInstance.deviceID isEqualToString:[Countly_OpenUDID value]])
        return;
#endif

    if([deviceID isEqualToString:CountlyDeviceInfo.sharedInstance.deviceID])
        return;

    if(onServer)
    {
        NSString* oldDeviceID = CountlyDeviceInfo.sharedInstance.deviceID;

        [CountlyDeviceInfo.sharedInstance initializeDeviceID:deviceID];

        [CountlyConnectionManager.sharedInstance sendOldDeviceID:oldDeviceID];
    }
    else
    {
        [Countly.sharedInstance suspend];

        [CountlyDeviceInfo.sharedInstance initializeDeviceID:deviceID];

        [Countly.sharedInstance resume];

        [CountlyPersistency.sharedInstance clearAllTimedEvents];
    }
}

- (void)setCustomHeaderFieldValue:(NSString *)customHeaderFieldValue
{
    CountlyConnectionManager.sharedInstance.customHeaderFieldValue = customHeaderFieldValue;
    [CountlyConnectionManager.sharedInstance tick];
}

#pragma mark ---

- (void)startWithConfig:(CountlyConfig *)config
{
    NSAssert(config.appKey && ![config.appKey isEqualToString:@"YOUR_APP_KEY"],@"[CountlyAssert] App key in Countly configuration is not set!");
    NSAssert(config.host && ![config.host isEqualToString:@"https://YOUR_COUNTLY_SERVER"],@"[CountlyAssert] Host in Countly configuration is not set!");

    if(!CountlyDeviceInfo.sharedInstance.deviceID || config.forceDeviceIDInitialization)
    {
        [CountlyDeviceInfo.sharedInstance initializeDeviceID:config.deviceID];
    }

    CountlyPersistency.sharedInstance.eventSendThreshold = config.eventSendThreshold;
    CountlyPersistency.sharedInstance.storedRequestsLimit = config.storedRequestsLimit;
    CountlyConnectionManager.sharedInstance.updateSessionPeriod = config.updateSessionPeriod;
    CountlyConnectionManager.sharedInstance.ISOCountryCode = config.ISOCountryCode;
    CountlyConnectionManager.sharedInstance.city = config.city;
    CountlyConnectionManager.sharedInstance.location = CLLocationCoordinate2DIsValid(config.location)?[NSString stringWithFormat:@"%f,%f", config.location.latitude, config.location.longitude]:nil;
    CountlyConnectionManager.sharedInstance.pinnedCertificates = config.pinnedCertificates;
    CountlyConnectionManager.sharedInstance.customHeaderFieldName = config.customHeaderFieldName;
    CountlyConnectionManager.sharedInstance.customHeaderFieldValue = config.customHeaderFieldValue;

#if TARGET_OS_IOS
    CountlyStarRating.sharedInstance.message = config.starRatingMessage;
    CountlyStarRating.sharedInstance.dismissButtonTitle = config.starRatingDismissButtonTitle;
    CountlyStarRating.sharedInstance.sessionCount = config.starRatingSessionCount;
    CountlyStarRating.sharedInstance.disableAskingForEachAppVersion = config.starRatingDisableAskingForEachAppVersion;
    
    [CountlyStarRating.sharedInstance checkForAutoAsk];

    [CountlyCommon.sharedInstance transferParentDeviceID];

    [self start:config.appKey withHost:config.host];

    if([config.features containsObject:CLYPushNotifications])
    {
        CountlyPushNotifications.sharedInstance.isTestDevice = config.isTestDevice;
        CountlyPushNotifications.sharedInstance.shouldNotShowAlert = config.shouldNotShowAlert;
        [CountlyPushNotifications.sharedInstance startPushNotifications];
    }

    if([config.features containsObject:CLYCrashReporting])
    {
        CountlyCrashReporter.sharedInstance.crashSegmentation = config.crashSegmentation;
        [CountlyCrashReporter.sharedInstance startCrashReporting];
    }

    if([config.features containsObject:CLYAutoViewTracking])
    {
        [CountlyViewTracking.sharedInstance startAutoViewTracking];
    }
#else
    [self start:config.appKey withHost:config.host];
#endif

    if([config.features containsObject:CLYAPM])
        [CountlyAPM.sharedInstance startAPM];

#if (TARGET_OS_WATCH)
    [CountlyCommon.sharedInstance activateWatchConnectivity];
#endif
}

- (void)start:(NSString *)appKey withHost:(NSString *)appHost
{
    timer = [NSTimer scheduledTimerWithTimeInterval:CountlyConnectionManager.sharedInstance.updateSessionPeriod target:self selector:@selector(onTimer:) userInfo:nil repeats:YES];
    lastTime = NSDate.date.timeIntervalSince1970;
    CountlyConnectionManager.sharedInstance.appKey = appKey;
    CountlyConnectionManager.sharedInstance.appHost = appHost;
    [CountlyConnectionManager.sharedInstance beginSession];
}

#pragma mark ---

- (void)onTimer:(NSTimer *)timer
{
    if (isSuspended == YES)
        return;

    NSTimeInterval currTime = NSDate.date.timeIntervalSince1970;
    unsentSessionLength += currTime - lastTime;
    lastTime = currTime;

    int duration = unsentSessionLength;
    [CountlyConnectionManager.sharedInstance updateSessionWithDuration:duration];
    unsentSessionLength -= duration;

    [CountlyConnectionManager.sharedInstance sendEvents];
}

- (void)suspend
{
    COUNTLY_LOG(@"Suspending...");

    isSuspended = YES;

    [CountlyConnectionManager.sharedInstance sendEvents];

    NSTimeInterval currTime = NSDate.date.timeIntervalSince1970;
    unsentSessionLength += currTime - lastTime;

    int duration = unsentSessionLength;
    [CountlyConnectionManager.sharedInstance endSessionWithDuration:duration];
    unsentSessionLength -= duration;

    [CountlyPersistency.sharedInstance saveToFileSync];
}

- (void)resume
{
#if TARGET_OS_WATCH
    //NOTE: skip first time to prevent double begin session because of applicationDidBecomeActive call on app lunch
    static BOOL isFirstCall = YES;

    if(isFirstCall)
    {
        isFirstCall = NO;
        return;
    }
#endif

    lastTime = NSDate.date.timeIntervalSince1970;

    [CountlyConnectionManager.sharedInstance beginSession];

    isSuspended = NO;
}

#pragma mark ---

- (void)didEnterBackgroundCallBack:(NSNotification *)notification
{
    COUNTLY_LOG(@"App did enter background.");
    [self suspend];
}

- (void)willEnterForegroundCallBack:(NSNotification *)notification
{
    COUNTLY_LOG(@"App will enter foreground.");
    [self resume];
}

- (void)willTerminateCallBack:(NSNotification *)notification
{
    COUNTLY_LOG(@"App will terminate.");

    [CountlyViewTracking.sharedInstance endView];

    [self suspend];
}

- (void)dealloc
{
#if TARGET_OS_IOS
    [NSNotificationCenter.defaultCenter removeObserver:self];
#endif

    if (timer)
    {
        [timer invalidate];
        timer = nil;
    }
}



#pragma mark - Countly CustomEvents
- (void)recordEvent:(NSString *)key
{
    [self recordEvent:key segmentation:nil count:1 sum:0 duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key count:(NSUInteger)count
{
    [self recordEvent:key segmentation:nil count:count sum:0 duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key sum:(double)sum
{
    [self recordEvent:key segmentation:nil count:1 sum:sum duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key duration:(NSTimeInterval)duration
{
    [self recordEvent:key segmentation:nil count:1 sum:0 duration:duration timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key count:(NSUInteger)count sum:(double)sum
{
    [self recordEvent:key segmentation:nil count:count sum:sum duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation
{
    [self recordEvent:key segmentation:segmentation count:1 sum:0 duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count
{
    [self recordEvent:key segmentation:segmentation count:count sum:0 duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(double)sum
{
    [self recordEvent:key segmentation:segmentation count:count sum:sum duration:0 timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(double)sum duration:(NSTimeInterval)duration
{
    [self recordEvent:key segmentation:segmentation count:count sum:sum duration:duration timestamp:NSDate.date.timeIntervalSince1970];
}

- (void)recordEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(double)sum duration:(NSTimeInterval)duration timestamp:(NSTimeInterval)timestamp
{
    CountlyEvent *event = CountlyEvent.new;
    event.key = key;
    event.segmentation = segmentation;
    event.count = MAX(count, 1);
    event.sum = sum;
    event.timestamp = timestamp;
    event.hourOfDay = [CountlyCommon.sharedInstance hourOfDay];
    event.dayOfWeek = [CountlyCommon.sharedInstance dayOfWeek];
    event.duration = duration;

    [CountlyPersistency.sharedInstance recordEvent:event];
}

#pragma mark ---

- (void)startEvent:(NSString *)key
{
    CountlyEvent *event = CountlyEvent.new;
    event.key = key;
    event.timestamp = NSDate.date.timeIntervalSince1970;
    event.hourOfDay = [CountlyCommon.sharedInstance hourOfDay];
    event.dayOfWeek = [CountlyCommon.sharedInstance dayOfWeek];

    [CountlyPersistency.sharedInstance recordTimedEvent:event];
}

- (void)endEvent:(NSString *)key
{
    [self endEvent:key segmentation:nil count:1 sum:0];
}

- (void)endEvent:(NSString *)key segmentation:(NSDictionary *)segmentation count:(NSUInteger)count sum:(double)sum
{
    CountlyEvent *event = [CountlyPersistency.sharedInstance timedEventForKey:key];

    if(!event)
    {
        COUNTLY_LOG(@"Event with key '%@' not started before!", key);
        return;
    }

    event.segmentation = segmentation;
    event.count = MAX(count, 1);;
    event.sum = sum;
    event.duration = NSDate.date.timeIntervalSince1970 - event.timestamp;

    [CountlyPersistency.sharedInstance recordEvent:event];
}



#pragma mark - Countly PushNotifications
#if TARGET_OS_IOS
- (void)recordLocation:(CLLocationCoordinate2D)coordinate
{
    [CountlyConnectionManager.sharedInstance sendLocation:coordinate];
}
#endif



#pragma mark - Countly CrashReporting

#if TARGET_OS_IOS
- (void)recordHandledException:(NSException *)exception
{
    [CountlyCrashReporter.sharedInstance recordHandledException:exception];
}

- (void)crashLog:(NSString *)format, ...
{
    va_list args;
    va_start(args, format);
    [CountlyCrashReporter.sharedInstance logWithFormat:format andArguments:args];
    va_end(args);
}
#endif



#pragma mark - Countly APM

- (void)addExceptionForAPM:(NSString *)exceptionURL
{
    [CountlyAPM.sharedInstance addExceptionForAPM:exceptionURL];
}

- (void)removeExceptionForAPM:(NSString *)exceptionURL
{
    [CountlyAPM.sharedInstance removeExceptionForAPM:exceptionURL];
}



#pragma mark - Countly AutoViewTracking

- (void)reportView:(NSString *)viewName
{
    [CountlyViewTracking.sharedInstance reportView:viewName];
}

#if TARGET_OS_IOS
- (void)addExceptionForAutoViewTracking:(Class)exceptionViewControllerSubclass
{
    [CountlyViewTracking.sharedInstance addExceptionForAutoViewTracking:exceptionViewControllerSubclass];
}

- (void)removeExceptionForAutoViewTracking:(Class)exceptionViewControllerSubclass
{
    [CountlyViewTracking.sharedInstance removeExceptionForAutoViewTracking:exceptionViewControllerSubclass];
}

- (void)setIsAutoViewTrackingEnabled:(BOOL)isAutoViewTrackingEnabled
{
    CountlyViewTracking.sharedInstance.isAutoViewTrackingEnabled = isAutoViewTrackingEnabled;
}

- (BOOL)isAutoViewTrackingEnabled
{
    return CountlyViewTracking.sharedInstance.isAutoViewTrackingEnabled;
}
#endif



#pragma mark - Countly UserDetails

+ (CountlyUserDetails *)user
{
    return CountlyUserDetails.sharedInstance;
}



#pragma mark - Countly StarRating
#if TARGET_OS_IOS

- (void)askForStarRating:(void(^)(NSInteger rating))completion
{
    [CountlyStarRating.sharedInstance showDialog:completion];
}
#endif

@end