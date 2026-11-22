import ArgumentParser
import KumoCoreKit

struct AgentPromptPayload: Encodable, Equatable {
    let page: String
    let intent: String
    let goal: String
    let steps: [AgentPromptStep]
    let prompt: String
}

extension KumoCommand {
    struct Prompt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print task-oriented guidance for a coding agent.",
            discussion: "Use `kumo prompt <page> [intent]`. With no page, or with --list, prints the registered pages and intent ids. Every referenced command is part of the current CLI."
        )

        @Argument(help: "Page id, for example overview, proxies, or dns.")
        var page: String?
        @Argument(help: "Optional intent id; defaults to the page's first intent.")
        var intent: String?
        @Flag(name: .long, help: "List pages and intent ids.")
        var list = false
        @OptionGroup var options: CLIOptions

        mutating func validate() throws {
            if list && (page != nil || intent != nil) {
                throw ValidationError("Use --list without a page or intent.")
            }
            if page == nil && intent != nil {
                throw ValidationError("Provide a page before an intent.")
            }
        }

        mutating func run() async throws {
            try options.install()
            if list || page == nil {
                let guides = AgentGuidance.guides
                CLIRuntime.current.write(guides) { guides in
                    guides.map { guide in
                        "\(guide.page): \(guide.intents.map(\.id).joined(separator: ", "))"
                    }.joined(separator: "\n")
                }
                return
            }

            let page = self.page!
            guard let guide = AgentGuidance.guide(for: page) else {
                throw AgentGuidanceError.unknownPage(page, available: AgentGuidance.guides.map(\.page))
            }
            let selected: AgentIntent
            if let intent {
                guard let match = guide.intents.first(where: { $0.id == intent }) else {
                    throw AgentGuidanceError.unknownIntent(page: page, intent: intent, available: guide.intents.map(\.id))
                }
                selected = match
            } else {
                guard let first = guide.intents.first else {
                    throw AgentGuidanceError.unknownIntent(page: page, intent: "", available: [])
                }
                selected = first
            }
            let payload = AgentPromptPayload(
                page: page,
                intent: selected.id,
                goal: selected.goal,
                steps: selected.steps,
                prompt: try AgentGuidance.prompt(page: page, intent: selected.id)
            )
            CLIRuntime.current.write(payload) { $0.prompt }
        }
    }
}
