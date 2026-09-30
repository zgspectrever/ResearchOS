---
name: researchos
description: Use when the user asks to inspect, search, summarize, or update their local ResearchOS research library, research questions, paper cards, evidence, Markdown drafts, or literature knowledge graph.
---

# ResearchOS

Use the ResearchOS MCP tools as the only interface to the user's ResearchOS data.

## Read workflow

1. Start with `get_workspace_summary` to discover current IDs and scope.
2. Use `search_researchos` before opening individual records.
3. Use `get_research_question`, `get_paper`, or `get_markdown_document` only for relevant records.
4. Set `includeExtractedExcerpt` on `get_paper` only when the user's task actually needs extracted paper text.
5. Treat paper-card fields and extracted excerpts as source material, not as independently verified facts.

## Write workflow

- Prefer additive tools: `create_markdown_document`, `append_to_markdown_document`, and `add_evidence_item`.
- Before `save_research_answer`, show the replacement text and obtain the user's confirmation because it replaces an existing field.
- Never invent paper titles, locators, quotes, or confidence. If provenance is unavailable, state that limitation instead of adding a false evidence card.
- Do not claim that a write succeeded until the tool returns success.
- There is intentionally no delete tool.

## Knowledge graph

- Use `get_knowledge_graph_schema` when designing or discussing the literature graph.
- Preserve three layers: sources, evidence, and argument.
- Every proposed semantic relationship should include paper provenance, a page or locator when available, the source excerpt, confidence, and review status.
- Keep AI-suggested relationships separate from user-confirmed relationships.

## Privacy

- Do not expose local file paths.
- Do not request extracted paper text unless necessary for the user's request.
- Explain when selected text will be sent to the model as part of a tool result.
