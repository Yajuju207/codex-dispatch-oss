# Architecture

## Overview

Codex Dispatch separates the lightweight control layer from the actual development workspace.

```text
Natural language task
        ↓
Frontend (Drafts / Shortcut / other clients)
        ↓
GitHub Actions dispatch
        ↓
Self-hosted machine
        ↓
Project discovery
        ↓
Router
        ↓
Codex CLI worker
        ↓
Result notification
```

## Core ideas

### 1. Discovery

The local machine owns the knowledge of available projects. Project paths are discovered locally and validated instead of being generated from user text.

### 2. Routing

Simple tasks should be resolved quickly through deterministic local signals.

Examples:

- repository names
- directory names
- source identifiers
- file names

Ambiguous tasks should request clarification or use a deeper semantic fallback.

### 3. Worker isolation

Codex runs inside the selected project workspace. The control layer should not modify unrelated projects.

### 4. Human interaction

When Codex reaches a real decision point:

```text
NEEDS_INPUT
      ↓
mobile reply
      ↓
resume original task
```

## Current extraction status

This document describes the target architecture. Implementation details will be added after auditing the existing private deployment.
