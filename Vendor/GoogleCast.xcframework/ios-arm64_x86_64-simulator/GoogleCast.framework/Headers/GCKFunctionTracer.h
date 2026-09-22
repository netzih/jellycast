#import <Foundation/Foundation.h>

/**
 * A utility class for tracing function, method, and block entry and exit for debugging.
 */
@interface GCKFunctionTracer : NSObject

/** Spaces per indent in the output */
@property(class) NSUInteger spacesPerIndent;

/** Whether or not to output only summary messages */
@property(class, readonly, getter=isSummaryMessagesOnly) BOOL summaryMessagesOnly;

/** Dictionary to save the block indent level so that when we exit the block we can restore the indent level */
@property(class, readonly) NSMutableDictionary *blockSaveIndentLevel;

/** Saved date formatter so that we don't have to create one each time */
@property(class, readonly) NSDateFormatter *dateFormatter;

/** Saved date formatter so that we don't have to create one each time */
@property(class, readonly) NSDateFormatter *fullDateFormatter;

/** Call when entering a function */
+ (void)enterFunction:(const char *)functionName;
/** Call when entering a function, and print parameters */
+ (void)enterFunction:(const char *)functionName withParams:(NSString *)format, ...;
/** Handle indent, or just log a summary, depending on the value of summaryMessagesOnly */
+ (void)enterFunctionSummary:(const char *)functionName withParams:(NSString *)format, ...;

/** Call when exiting a function */
+ (void)exitFunction:(const char *)functionName;
/** Call when exiting a function, and print parameters */
+ (void)exitFunction:(const char *)functionName withParams:(NSString *)format, ...;
/** Handle indent, or just log a summary, depending on the value of summaryMessagesOnly */
+ (void)exitFunctionSummary:(const char *)functionName withParams:(NSString *)format, ...;

/** Call when entering a block */
+ (void)enterBlock:(NSString *)blockName inFile:(const char *)fileName atLineNumber:(int)lineNumber;
/** Call when entering a block, and print parameters */
+ (void)enterBlock:(NSString *)blockName inFile:(const char *)fileName atLineNumber:(int)lineNumber withParams:(NSString *)format, ...;

/** Call when exiting a block */
+ (void)exitBlock:(NSString *)blockName inFile:(const char *)fileName;
/** Call when exiting a block, and print parameters */
+ (void)exitBlock:(NSString *)blockName inFile:(const char *)fileName withParams:(NSString *)format, ...;

/** Log a message at the current indent level */
+ (void)logMessageInFile:(const char *)fileName atLineNumber:(int)lineNumber withParams:(NSString *)format, ...;
/** Log a one-line summary without indent */
+ (void)logSummaryInFunction:(const char *)functionName withParams:(NSString *)format, ...;
/** Log text as a message wit indent, or as a one-line summart without indent, depending on the
 * value of summaryMessagesOnly */
+ (void)logMessageOrSummaryInFile:(const char *)fileName
                     atLineNumber:(int)lineNumber
                         function:(const char *)functionName
                       withParams:(NSString *)format, ...;

@end

/* Private properties and methods */
@interface GCKFunctionTracer ()

@property(class) NSUInteger indentLevel;

+ (NSString *)indentString;

@end

#define GCK_BOOL_TO_YES_NO_STRING(BOOLVAL) (BOOLVAL ? @"YES" : @"NO")
#define GCK_NIL_STRING(OBJ) ((OBJ) == nil ? (@"is nil") : (@"is not nil"))
#define GCK_STRING_OR_NIL(OBJ) ((OBJ) == nil ? (@"is nil") : (OBJ))
#define __GCK_FILENAME__ (__builtin_strrchr("/" __FILE__, '/') + 1)

#define GCKEnterFunction [GCKFunctionTracer enterFunction:__FUNCTION__]
#define GCKEnterFunctionWithParams(...) [GCKFunctionTracer enterFunction:__FUNCTION__ withParams:__VA_ARGS__]
#define GCKEnterFunctionSummary(...) \
  [GCKFunctionTracer enterFunctionSummary:__FUNCTION__ withParams:__VA_ARGS__]

#define GCKExitFunction [GCKFunctionTracer exitFunction:__FUNCTION__]
#define GCKExitFunctionWithParams(...) [GCKFunctionTracer exitFunction:__FUNCTION__ withParams:__VA_ARGS__]
#define GCKExitFunctionSummary(...) \
  [GCKFunctionTracer exitFunctionSummary:__FUNCTION__ withParams:__VA_ARGS__]

#define GCKEnterBlock(NAME) [GCKFunctionTracer enterBlock:NAME inFile:__GCK_FILENAME__ atLineNumber:__LINE__]
#define GCKEnterBlockWithParams(NAME, ...)       \
  [GCKFunctionTracer enterBlock:NAME             \
                         inFile:__GCK_FILENAME__ \
                   atLineNumber:__LINE__         \
                     withParams:__VA_ARGS__]

#define GCKExitBlock(NAME) [GCKFunctionTracer exitBlock:NAME inFile:__GCK_FILENAME__]
#define GCKExitBlockWithParams(NAME, ...) \
  [GCKFunctionTracer exitBlock:NAME inFile:__GCK_FILENAME__ withParams:__VA_ARGS__]

#define GCKLogMessage(...) \
  [GCKFunctionTracer logMessageInFile:__GCK_FILENAME__ atLineNumber:__LINE__ withParams:__VA_ARGS__]
#define GCKLogSummary(...) \
  [GCKFunctionTracer logSummaryInFunction:__FUNCTION__ withParams:__VA_ARGS__]
#define GCKLogMessageOrSummary(...)                             \
  [GCKFunctionTracer logMessageOrSummaryInFile:__GCK_FILENAME__ \
                                  atLineNumber:__LINE__         \
                                      function:__FUNCTION__     \
                                    withParams:__VA_ARGS__]
