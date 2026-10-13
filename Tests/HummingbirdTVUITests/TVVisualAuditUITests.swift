import XCTest

/// Physical-device layout audit for every stable top-level tvOS destination.
///
/// Keep this test in the normal Debug scheme: new screens must be added here,
/// and every checkpoint receives Apple's clipped-text audit plus Hummingbird's
/// peer-overlap and screen-boundary checks. Intentional compositing belongs in
/// `allowedOverlap`; broad geometry exemptions are deliberately unsupported.
final class TVVisualAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @MainActor
    func testAllTopLevelMenusHaveSoundLayout() throws {
        try audit("Home")

        for route in ["subscriptions", "search", "library", "sources", "settings"] {
            launch(route)
            try audit(route.capitalized)
        }
    }

    @MainActor
    func testAllTopLevelMenusHaveNoClippedText() throws {
        try app.performAccessibilityAudit(for: [.textClipped])
        for route in ["subscriptions", "search", "library", "sources", "settings"] {
            launch(route)
            try app.performAccessibilityAudit(for: [.textClipped])
        }
    }

    @MainActor
    func testSearchIncludesSharedBrowserToolbar() {
        launch("search")
        XCTAssertTrue(app.buttons["1 tab"].waitForExistence(timeout: 3))
        XCTAssertLessThan(app.buttons["Back"].frame.midX, app.frame.midX)
        XCTAssertLessThan(app.buttons["Forward"].frame.midX, app.frame.midX)
    }

    @MainActor
    private func audit(_ name: String) throws {
        waitForAnimations()
        XCTAssertTrue(
            app.buttons["1 tab"].waitForExistence(timeout: 2),
            "\(name) is missing the shared browser toolbar"
        )
        XCTContext.runActivity(named: "Visual audit: \(name)") { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "tvOS-\(name)"
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
        }

        let problems = geometryProblems()
        XCTAssertTrue(problems.isEmpty, "\(name) layout issues:\n\(problems.joined(separator: "\n"))")

        for label in ["Back", "Forward"] {
            let control = app.buttons[label]
            XCTAssertLessThan(control.frame.midX, app.frame.midX, "\(name) \(label) must remain on the leading side")
        }

    }

    @MainActor
    private func launch(_ route: String) {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["HUMMINGBIRD_VISUAL_AUDIT_ROUTE"] = route
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @MainActor
    private func geometryProblems() -> [String] {
        let screen = app.frame
        let candidates = visibleLeafElements()
        var problems: [String] = []

        for item in candidates where !screen.insetBy(dx: -2, dy: -2).contains(item.frame) {
            problems.append("offscreen \(describe(item))")
        }

        for leftIndex in candidates.indices {
            for rightIndex in candidates.indices where rightIndex > leftIndex {
                let left = candidates[leftIndex]
                let right = candidates[rightIndex]
                let intersection = left.frame.intersection(right.frame)
                guard !intersection.isNull, intersection.width > 3, intersection.height > 3 else { continue }
                guard !contains(left.frame, right.frame), !contains(right.frame, left.frame) else { continue }
                guard overlapRatio(intersection, relativeTo: left.frame) > 0.12,
                      overlapRatio(intersection, relativeTo: right.frame) > 0.12 else { continue }
                guard !allowedOverlap(left, right) else { continue }
                problems.append("overlap \(describe(left)) <> \(describe(right)); intersection=\(intersection)")
            }
        }
        return problems
    }

    @MainActor
    private func visibleLeafElements() -> [XCUIElement] {
        let types: [XCUIElement.ElementType] = [.staticText, .button, .textField, .searchField, .image]
        return types.flatMap { app.descendants(matching: $0).allElementsBoundByIndex }
            .filter { $0.exists && !$0.frame.isEmpty && $0.frame.width.isFinite && $0.frame.height.isFinite }
    }

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    private func overlapRatio(_ intersection: CGRect, relativeTo frame: CGRect) -> CGFloat {
        intersection.width * intersection.height / max(1, frame.width * frame.height)
    }

    private func allowedOverlap(_ first: XCUIElement, _ second: XCUIElement) -> Bool {
        let pair = Set([first.label, second.label])
        // Thumbnail badges and player chrome are intentional compositing.
        if pair.contains("Playback position") { return true }
        if first.elementType == .image || second.elementType == .image { return true }
        return false
    }

    private func describe(_ element: XCUIElement) -> String {
        "\(element.elementType) '\(element.label)' frame=\(element.frame)"
    }

    private func waitForAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
}
