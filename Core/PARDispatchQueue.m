//  PARStore
//  Author: Charles Parnot
//  Licensed under the terms of the BSD License, as specified in the file 'LICENSE-BSD.txt' included with this distribution


#import "PARDispatchQueue.h"
#import <mach/mach_time.h>

// keys and context used for the `dispatch_xxx_specific` APIs and to keep track of the stack of queues
static int PARQueueStackKey  = 1;
static int PARIsCurrentKey   = 1;


// private properties
@interface PARDispatchQueue()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (copy) NSString *_label;
@property (strong) NSMutableDictionary *timers;
@property (nonatomic) PARDeadlockBehavior _deadlockBehavior;
@property BOOL concurrent;
@property NSUInteger timerCountPrivate;
@end


@implementation PARDispatchQueue

+ (PARDispatchQueue *)dispatchQueueWithGCDQueue:(dispatch_queue_t)gcdQueue behavior:(PARDeadlockBehavior)behavior
{
    PARDispatchQueue *newQueue = [[self alloc] init];
    newQueue.queue = gcdQueue;
    newQueue._deadlockBehavior = behavior;
    dispatch_queue_set_specific(gcdQueue, &PARIsCurrentKey, (__bridge void *)(newQueue), NULL);
    return newQueue;
}

+ (PARDispatchQueue *)dispatchQueueWithLabel:(NSString *)label behavior:(PARDeadlockBehavior)behavior
{
    PARDispatchQueue *newQueue = [self dispatchQueueWithGCDQueue:dispatch_queue_create([label UTF8String], DISPATCH_QUEUE_SERIAL) behavior:behavior];
    newQueue._label = label ?: @"PARDispatchQueue";
    return newQueue;
}

+ (PARDispatchQueue *)dispatchQueueWithLabel:(NSString *)label
{
    return [self dispatchQueueWithLabel:label behavior:PARDeadlockBehaviorExecute];
}

+ (NSString *)labelByPrependingBundleIdentifierToString:(NSString *)suffix
{
    return [[[NSBundle mainBundle] bundleIdentifier] stringByAppendingFormat:@".%@", suffix];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@:%p>[%@]", NSStringFromClass([self class]), self, self.label];
}


#pragma mark - Special Queues

// using singletons for these queues so that `isCurrentQueue` works as intended

+ (PARDispatchQueue *)globalDispatchQueue
{
    static dispatch_once_t pred = 0;
    static PARDispatchQueue *globalDispatchQueue = nil;
    dispatch_once(&pred, ^
      {
          globalDispatchQueue = [self dispatchQueueWithGCDQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) behavior:PARDeadlockBehaviorBlock];
          const char *label = dispatch_queue_get_label(globalDispatchQueue.queue);
          if (label == NULL)
              label = "unlabeled";
          globalDispatchQueue._label = [NSString stringWithUTF8String:label];
          globalDispatchQueue.concurrent = YES;
      });
    return globalDispatchQueue;
}

// DISPATCH_QUEUE_PRIORITY_HIGH
// DISPATCH_QUEUE_PRIORITY_LOW

static PARDispatchQueue *PARMainDispatchQueue = nil;
+ (PARDispatchQueue *)mainDispatchQueue
{
    static dispatch_once_t pred = 0;
    dispatch_once(&pred, ^
      {
          PARMainDispatchQueue = [self dispatchQueueWithGCDQueue:dispatch_get_main_queue() behavior:PARDeadlockBehaviorExecute];
          const char *label = dispatch_queue_get_label(PARMainDispatchQueue.queue);
          if (label == NULL)
              label = "unlabeled";
          PARMainDispatchQueue._label = [NSString stringWithUTF8String:label];
      });
    return PARMainDispatchQueue;
}


static PARDispatchQueue *PARSharedConcurrentQueue = nil;
+ (PARDispatchQueue *)sharedConcurrentQueue
{
    static dispatch_once_t pred = 0;
    dispatch_once(&pred, ^
      {
          NSString *label = @"PARSharedConcurrentQueue";
          PARSharedConcurrentQueue = [self dispatchQueueWithGCDQueue:dispatch_queue_create([label UTF8String], DISPATCH_QUEUE_CONCURRENT) behavior:PARDeadlockBehaviorBlock];
          PARSharedConcurrentQueue._label = label;
          PARSharedConcurrentQueue.concurrent = YES;
      });
    return PARSharedConcurrentQueue;
}


