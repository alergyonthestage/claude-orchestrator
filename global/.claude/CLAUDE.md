# Global Instructions

## Development Workflow

Every task follows this structured workflow. Phase transitions are MANUAL —
never skip ahead or auto-advance without explicit user approval.

### Phases
1. **Analysis** → Understand requirements, explore codebase, identify constraints
2. **Review & Approval** → Present findings, wait for user feedback
3. **Design** → Propose architecture, interfaces, data models
4. **Review & Approval** → Present design, wait for user feedback
5. **Implementation & Testing** → Write code, tests, verify
6. **Review & Approval** → Present implementation, wait for user feedback
7. **Documentation** → Update docs, README, API docs, changelog
8. **Closure** → Final review, merge readiness check

### Scope Levels
The workflow applies recursively at multiple levels:
- **Project**: Overall project planning and architecture
- **Architecture**: System-wide design decisions
- **App/Service**: Individual application or microservice
- **Module**: Component or module within an app
- **Feature**: Specific feature or user story

Always clarify the current scope level before starting work.

### Phase Behavior
- During **Analysis**: Read code, ask questions, produce summaries. NO code changes.
- During **Design**: Produce design docs, diagrams, interface definitions. NO implementation.
- During **Implementation**: Write code and tests. Follow the approved design.
- During **Documentation**: Update all relevant docs. NO new features.

## Git Practices
- Always work on feature branches, never directly on main/master
- Use conventional commits: feat:, fix:, docs:, refactor:, test:, chore:
- Commit frequently with meaningful, descriptive messages
- Create a new branch at the start of any implementation phase
- Branch naming: `<type>/<scope>/<description>` (e.g., `feat/auth/add-oauth-flow`)

## Communication Style
- Be concise and direct
- Present findings in structured format
- When presenting options, include trade-offs
- Ask clarifying questions before making assumptions
- At the end of each phase, summarize what was done and what's next

## Agent Teams
- The lead coordinates and delegates work to teammates
- Each teammate focuses on their specialized domain
- Use the shared task list for coordination
- Communicate relevant findings between teammates
- The lead synthesizes teammate outputs into coherent results

## Docker Environment
- This session runs inside a Docker container
- Repos are mounted at /workspace/<repo-name>/
- Docker socket is available — you can run docker and docker compose
- When starting infrastructure (postgres, redis, etc.), use the project network
- Dev servers run inside this container with ports mapped to the host
