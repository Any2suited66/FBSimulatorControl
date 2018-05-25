/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBCrashLogInfo.h"

#import <stdio.h>

#import "FBControlCoreGlobalConfiguration.h"
#import "FBDiagnostic.h"
#import "FBConcurrentCollectionOperations.h"
#import "NSPredicate+FBControlCore.h"

@implementation FBCrashLogInfo

#pragma mark Initializers

+ (instancetype)fromCrashLogAtPath:(NSString *)crashPath
{
  if (!crashPath) {
    return nil;
  }
  FILE *file = fopen(crashPath.UTF8String, "r");
  if (!file) {
    return nil;
  }

  NSString *executablePath = nil;
  NSString *identifier = nil;
  NSString *processName = nil;
  NSString *parentProcessName = nil;
  NSDate *date = nil;
  pid_t processIdentifier = -1;
  pid_t parentProcessIdentifier = -1;

  if (![self extractFromFile:file executablePathOut:&executablePath identifierOut:&identifier processNameOut:&processName parentProcessNameOut:&parentProcessName processIdentifierOut:&processIdentifier parentProcessIdentifierOut:&parentProcessIdentifier dateOut:&date]) {
    fclose(file);
    return nil;
  }

  FBCrashLogInfoProcessType processType = [self processTypeForExecutablePath:executablePath];
  fclose(file);

  return [[FBCrashLogInfo alloc]
    initWithCrashPath:crashPath
    executablePath:executablePath
    identifier:identifier
    processName:processName
    processIdentifier:processIdentifier
    parentProcessName:parentProcessName
    parentProcessIdentifier:parentProcessIdentifier
    date:date
    processType:processType];
}

- (instancetype)initWithCrashPath:(NSString *)crashPath executablePath:(NSString *)executablePath identifier:(NSString *)identifier processName:(NSString *)processName processIdentifier:(pid_t)processIdentifer parentProcessName:(NSString *)parentProcessName parentProcessIdentifier:(pid_t)parentProcessIdentifier date:(NSDate *)date processType:(FBCrashLogInfoProcessType)processType
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _crashPath = crashPath;
  _executablePath = executablePath;
  _identifier = identifier;
  _processName = processName;
  _processIdentifier = processIdentifer;
  _parentProcessName = parentProcessName;
  _parentProcessIdentifier = parentProcessIdentifier;
  _date = date;
  _processType = processType;

  return self;
}

#pragma mark Public

- (FBDiagnostic *)toDiagnostic:(FBDiagnosticBuilder *)builder
{
  return [[[builder
    updateShortName:self.crashPath.lastPathComponent]
    updatePath:self.crashPath]
    build];
}

+ (BOOL)isParsableCrashLog:(NSData *)data
{
#if defined(__apple_build_version__)
  if (@available(macOS 10.13, *)) {
    FILE *file = fmemopen((void *)data.bytes, data.length, "r");
    if (!file) {
      return NO;
    }
    BOOL parsable = [self extractFromFile:file executablePathOut:nil identifierOut:nil processNameOut:nil parentProcessNameOut:nil processIdentifierOut:nil parentProcessIdentifierOut:nil dateOut:nil];
    fclose(file);
    return parsable;
  } else {
    return NO;
  }
#else
  return NO;
#endif
}

#pragma mark NSObject

- (NSString *)description
{
  return [NSString stringWithFormat:
    @"Identifier %@ | Executable Path %@ | Process %@ | pid %d | Parent %@ | ppid %d | Date %@ | Path %@",
    self.identifier,
    self.executablePath,
    self.processName,
    self.processIdentifier,
    self.parentProcessName,
    self.parentProcessIdentifier,
    self.date,
    self.crashPath
  ];
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
  // Is immutable
  return self;
}

#pragma mark Bulk Collection

+ (NSArray<FBCrashLogInfo *> *)crashInfoAfterDate:(NSDate *)date
{
  NSString *basePath = self.diagnosticReportsPath;

  return [[FBConcurrentCollectionOperations
    filterMap:[NSFileManager.defaultManager contentsOfDirectoryAtPath:basePath error:nil]
    predicate:[FBCrashLogInfo predicateForFilesWithBasePath:basePath afterDate:date withExtension:@"crash"]
    map:^ FBCrashLogInfo * (NSString *fileName) {
      NSString *path = [basePath stringByAppendingPathComponent:fileName];
      return [FBCrashLogInfo fromCrashLogAtPath:path];
    }]
    filteredArrayUsingPredicate:NSPredicate.notNullPredicate];
}

#pragma mark Predicates

+ (NSPredicate *)predicateForCrashLogsWithProcessID:(pid_t)processID
{
  return [NSPredicate predicateWithBlock:^ BOOL (FBCrashLogInfo *crashLog, id _) {
    return crashLog.processIdentifier == processID;
  }];
}