#pragma mark - Accessors

- (NSString *)label
{
    return self._label;
}

- (PARDeadlockBehavior)deadlockBehavior
{
    return self._deadlockBehavior;
}


#pragma mark - Dispatch

- (void)dispatchSynchronously:(PARDispatchBlock)block
{
    PARDeadlockBehavior behavior = self.deadlockBehavior;

    // dispatch_sync will only deadlock if that's the desired behavior
    if (behavior == PARDeadlockBehaviorBlock || ![self isInCurrentQueueStack])
    {
        // prepare the new stack before we are inside the queue, so it can be set on the queue
        NSMutableArray *queueStack = (__bridge NSMutableArray *)(dispatch_get_specific(&PARQueueStackKey));
        BOOL newStack = NO;
        if (!queueStack)
        {
            queueStack = [NSMutableArray array];
            newStack = YES;
        }
        
        // dispatch_queue_set_specific should be serialized within the queue, so it's consistent from one block execution to the next
        dispatch_sync(self.queue, ^
          {
              if (!self.concurrent)
                  [queueStack addObject:self];
              dispatch_queue_set_specific(self.queue, &PARQueueStackKey, (__bridge void *)queueStack, NULL);
              block();
              NSAssert([queueStack lastObject] == self, @"The queue stack set after execution of a block should have the parent queue as the last object: %@\n Iinstead, it has the following stack: %@", self, queueStack);
              if (!self.concurrent)
                  [queueStack removeLastObject];
              NSAssert(!newStack || [queueStack count] == 0, @"The queue stack should be empty after execution of a block dispatched synchronously that was started without a queue stack yet: %@", self);
              dispatch_queue_set_specific(self.queue, &PARQueueStackKey, NULL, NULL);
          });
    }

    else
    {
        if (behavior == PARDeadlockBehaviorExecute)
            block();
        else if (behavior == PARDeadlockBehaviorLog)
            NSLog(@"Synchronous dispatch can not be executed on the queue with label '%@' because it is already part of the current dispatch queue hierarchy", self.label);
        else if (behavior == PARDeadlockBehaviorAssert)
            NSAssert(0, @"Synchronous dispatch can not be executed on the queue with label '%@' because it is already part of the current dispatch queue hierarchy", self.label);
    }
}

// asynchronous dispatch can only start a new queue stack
- (void)dispatchAsynchronously:(PARDispatchBlock)block
{
    if (self.concurrent)
        dispatch_async(self.queue, block);
    else
        dispatch_async(self.queue, ^
           {
               NSAssert(dispatch_get_specific(&PARQueueStackKey) == NULL, @"There should be no queue stack set before execution of a block dispatched asynchronously with queue: %@", self);
               NSMutableArray *queueStack = [NSMutableArray arrayWithObject:self];
               dispatch_queue_set_specific(self.queue, &PARQueueStackKey, (__bridge void *)queueStack, NULL);
               block();
               NSAssert([queueStack lastObject] == self, @"The queue stack set after execution of a block should have the parent queue as the last object: %@\n Iinstead, it has the following stack: %@", self, queueStack);
               [queueStack removeLastObject];
               NSAssert([queueStack count] == 0, @"The queue stack should be empty after execution of a block dispatched asynchronously with queue: %@", self);
               dispatch_queue_set_specific(self.queue, &PARQueueStackKey, NULL, NULL);
           });
}

- (void)dispatchBarrierSynchronously:(PARDispatchBlock)block
{
    dispatch_barrier_sync(self.queue, block);
}

- (void)dispatchBarrierAsynchronously:(PARDispatchBlock)block
{
    dispatch_barrier_async(self.queue, block);
}

// see: https://devforums.apple.com/message/710745 for why using dispatch_get_current_queue() is not a good way to check the current queue, and why it's deprecated in iOS 6.0
- (BOOL)isCurrentQueue
{
    return (dispatch_get_specific(&PARIsCurrentKey) == (__bridge void *)(self));
}

