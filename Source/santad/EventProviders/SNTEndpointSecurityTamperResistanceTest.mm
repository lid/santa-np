/// Copyright 2022 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#include <EndpointSecurity/ESTypes.h>
#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include <stdlib.h>

#include <map>
#include <memory>
#include <set>

#include "Source/common/TestUtils.h"
#include "Source/santad/DataLayer/WatchItemPolicy.h"
#include "Source/santad/EventProviders/EndpointSecurity/Client.h"
#include "Source/santad/EventProviders/EndpointSecurity/Message.h"
#include "Source/santad/EventProviders/EndpointSecurity/MockEndpointSecurityAPI.h"
#import "Source/santad/EventProviders/SNTEndpointSecurityTamperResistance.h"
#import "Source/santad/Metrics.h"

using santa::Client;
using santa::EventDisposition;
using santa::Message;
using santa::WatchItemPathType;

static constexpr std::string_view kEventsDBPath = "/private/var/db/santa/events.db";
static constexpr std::string_view kRulesDBPath = "/private/var/db/santa/rules.db";
static constexpr std::string_view kBenignPath = "/some/other/path";
static constexpr std::string_view kSantaKextIdentifier = "com.northpolesec.santa-driver";

@interface SNTEndpointSecurityTamperResistance (Testing)
+ (bool)isProtectedPath:(std::string_view)path;
@end

@interface SNTEndpointSecurityTamperResistanceTest : XCTestCase
@end

@implementation SNTEndpointSecurityTamperResistanceTest

- (void)testEnable {
  // Ensure the client subscribes to expected event types
  std::set<es_event_type_t> expectedEventSubs{
    ES_EVENT_TYPE_AUTH_SIGNAL,
    ES_EVENT_TYPE_AUTH_EXEC,
    ES_EVENT_TYPE_AUTH_UNLINK,
    ES_EVENT_TYPE_AUTH_RENAME,
  };

  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();
  EXPECT_CALL(*mockESApi, NewClient(testing::_))
    .WillOnce(testing::Return(Client(nullptr, ES_NEW_CLIENT_RESULT_SUCCESS)));
  EXPECT_CALL(*mockESApi, MuteProcess(testing::_, testing::_)).WillOnce(testing::Return(true));
  EXPECT_CALL(*mockESApi, ClearCache(testing::_))
    .After(EXPECT_CALL(*mockESApi, Subscribe(testing::_, expectedEventSubs))
             .WillOnce(testing::Return(true)))
    .WillOnce(testing::Return(true));

  // Setup mocks to handle inverting target path muting
  EXPECT_CALL(*mockESApi, InvertTargetPathMuting).WillOnce(testing::Return(true));
  EXPECT_CALL(*mockESApi, UnmuteAllTargetPaths).WillOnce(testing::Return(true));

  // Setup mocks to handle muting the rules db and events db
  EXPECT_CALL(*mockESApi, MuteTargetPath(testing::_, testing::_, WatchItemPathType::kLiteral))
    .WillRepeatedly(testing::Return(true));
  EXPECT_CALL(*mockESApi, MuteTargetPath(testing::_, testing::_, WatchItemPathType::kPrefix))
    .WillRepeatedly(testing::Return(true));

  SNTEndpointSecurityTamperResistance *tamperClient =
    [[SNTEndpointSecurityTamperResistance alloc] initWithESAPI:mockESApi
                                                       metrics:nullptr
                                                        logger:nullptr];
  id mockTamperClient = OCMPartialMock(tamperClient);

  [mockTamperClient enable];

  for (const auto &event : expectedEventSubs) {
    XCTAssertNoThrow(santa::EventTypeToString(event));
  }

  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
  [mockTamperClient stopMocking];
}

