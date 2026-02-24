# CLAUDE.md - Client/Frontend Guidelines

This file provides guidance to Claude Code (claude.ai/code) when working with the **client** portion of the `claude-orchestrator` project.

## Project Context
The frontend/client is responsible for the user interface that interacts with the `claude-orchestrator` backend. The orchestrator itself manages isolated Docker sessions for multi-project development.

## Tech Stack & Architecture
*(Note: Please verify the specific framework used in the client repository —e.g., SvelteKit, React, Vue, etc.— and adjust these guidelines accordingly.)*

- **UI Framework**: [Insert Framework, e.g., SvelteKit 5]
- **Styling**: [Insert UI Library, e.g., Tailwind CSS / shadcn]
- **API Communication**: All interactions with the orchestrator backend (Docker management, session tracking) should occur via REST / WebSocket exposed by the orchestrator.

## Commands
```bash
npm run dev      # Start local development server
npm run build    # Build for production
npm run lint     # Run linters
npm run format   # Format code
```

## Code Style & Conventions
- **Component Design**: Keep UI components isolated and reusable.
- **State Management**: Use the native state management provided by the framework.
- **API Layer**: Keep API calls abstracted away from pure UI components. Create wrapper services for interacting with the main orchestrator backend.
- **Naming**: 
  - PascalCase for UI Components (e.g., `SessionCard.svelte`).
  - camelCase for utility functions and variables.
- **Formatting**: Use Prettier (tabs/spaces as configured, single quotes).

## Interaction with Claude Orchestrator Backend
- The client should be aware that the backend is managing Docker containers (sibling containers).
- Understand that project data, memory, and contexts are isolated per project on the host. The UI should reflect this isolation clearly.
- When triggering session starts/stops, handle the asynchronous nature of Docker container lifecycle operations gracefully (show loading states, handle timeouts).

## Implementation Rules
1. Do not hardcode API endpoints. Use environment variables.
2. Avoid direct manipulation of the DOM; rely on the declarative framework.
3. Ensure the UI can handle real-time status updates from the orchestrator (e.g., if a container drops out unexpectedly).