- (BOOL)isInCurrentQueueStack
{
    // main queue is easier and safer to assert
    if (self == PARMainDispatchQueue)
        return [NSThread isMainThread];
    
    NSArray *queueStack = (__bridge NSArray *)(dispatch_get_specific(&PARQueueStackKey));
    return [queueStack containsObject:self];
}

#pragma mark - Timers

- (NSTimeInterval)_now
{
    static mach_timebase_info_data_t info;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{ mach_timebase_info(&info); });
    
    NSTimeInterval t = mach_absolute_time();
    t *= info.numer;
    t /= info.denom;
    return t / NSEC_PER_SEC;
}

- (BOOL)_scheduleTimerWithName:(NSString *)name referenceTime:(NSTimeInterval)time timeInterval:(NSTimeInterval)delay behavior:(PARTimerBehavior)behavior block:(PARDispatchBlock)block
{
    if (!self.timers)
        self.timers = [NSMutableDictionary dictionary];
    
    NSDictionary *timerInfo = self.timers[name];
    NSNumber *dateValue = timerInfo[@"DateValue"];
    NSValue *timerValue = timerInfo[@"TimerValue"];
    if (timerValue == nil && behavior != PARTimerBehaviorThrottle)
        dateValue = nil;
    
    // get the underlying dispatch timer
    dispatch_source_t dispatchTimer = NULL;
    if (timerValue)
        dispatchTimer = (dispatch_source_t)[timerValue pointerValue];
    else
        dispatchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    if (!dispatchTimer)
        return NO;
    
    // adjust firing time as needed:
    NSTimeInterval now = [self _now];
    NSTimeInterval newFireTime;

    // - wait behavior: fire now or last date + delay
    if (behavior == PARTimerBehaviorThrottle)
    {
        // timer already set: already throttled
        if (timerValue != nil)
        {
            newFireTime = dateValue.doubleValue;
        }
        
        else
        {
            // never fired or already past the throttle delay --> fire now
            newFireTime = dateValue.doubleValue + delay;
            if (dateValue == nil || newFireTime <= now)
            {
                newFireTime = now;
                // it seems we should not use a time interval of zero, to avoid warning: "DEPRECATED USE in libdispatch client: Setting timer interval to 0 requests a 1ns timer, did you mean FOREVER (a one-shot timer)?"
                dispatch_source_set_timer(dispatchTimer, dispatch_time(DISPATCH_TIME_NOW, 1), 0, 0);
            }
            
            // fired before --> apply throttle
            else
            {
                NSTimeInterval adjustedDelay = newFireTime - now;
                dispatch_source_set_timer(dispatchTimer, dispatch_time(DISPATCH_TIME_NOW, adjustedDelay * NSEC_PER_SEC), 0, 0);
            }
        }
    }
    
    // - coalesce behavior: only take into account earlier-than-currently-set firing
    // - delay behavior: firing always at now + delay
    else
    {
        NSTimeInterval adjustedDelay = delay - (now - time);
        if (adjustedDelay < 0.0)
            adjustedDelay = 0.0;
        NSTimeInterval fireTime = [dateValue doubleValue];
        newFireTime = now + adjustedDelay;
        if (dateValue == nil || behavior == PARTimerBehaviorDelay || newFireTime < fireTime)
        {
            dispatch_source_set_timer(dispatchTimer, dispatch_time(DISPATCH_TIME_NOW, adjustedDelay * NSEC_PER_SEC), 0, 0);
        }
    }
    
    // set the new event handler
    if (self.concurrent)
        dispatch_source_set_event_handler(dispatchTimer, ^
          {
              block();
              [self _cancelTimerWithName:name];
          });
    else
        dispatch_source_set_event_handler(dispatchTimer, ^
          {
              NSAssert(dispatch_get_specific(&PARQueueStackKey) == NULL, @"There should be no queue stack set before execution of a block dispatched asynchronously by timer '%@' with queue: %@", name, self);
              NSMutableArray *queueStack = [NSMutableArray arrayWithObject:self];
              dispatch_queue_set_specific(self.queue, &PARQueueStackKey, (__bridge void *)queueStack, NULL);
              block();
              NSAssert([queueStack lastObject] == self, @"The queue stack set after execution of a block should have the parent queue as the last object: %@\n Iinstead, it has the following stack: %@", self, queueStack);
              [queueStack removeLastObject];
              NSAssert([queueStack count] == 0, @"The queue stack should be empty after execution of a block dispatched asynchronously by timer '%@' with queue: %@", name, self);
              dispatch_queue_set_specific(self.queue, &PARQueueStackKey, NULL, NULL);
              [self _cancelTimerWithName:name];
          });
    
    // new timers need to be retained and activated
    if (!timerValue)
    {
        timerValue = [NSValue valueWithPointer:(__bridge_retained const void *)dispatchTimer];
        dispatch_resume(dispatchTimer);
    }
    
    // update timer info
    self.timers[name] = @{ @"DateValue" : @(newFireTime), @"TimerValue" : timerValue };
    [self _updateTimerCountPrivate];
    
    return YES;
}

