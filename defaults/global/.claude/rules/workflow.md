# Workflow Phase Rules

## Principles
- Phase transitions require explicit user approval — never auto-advance
- Decompose complex tasks: clarify scope before starting work
- If the approach changes during implementation, pause and discuss
- At the end of each phase, summarize findings and propose next steps

## Analysis Phase
- Read and understand all relevant code before proposing changes
- Identify dependencies, constraints, and potential risks
- Document findings in a structured analysis summary
- List questions that need answers before proceeding
- DO NOT modify any files during analysis

## Design Phase
- Reference the analysis findings
- Propose clear interfaces and data models
- Consider error handling and edge cases
- Evaluate alternatives and document trade-offs
- Produce diagrams where helpful
- DO NOT write implementation code during design

## Implementation Phase
- Follow the approved design
- Write tests alongside implementation
- Commit after each logical unit of work
- Run existing tests to verify no regressions
- If the design needs changes, pause and discuss

## Documentation Phase
- Update README if public API changed
- Update inline code comments
- Update changelog
- Document new configuration options
- DO NOT add new features during documentation
