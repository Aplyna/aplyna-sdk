import XCTest
@testable import Aplyna

final class DesignPropertiesTests: XCTestCase {
    func testAdvancedDesignPropertiesRoundTripWithoutLosingAppearance() throws {
        let json = ##"{"width":"fill","height":"fill","minWidth":120,"maxWidth":280,"minHeight":40,"maxHeight":160,"fontStyle":"italic","underline":true,"strikethrough":true,"letterSpacing":1.2,"shape":"pill","gradient":{"start":"#345CFF","end":"#10182880","angle":135},"border":{"width":2,"color":"#FFFFFF80"},"shadow":{"x":-2,"y":4,"blur":12,"color":"#00000026"},"badge":{"text":"Best value","position":"center","color":"#FFFFFF","background":"#345CFF"}}"##
        let decoder = JSONDecoder()
        let design = try decoder.decode(AplynaElementDesign.self, from: Data(json.utf8))
        let restored = try decoder.decode(AplynaElementDesign.self, from: JSONEncoder().encode(design))
        XCTAssertEqual(restored.width, .fill)
        XCTAssertEqual(restored.minWidth, 120)
        XCTAssertEqual(restored.maxHeight, 160)
        XCTAssertEqual(restored.fontStyle, "italic")
        XCTAssertEqual(restored.underline, true)
        XCTAssertEqual(restored.strikethrough, true)
        XCTAssertEqual(restored.letterSpacing, 1.2)
        XCTAssertEqual(restored.shape, "pill")
        XCTAssertEqual(restored.gradient?.end, "#10182880")
        XCTAssertEqual(restored.border?.width, 2)
        XCTAssertEqual(restored.shadow?.x, -2)
        XCTAssertEqual(restored.badge?.text, "Best value")
    }
}
