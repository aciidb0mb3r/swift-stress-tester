//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Common

final class StressTestOperation: Operation {
  enum Status {
    /// Indicates the operation is still pending
    case unexecuted
    /// Indicates the operation was cancelled
    case cancelled
    /// Indicates the operation was executed and no issues were found
    case passed([SourceKitResponseData])
    /// Indicates the operation was executed and issues were found
    case failed(SourceKitError, [SourceKitResponseData])
    /// Indicates the operation was executed, but the stress tester itself failed
    case errored(status: Int32, arguments: [String])

    var name: String {
      switch self {
      case .unexecuted:
        return "unexecuted"
      case .cancelled:
        return "cancelled"
      case .passed:
        return "passed"
      case .failed:
        return "failed"
      case .errored:
        return "errored"
      }
    }

    var isPassed: Bool {
      if case .passed = self {
        return true
      }
      return false
    }
  }

  let file: String
  let part: (Int, of: Int)
  let mode: RewriteMode
  var status: Status = .unexecuted

  private let process: ProcessRunner

  init(file: String, rewriteMode: RewriteMode, requests: [RequestKind]?, conformingMethodTypes: [String]?, limit: Int?, part: (Int, of: Int), reportResponses: Bool, compilerArgs: [String], executable: String) {
    var stressTesterArgs = ["--format", "json", "--page", "\(part.0)/\(part.of)", "--rewrite-mode", rewriteMode.rawValue]
    if let limit = limit {
      stressTesterArgs += ["--limit", String(limit)]
    }
    if let requests = requests {
      stressTesterArgs += requests.flatMap { ["--request", $0.rawValue] }
    }
    if let types = conformingMethodTypes {
      stressTesterArgs += types.flatMap { ["--type-list-item", $0] }
    }
    if reportResponses {
      stressTesterArgs += ["--report-responses"]
    }

    self.file = file
    self.mode = rewriteMode
    self.part = part
    self.process = ProcessRunner(launchPath: executable, arguments: stressTesterArgs + [file, "swiftc"] + compilerArgs)
  }

  var summary: String {
    return "rewrite \(mode.rawValue) \(part.0)/\(part.of)"
  }

  override func main() {
    guard !isCancelled else {
      status = .cancelled
      return
    }

    let result = process.run()
    if isCancelled {
      status = .cancelled
    } else if let (error, responses) = parseMessages(result.stdout) {
      if result.status == EXIT_SUCCESS {
        status = .passed(responses)
      } else if let error = error {
        status = .failed(error, responses)
      } else {
        status = .errored(status: result.status, arguments: process.process.arguments ?? [])
      }
    } else {
      status = .errored(status: result.status, arguments: process.process.arguments ?? [])
    }
  }

  private func parseMessages(_ data: Data) -> (error: SourceKitError?, responses: [SourceKitResponseData])? {
    let terminator = UInt8(ascii: "\n")
    var sourceKitError: SourceKitError? = nil
    var sourceKitResponses = [SourceKitResponseData]()

    for data in data.split(separator: terminator, omittingEmptySubsequences: true) {
      guard let message = StressTesterMessage(from: data) else { return nil }
      switch message {
      case .detected(let error):
        guard sourceKitError == nil else { return nil }
        sourceKitError = error
      case .produced(let responseData):
        sourceKitResponses.append(responseData)
      }
    }
    return (sourceKitError, sourceKitResponses)
  }

  override func cancel() {
    super.cancel()
    process.terminate()
  }
}