+ (NSPredicate *)predicateNewerThanDate:(NSDate *)date
{
  return [NSPredicate predicateWithBlock:^ BOOL (FBCrashLogInfo *crashLog, id _) {
    return [crashLog.date compare:date] == NSOrderedAscending;
  }];
}

#pragma mark Helpers

+ (NSString *)diagnosticReportsPath
{
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/DiagnosticReports"];
}

#pragma mark Private

static NSUInteger MaxLineSearch = 20;

+ (BOOL)extractFromFile:(FILE *)file executablePathOut:(NSString **)executablePathOut identifierOut:(NSString **)identifierOut processNameOut:(NSString **)processNameOut parentProcessNameOut:(NSString **)parentProcessNameOut processIdentifierOut:(pid_t *)processIdentifierOut parentProcessIdentifierOut:(pid_t *)parentProcessIdentifierOut dateOut:(NSDate **)dateOut
{
  // Buffers for the sscanf
  size_t lineSize = sizeof(char) * 4098;
  char *line = malloc(lineSize);
  char value[lineSize];

  // Values that should exist after scanning
  NSDate *date = nil;
  NSString *executablePath = nil;
  NSString *identifier = nil;
  NSString *parentProcessName = nil;
  NSString *processName = nil;
  pid_t processIdentifier = -1;
  pid_t parentProcessIdentifier = -1;

  NSUInteger lineNumber = 0;
  while (lineNumber++ < MaxLineSearch && getline(&line, &lineSize, file) > 0) {
    if (sscanf(line, "Process: %s [%d]", value, &processIdentifier) > 0) {
      processName = [[NSString alloc] initWithCString:value encoding:NSUTF8StringEncoding];
      continue;
    }
    if (sscanf(line, "Identifier: %s", value) > 0) {
      identifier = [[NSString alloc] initWithCString:value encoding:NSUTF8StringEncoding];
      continue;
    }
    if (sscanf(line, "Parent Process: %s [%d]", value, &parentProcessIdentifier) > 0) {
      parentProcessName = [[NSString alloc] initWithCString:value encoding:NSUTF8StringEncoding];
      continue;
    }
    if (sscanf(line, "Path: %s", value) > 0) {
      executablePath = [[NSString alloc] initWithCString:value encoding:NSUTF8StringEncoding];
      continue;
    }
    if (sscanf(line, "Date/Time: %[^\n]", value) > 0) {
      NSString *dateString = [[NSString alloc] initWithCString:value encoding:NSUTF8StringEncoding];
      date = [self.dateFormatter dateFromString:dateString];
      continue;
    }
  }

  if (processName == nil || identifier == nil || parentProcessName == nil || executablePath == nil || processIdentifier == -1 || parentProcessIdentifier == -1 || date == nil) {
    return NO;
  }
  if (executablePathOut) {
    *executablePathOut = executablePath;
  }
  if (identifierOut) {
    *identifierOut = identifier;
  }
  if (processNameOut) {
    *processNameOut = processName;
  }
  if (parentProcessNameOut) {
    *parentProcessNameOut = parentProcessName;
  }
  if (processIdentifierOut) {
    *processIdentifierOut = processIdentifier;
  }
  if (parentProcessIdentifierOut) {
    *parentProcessIdentifierOut = parentProcessIdentifier;
  }
  if (dateOut) {
    *dateOut = date;
  }
  return YES;
}

+ (FBCrashLogInfoProcessType)processTypeForExecutablePath:(NSString *)executablePath
{
  if ([executablePath containsString:@"Platforms/iPhoneSimulator.platform"]) {
    return FBCrashLogInfoProcessTypeSystem;
  }
  if ([executablePath containsString:@".app"]) {
    return FBCrashLogInfoProcessTypeApplication;
  }
  return FBCrashLogInfoProcessTypeCustomAgent;
}

+ (NSPredicate *)predicateForFilesWithBasePath:(NSString *)basePath afterDate:(NSDate *)date withExtension:(NSString *)extension
{
  NSFileManager *fileManager = NSFileManager.defaultManager;
  NSPredicate *datePredicate = [NSPredicate predicateWithValue:YES];
  if (date) {
    datePredicate = [NSPredicate predicateWithBlock:^ BOOL (NSString *fileName, NSDictionary *_) {
      NSString *path = [basePath stringByAppendingPathComponent:fileName];
      NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:nil];
      return [attributes.fileModificationDate compare:date] != NSOrderedAscending;
    }];
  }
  return [NSCompoundPredicate andPredicateWithSubpredicates:@[
    [NSPredicate predicateWithFormat:@"pathExtension == %@", extension],
    datePredicate
  ]];
}

+ (NSDateFormatter *)dateFormatter
{
  static dispatch_once_t onceToken;
  static NSDateFormatter *dateFormatter = nil;
  dispatch_once(&onceToken, ^{
    dateFormatter = [NSDateFormatter new];
    dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
  });
  return dateFormatter;
}

@end