- (void)testHandleMessage {
  es_file_t file = MakeESFile("foo");
  es_process_t proc = MakeESProcess(&file);
  es_message_t esMsg = MakeESMessage(ES_EVENT_TYPE_AUTH_LINK, &proc, ActionType::Auth);

  es_file_t fileEventsDB = MakeESFile(kEventsDBPath.data());
  es_file_t fileRulesDB = MakeESFile(kRulesDBPath.data());
  es_file_t fileBenign = MakeESFile(kBenignPath.data());

  es_string_token_t santaTok = MakeESStringToken(kSantaKextIdentifier.data());
  es_string_token_t benignTok = MakeESStringToken(kBenignPath.data());

  std::map<es_file_t *, es_auth_result_t> pathToResult{
    {&fileEventsDB, ES_AUTH_RESULT_DENY},
    {&fileRulesDB, ES_AUTH_RESULT_DENY},
    {&fileBenign, ES_AUTH_RESULT_ALLOW},
  };

  std::map<es_string_token_t *, es_auth_result_t> kextIdToResult{
    {&santaTok, ES_AUTH_RESULT_DENY},
    {&benignTok, ES_AUTH_RESULT_ALLOW},
  };

  std::map<std::pair<pid_t, pid_t>, es_auth_result_t> pidsToResult{
    {{getpid(), 31838}, ES_AUTH_RESULT_DENY},
    {{getpid(), 1}, ES_AUTH_RESULT_ALLOW},
    {{435, 98381}, ES_AUTH_RESULT_ALLOW},
  };

  dispatch_semaphore_t semaMetrics = dispatch_semaphore_create(0);

  auto mockESApi = std::make_shared<MockEndpointSecurityAPI>();
  mockESApi->SetExpectationsESNewClient();
  mockESApi->SetExpectationsRetainReleaseMessage();

  SNTEndpointSecurityTamperResistance *tamperClient =
    [[SNTEndpointSecurityTamperResistance alloc] initWithESAPI:mockESApi
                                                       metrics:nullptr
                                                        logger:nullptr];

  id mockTamperClient = OCMPartialMock(tamperClient);

  // Unable to use `OCMExpect` here because we cannot match on the `Message`
  // parameter. In order to verify the `AuthResult` and `Cacheable` parameters,
  // instead use `OCMStub` and extract the arguments in order to assert their
  // expected values.
  __block es_auth_result_t gotAuthResult;
  __block bool gotCachable;
  OCMStub([mockTamperClient respondToMessage:Message(mockESApi, &esMsg)
                              withAuthResult:(es_auth_result_t)0
                                   cacheable:false])
    .ignoringNonObjectArgs()
    .andDo(^(NSInvocation *inv) {
      [inv getArgument:&gotAuthResult atIndex:3];
      [inv getArgument:&gotCachable atIndex:4];
    });

  // First check unhandled event types will crash
  {
    Message msg(mockESApi, &esMsg);
    XCTAssertThrows([tamperClient handleMessage:Message(mockESApi, &esMsg)
                             recordEventMetrics:^(EventDisposition d) {
                               XCTFail("Unhandled event types shouldn't call metrics recorder");
                             }]);
  }

  // Check UNLINK tamper events
  {
    esMsg.event_type = ES_EVENT_TYPE_AUTH_UNLINK;
    for (const auto &kv : pathToResult) {
      Message msg(mockESApi, &esMsg);
      esMsg.event.unlink.target = kv.first;

      [mockTamperClient
             handleMessage:std::move(msg)
        recordEventMetrics:^(EventDisposition d) {
          XCTAssertEqual(d, kv.second == ES_AUTH_RESULT_DENY ? EventDisposition::kProcessed
                                                             : EventDisposition::kDropped);
          dispatch_semaphore_signal(semaMetrics);
        }];

      XCTAssertSemaTrue(semaMetrics, 5, "Metrics not recorded within expected window");

      XCTAssertEqual(gotAuthResult, kv.second);
      XCTAssertEqual(gotCachable, kv.second == ES_AUTH_RESULT_ALLOW);
    }
  }

  // Check RENAME `source` tamper events
  {
    esMsg.event_type = ES_EVENT_TYPE_AUTH_RENAME;
    for (const auto &kv : pathToResult) {
      Message msg(mockESApi, &esMsg);
      esMsg.event.rename.source = kv.first;
      esMsg.event.rename.destination_type = ES_DESTINATION_TYPE_NEW_PATH;

      [mockTamperClient
             handleMessage:std::move(msg)
        recordEventMetrics:^(EventDisposition d) {
          XCTAssertEqual(d, kv.second == ES_AUTH_RESULT_DENY ? EventDisposition::kProcessed
                                                             : EventDisposition::kDropped);
          dispatch_semaphore_signal(semaMetrics);
        }];

      XCTAssertSemaTrue(semaMetrics, 5, "Metrics not recorded within expected window");
      XCTAssertEqual(gotAuthResult, kv.second);
      XCTAssertEqual(gotCachable, kv.second == ES_AUTH_RESULT_ALLOW);
    }
  }

  // Check RENAME `dest` tamper events
  {
    esMsg.event_type = ES_EVENT_TYPE_AUTH_RENAME;
    esMsg.event.rename.source = &fileBenign;
    for (const auto &kv : pathToResult) {
      Message msg(mockESApi, &esMsg);
      esMsg.event.rename.destination_type = ES_DESTINATION_TYPE_EXISTING_FILE;
      esMsg.event.rename.destination.existing_file = kv.first;

      [mockTamperClient
             handleMessage:std::move(msg)
        recordEventMetrics:^(EventDisposition d) {
          XCTAssertEqual(d, kv.second == ES_AUTH_RESULT_DENY ? EventDisposition::kProcessed
                                                             : EventDisposition::kDropped);
          dispatch_semaphore_signal(semaMetrics);
        }];

      XCTAssertSemaTrue(semaMetrics, 5, "Metrics not recorded within expected window");
      XCTAssertEqual(gotAuthResult, kv.second);
      XCTAssertEqual(gotCachable, kv.second == ES_AUTH_RESULT_ALLOW);
    }
  }

  // Check SIGNAL tamper events
  {
    esMsg.event_type = ES_EVENT_TYPE_AUTH_SIGNAL;

    for (const auto &kv : pidsToResult) {
      Message msg(mockESApi, &esMsg);
      es_process_t target_proc = MakeESProcess(&file);
      target_proc.audit_token = MakeAuditToken(kv.first.first, 42);
      esMsg.event.signal.target = &target_proc;
      esMsg.process->audit_token = MakeAuditToken(kv.first.second, 42);

      [mockTamperClient
             handleMessage:std::move(msg)
        recordEventMetrics:^(EventDisposition d) {
          XCTAssertEqual(d, kv.second == ES_AUTH_RESULT_DENY ? EventDisposition::kProcessed
                                                             : EventDisposition::kDropped);
          dispatch_semaphore_signal(semaMetrics);
        }];

      XCTAssertSemaTrue(semaMetrics, 5, "Metrics not recorded within expected window");
      XCTAssertEqual(gotAuthResult, kv.second);
      XCTAssertEqual(gotCachable, kv.second == ES_AUTH_RESULT_ALLOW);
    }
  }

  XCTBubbleMockVerifyAndClearExpectations(mockESApi.get());
  XCTAssertTrue(OCMVerifyAll(mockTamperClient));

  [mockTamperClient stopMocking];
}

- (void)testIsProtectedPath {
  XCTAssertTrue(
    [SNTEndpointSecurityTamperResistance isProtectedPath:"/private/var/db/santa/rules.db"]);
  XCTAssertTrue(
    [SNTEndpointSecurityTamperResistance isProtectedPath:"/private/var/db/santa/events.db"]);
  XCTAssertTrue([SNTEndpointSecurityTamperResistance isProtectedPath:"/Applications/Santa.app"]);

  XCTAssertFalse([SNTEndpointSecurityTamperResistance isProtectedPath:"/not/a/db/path"]);
}

@end
