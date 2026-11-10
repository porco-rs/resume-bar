import Testing
import RBUI

@Test func popoverActionDependsOnTriggerAndVisibility() {
    #expect(PopoverAction.decide(trigger: .click, isShown: false) == .open)
    #expect(PopoverAction.decide(trigger: .click, isShown: true) == .close)
    #expect(PopoverAction.decide(trigger: .hotkey, isShown: false) == .open)
    #expect(PopoverAction.decide(trigger: .hotkey, isShown: true) == .toggleMode)
}
