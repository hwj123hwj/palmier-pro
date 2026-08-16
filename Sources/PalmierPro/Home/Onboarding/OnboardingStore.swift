import Foundation
import Observation

@MainActor @Observable
final class OnboardingStore {
    /// Inherited from the pre-survey welcome overlay so existing installs stay onboarded.
    static let completionKey = "hasSeenWelcome"
    static let shared = OnboardingStore()

    private(set) var step = OnboardingStep.welcome
    private(set) var isComplete: Bool
    private(set) var selections: [OnboardingQuestion: Set<String>] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isComplete = defaults.bool(forKey: Self.completionKey)
    }

    func advance() {
        move(by: 1)
    }

    func goBack() {
        move(by: -1)
    }

    func submitSurvey() {
        complete()
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
        isComplete = true
    }

    func selection(for question: OnboardingQuestion) -> Set<String> {
        selections[question, default: []]
    }

    func toggle(_ option: OnboardingOption, for question: OnboardingQuestion) {
        var selection = selection(for: question)

        if !question.allowsMultipleSelection {
            selections[question] = selection.contains(option.id) ? [] : [option.id]
            return
        }

        if question.exclusiveOptionIDs.contains(option.id) {
            selections[question] = selection == [option.id] ? [] : [option.id]
            return
        }

        selection.subtract(question.exclusiveOptionIDs)
        if selection.contains(option.id) {
            selection.remove(option.id)
        } else {
            selection.insert(option.id)
        }
        selections[question] = selection
    }

    private func move(by offset: Int) {
        guard let destination = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        step = destination
    }
}
