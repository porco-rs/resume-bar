import Testing
import RBContract

@Test func languageResolution() {
    #expect(AppLanguage.resolve(override: nil, preferred: ["de-DE", "en-US"], underTest: false) == .de)
    #expect(AppLanguage.resolve(override: nil, preferred: ["en-GB", "de-DE"], underTest: false) == .en)
    #expect(AppLanguage.resolve(override: nil, preferred: ["fr-FR", "de-AT"], underTest: false) == .de)
    #expect(AppLanguage.resolve(override: nil, preferred: ["fr-FR"], underTest: false) == .en)
    #expect(AppLanguage.resolve(override: nil, preferred: [], underTest: false) == .en)
    #expect(AppLanguage.resolve(override: "en", preferred: ["de"], underTest: true) == .en)
    #expect(AppLanguage.resolve(override: "de", preferred: ["en"], underTest: false) == .de)
    #expect(AppLanguage.resolve(override: "unknown", preferred: ["de"], underTest: false) == .de)
    #expect(AppLanguage.resolve(override: nil, preferred: ["en"], underTest: true) == .de)
    #expect(AppLanguage.current == .de)
}
