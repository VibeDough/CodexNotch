import Foundation
import Testing
@testable import CodexPetNotch

@Suite struct AppLanguageTests {
    @Test func explicitLanguagesResolvePredictably() {
        #expect(AppLanguage.chinese.usesEnglish == false)
        #expect(AppLanguage.english.usesEnglish == true)
    }

    @Test func allLanguageChoicesRemainAvailable() {
        #expect(AppLanguage.allCases == [.system, .chinese, .english])
    }
}