- (void)_cancelTimerWithName:(NSString *)name
{
    NSDictionary *timerInfo = self.timers[name];
    NSValue *timerValue = timerInfo[@"TimerValue"];
    if (!timerValue)
        return;
    NSNumber *dateValue = timerInfo[@"DateValue"];
    
    // because we are using NSValue, we need to do the memory management ourselves
    dispatch_source_t dispatchTimer = (__bridge_transfer dispatch_source_t)[timerValue pointerValue];
    dispatch_source_cancel(dispatchTimer);
    // **from here on, the timerValue pointer can't be used anymore!**
    
    // for 'throttle' behavior, we need to keep track of last firing date, but still remove the timer value itself
    self.timers[name] = @{ @"DateValue" : dateValue };
    [self _updateTimerCountPrivate];
}

- (void)_updateTimerCountPrivate
{
    NSUInteger count = 0;
    for (NSDictionary *timerDescription in self.timers.allValues)
    {
        if (timerDescription[@"TimerValue"] != nil)
        {
            count ++;
        }
    }
    self.timerCountPrivate = count;
}

- (void)scheduleTimerWithName:(NSString *)name timeInterval:(NSTimeInterval)delay behavior:(PARTimerBehavior)behavior block:(PARDispatchBlock)block
{
    NSTimeInterval time = [self _now];
    [self dispatchAsynchronously:^
    {
        [self _scheduleTimerWithName:name referenceTime:time timeInterval:delay behavior:behavior block:block];
    }];
}

- (void)cancelTimerWithName:(NSString *)name
{
    [self dispatchAsynchronously:^
    {
        [self _cancelTimerWithName:name];
    }];
}

- (void)cancelAllTimers
{
    [self dispatchAsynchronously:^
    {
        for (NSString *name in self.timers.allKeys)
            [self _cancelTimerWithName:name];
        self.timerCountPrivate = self.timers.count;
    }];
}

// the whole point of having a property timerCountPrivate` separate from the `timers` dictionary, is to not require a synchronous call into the queue, while still having an atomic accessor
// the returned value may well be outdated by the time it is used (except if used **inside** the queue), but this should be obvious to the client
- (NSUInteger)timerCount
{
    return _timerCountPrivate;
}

@end


@interface PARBlockOperation ()
@property (nonatomic, strong) PARDispatchQueue *queue;
@property BOOL done;
@end

@implementation PARBlockOperation

+ (PARBlockOperation *)dispatchedOperationWithQueue:(PARDispatchQueue *)queue block:(PARDispatchBlock)block;
{
    PARBlockOperation *operation = [[PARBlockOperation alloc] init];
    
    // use a private queue to guarantee FIFO order: the block will be executed before the one used in the `waitUntilFinished` method
    operation.queue = [PARDispatchQueue dispatchQueueWithLabel:[queue.label stringByAppendingString:@".block_operation"]];
    [operation.queue dispatchAsynchronously:^{ operation.done = NO; [queue dispatchSynchronously:block]; operation.done = YES; }];
    
    return operation;
}

- (void)waitUntilFinished
{
    __block BOOL reallyDone = NO;
    [self.queue dispatchSynchronously:^{ reallyDone = self.done; /* noop, just waiting */ }];
    NSAssert(reallyDone, @"BAD");
}


@end

