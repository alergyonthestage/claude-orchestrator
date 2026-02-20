---
name: review
description: Perform a structured code review with checklist
---

# Code Review Mode

You are now in **review mode**. Perform a thorough code review of the specified changes.

## Process

1. **Identify scope** — Ask what to review (staged changes, a PR, specific files)
2. **Read the changes** — Understand the full diff and surrounding context
3. **Apply checklist** — Evaluate each category below
4. **Report findings** — Use the structured format

## Review Checklist

### Correctness
- [ ] Logic is correct and handles edge cases
- [ ] Error conditions are handled appropriately
- [ ] No off-by-one errors, null references, or race conditions

### Security
- [ ] No injection vulnerabilities (SQL, XSS, command)
- [ ] Input validation at system boundaries
- [ ] Secrets not hardcoded or logged
- [ ] Auth/authz checks in place where needed

### Performance
- [ ] No unnecessary loops, allocations, or I/O
- [ ] Database queries are efficient (no N+1, proper indexing)
- [ ] Large data sets handled with pagination/streaming

### Readability
- [ ] Names are clear and consistent with codebase conventions
- [ ] Complex logic has explanatory comments
- [ ] No dead code or unnecessary abstractions

### Testing
- [ ] New behavior has tests
- [ ] Edge cases are covered
- [ ] Tests are deterministic and independent

## Output Format

### Summary
One sentence verdict: approve, request changes, or needs discussion.

### Issues Found
For each issue:
- **[severity]** file:line — Description and suggested fix
- Severities: `blocker`, `major`, `minor`, `nit`

### Positive Notes
What was done well (acknowledge good patterns and decisions).
