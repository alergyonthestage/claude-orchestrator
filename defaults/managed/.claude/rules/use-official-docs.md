# Use Official Framework Documentation

When official framework documentation (llms.txt) is listed in the session
context:

1. **Consult before writing**: Read the relevant llms.txt documentation BEFORE
   writing code that uses that framework. Do not rely solely on training data —
   APIs change between versions.

2. **Read selectively**: Large documentation files (10K+ lines) should be read
   with offset/limit targeting the relevant section. Do not read the entire file.

3. **Index files**: When a documentation file is an index (contains URLs to
   component/API pages), read the index first to locate the relevant page, then
   use WebFetch to retrieve the specific page content.

4. **Priority**: Official documentation takes precedence over training data when
   there is a conflict in API signatures, component props, or usage patterns.
