/// Marks timeline work performed by the agent or an MCP client. The editor reads this
/// to keep agent-driven mutations out of `nonAgentTimelineMutationRevision`.
enum AgentMutationScope {
    @TaskLocal static var isActive = false
}
