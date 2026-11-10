import XCTest
@testable import MacADTKit

/// Contract of the standalone model's post-install template.
///
/// MacADT instantiates it by string substitution (like the Windows command
/// line) to inject the `packageKey` and the mode chosen by the operator. A broken
/// template, or a token left in a comment, produces a script that no longer passes
/// `sh -n` and a deployment silently running without any framing.
final class TemplateRenderingTests: XCTestCase {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)   // Tests/MacADTKitTests/TemplateRenderingTests.swift
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let templateName = "macos-postinstall-standalone.sh.template"

    private func template() throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent("Scripts/templates/\(templateName)"),
            encoding: .utf8)
    }

    func testTemplateExists() throws {
        XCTAssertFalse(try template().isEmpty, "\(templateName) is empty or missing")
    }

    func testDeclaresEveryTokenToSubstitute() throws {
        let content = try template()
        for token in ["{##PACKAGE_KEY##}", "{##DEPLOY_MODE##}"] {
            XCTAssertTrue(content.contains(token), "missing token: \(token)")
        }
    }

    /// The substitution is a string replacement over the whole file, comments
    /// included: a token written in a comment would receive its value right in the
    /// documentation and break the rendered script.
    func testNoTokenAppearsInACommentLine() throws {
        for (index, line) in try template().components(separatedBy: "\n").enumerated() {
            guard line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            XCTAssertFalse(line.contains("{##"),
                           "\(templateName):\(index + 1) — token in a comment: \(line)")
        }
    }

    func testTranslatesRestartCodesToZero() throws {
        // Without this translation, a successful install that requires a restart
        // would be seen as a failure by Intune, which would reinstall in a loop.
        XCTAssertTrue(try template().contains("70|71|72"),
                      "the restart-code translation has disappeared from the template")
    }

    /// The mode chosen by the operator must reach the agent, and no token must
    /// remain after substitution.
    func testRenderedScriptInvokesAgentWithChosenMode() throws {
        let rendered = try template()
            .replacingOccurrences(of: "{##PACKAGE_KEY##}", with: "chrome-2026q3")
            .replacingOccurrences(of: "{##DEPLOY_MODE##}", with: "Silent")

        XCTAssertFalse(rendered.contains("{##"), "unsubstituted token in the rendered script")
        XCTAssertTrue(rendered.contains("--mode \"Silent\""),
                      "the mode chosen in the UI must reach the agent")
    }
}
