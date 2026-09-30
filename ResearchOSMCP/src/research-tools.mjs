import * as z from "zod/v4";
import {
  appleReferenceDateNow,
  defaultLibraryPath,
  makeID,
  normalizeText,
  readLibrary,
  updateLibrary,
} from "./library-store.mjs";

const READ_ONLY = { readOnlyHint: true, openWorldHint: false, destructiveHint: false };
const ADDITIVE_WRITE = { readOnlyHint: false, openWorldHint: false, destructiveHint: false };
const REPLACE_WRITE = { readOnlyHint: false, openWorldHint: false, destructiveHint: true };

function result(payload, summary) {
  return {
    content: [{ type: "text", text: summary ?? JSON.stringify(payload, null, 2) }],
    structuredContent: payload,
  };
}

function publicPaper(paper, includeExcerpt = false) {
  const item = {
    id: paper.id,
    title: paper.title,
    authors: paper.authors,
    year: paper.year,
    venue: paper.venue,
    doi: paper.doi ?? null,
    status: paper.status,
    source: paper.source,
    analysisState: paper.analysisState,
    hasPDF: Boolean(paper.attachmentPath),
    pageCount: paper.pageCount ?? 0,
    abstract: paper.abstractText ?? "",
    researchQuestion: paper.researchQuestion ?? "",
    method: paper.method ?? "",
    finding: paper.finding ?? "",
    limitation: paper.limitation ?? "",
  };
  if (includeExcerpt) item.extractedExcerpt = String(paper.analysisInput ?? "").slice(0, 12_000);
  return item;
}

function findByID(items, id, kind) {
  const item = items.find(candidate => String(candidate.id).toLowerCase() === String(id).toLowerCase());
  if (!item) throw new Error(`找不到${kind}：${id}`);
  return item;
}

function searchableItems(library) {
  return [
    ...library.questions.map(item => ({
      type: "research_question",
      id: item.id,
      title: item.shortTitle,
      text: [item.question, item.workingAnswer, item.nextMove, ...(item.evidence ?? []).map(value => value.claim)].join("\n"),
    })),
    ...library.papers.map(item => ({
      type: "paper",
      id: item.id,
      title: item.title,
      text: [item.authors, item.venue, item.abstractText, item.researchQuestion, item.method, item.finding, item.limitation].join("\n"),
    })),
    ...library.markdownDocuments.map(item => ({
      type: "markdown_document",
      id: item.id,
      title: item.title,
      text: item.content,
    })),
  ];
}

export function registerResearchTools(server, libraryPath = defaultLibraryPath()) {
  server.registerTool("get_workspace_summary", {
    title: "读取 ResearchOS 概览",
    description: "读取本机 ResearchOS 中研究问题、论文和 Markdown 文稿的概览，不读取 PDF 文件。",
    inputSchema: {},
    annotations: READ_ONLY,
  }, async () => {
    const library = await readLibrary(libraryPath);
    return result({
      counts: {
        researchQuestions: library.questions.length,
        papers: library.papers.length,
        markdownDocuments: library.markdownDocuments.length,
        papersWithPDF: library.papers.filter(item => item.attachmentPath).length,
      },
      researchQuestions: library.questions.map(item => ({
        id: item.id,
        title: item.shortTitle,
        question: item.question,
        status: item.status,
        evidenceCount: (item.evidence ?? []).length,
      })),
      markdownDocuments: library.markdownDocuments.map(item => ({ id: item.id, title: item.title, modifiedAt: item.modifiedAt })),
    });
  });

  server.registerTool("search_researchos", {
    title: "检索 ResearchOS",
    description: "按关键词检索研究问题、论文卡片和 Markdown 文稿。只返回命中摘要，不读取 PDF 原文件。",
    inputSchema: {
      query: z.string().min(1).max(200).describe("要检索的关键词或短语"),
      limit: z.number().int().min(1).max(30).default(12).describe("最多返回多少项"),
    },
    annotations: READ_ONLY,
  }, async ({ query, limit }) => {
    const library = await readLibrary(libraryPath);
    const terms = query.toLocaleLowerCase().split(/\s+/).filter(Boolean);
    const matches = searchableItems(library).map(item => {
      const haystack = `${item.title}\n${item.text}`.toLocaleLowerCase();
      const score = terms.reduce((sum, term) => sum + (haystack.includes(term) ? 1 : 0), 0);
      const first = terms.map(term => haystack.indexOf(term)).filter(index => index >= 0).sort((a, b) => a - b)[0] ?? 0;
      const start = Math.max(0, first - 100);
      return { ...item, score, excerpt: item.text.slice(start, start + 500) };
    }).filter(item => item.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map(({ text: _text, ...item }) => item);
    return result({ query, matches });
  });

  server.registerTool("get_research_question", {
    title: "读取研究问题",
    description: "读取一个研究问题的工作结论、下一步和证据卡片。",
    inputSchema: { id: z.string().describe("研究问题 ID") },
    annotations: READ_ONLY,
  }, async ({ id }) => {
    const library = await readLibrary(libraryPath);
    return result({ question: findByID(library.questions, id, "研究问题") });
  });

  server.registerTool("get_paper", {
    title: "读取论文卡片",
    description: "读取一篇论文的元数据和 ResearchOS 已提取内容。仅在明确需要时才请求 extractedExcerpt。",
    inputSchema: {
      id: z.string().describe("论文 ID"),
      includeExtractedExcerpt: z.boolean().default(false).describe("是否包含最多 12000 字符的已提取正文片段"),
    },
    annotations: READ_ONLY,
  }, async ({ id, includeExtractedExcerpt }) => {
    const library = await readLibrary(libraryPath);
    return result({ paper: publicPaper(findByID(library.papers, id, "论文"), includeExtractedExcerpt) });
  });

  server.registerTool("get_markdown_document", {
    title: "读取 Markdown 文稿",
    description: "读取 ResearchOS 中一份 Markdown 文稿的完整内容。",
    inputSchema: { id: z.string().describe("Markdown 文稿 ID") },
    annotations: READ_ONLY,
  }, async ({ id }) => {
    const library = await readLibrary(libraryPath);
    return result({ document: findByID(library.markdownDocuments, id, "Markdown 文稿") });
  });

  server.registerTool("create_markdown_document", {
    title: "新建 ResearchOS 文稿",
    description: "在 ResearchOS 中新建一份 Markdown 文稿，不修改已有内容。",
    inputSchema: {
      title: z.string().min(1).max(200).describe("文稿标题"),
      content: z.string().max(200_000).default("").describe("Markdown 内容"),
    },
    annotations: ADDITIVE_WRITE,
  }, async ({ title, content }) => {
    const id = makeID();
    const cleanTitle = normalizeText(title, 200) || "未命名文稿";
    const cleanContent = normalizeText(content, 200_000) || `# ${cleanTitle}\n`;
    const document = await updateLibrary({
      path: libraryPath,
      action: "create_markdown_document",
      details: { id, title: cleanTitle },
      mutate: library => {
        const value = { id, title: cleanTitle, content: cleanContent, modifiedAt: appleReferenceDateNow() };
        library.markdownDocuments.unshift(value);
        return value;
      },
    });
    return result({ document }, `已在 ResearchOS 中新建《${cleanTitle}》。`);
  });

  server.registerTool("append_to_markdown_document", {
    title: "追加到 ResearchOS 文稿",
    description: "把内容追加到已有 Markdown 文稿末尾；不会覆盖原文。",
    inputSchema: {
      id: z.string().describe("Markdown 文稿 ID"),
      content: z.string().min(1).max(100_000).describe("要追加的 Markdown 内容"),
      heading: z.string().max(200).optional().describe("可选的二级标题"),
    },
    annotations: ADDITIVE_WRITE,
  }, async ({ id, content, heading }) => {
    const cleanContent = normalizeText(content, 100_000);
    const cleanHeading = heading ? normalizeText(heading, 200) : "";
    const document = await updateLibrary({
      path: libraryPath,
      action: "append_to_markdown_document",
      details: { id, heading: cleanHeading || null, characterCount: cleanContent.length },
      mutate: library => {
        const value = findByID(library.markdownDocuments, id, "Markdown 文稿");
        const block = `${cleanHeading ? `## ${cleanHeading}\n\n` : ""}${cleanContent}`;
        value.content = `${String(value.content ?? "").trimEnd()}\n\n${block}\n`;
        value.modifiedAt = appleReferenceDateNow();
        return value;
      },
    });
    return result({ document: { id: document.id, title: document.title, modifiedAt: document.modifiedAt } }, `已追加到《${document.title}》。`);
  });

  server.registerTool("save_research_answer", {
    title: "保存研究问题结论",
    description: "更新一个研究问题的工作结论或下一步。此操作会替换对应字段，应先让用户确认。",
    inputSchema: {
      id: z.string().describe("研究问题 ID"),
      workingAnswer: z.string().max(30_000).optional().describe("新的工作结论"),
      nextMove: z.string().max(10_000).optional().describe("新的下一步"),
    },
    annotations: REPLACE_WRITE,
  }, async ({ id, workingAnswer, nextMove }) => {
    if (workingAnswer === undefined && nextMove === undefined) throw new Error("至少提供 workingAnswer 或 nextMove。 ");
    const question = await updateLibrary({
      path: libraryPath,
      action: "save_research_answer",
      details: { id, updatedFields: [workingAnswer !== undefined ? "workingAnswer" : null, nextMove !== undefined ? "nextMove" : null].filter(Boolean) },
      mutate: library => {
        const value = findByID(library.questions, id, "研究问题");
        if (workingAnswer !== undefined) value.workingAnswer = normalizeText(workingAnswer, 30_000);
        if (nextMove !== undefined) value.nextMove = normalizeText(nextMove, 10_000);
        return value;
      },
    });
    return result({ question }, `已更新研究问题《${question.shortTitle}》。`);
  });

  server.registerTool("add_evidence_item", {
    title: "添加证据卡片",
    description: "向研究问题追加一条共识、分歧或证据空白，不改动已有证据。",
    inputSchema: {
      questionID: z.string().describe("研究问题 ID"),
      kind: z.enum(["convergence", "tension", "gap"]).describe("证据类型：共识、分歧或空白"),
      claim: z.string().min(1).max(10_000).describe("证据主张"),
      source: z.string().min(1).max(1_000).describe("论文、页码或其他出处"),
      confidence: z.string().min(1).max(500).describe("置信度及理由"),
    },
    annotations: ADDITIVE_WRITE,
  }, async ({ questionID, kind, claim, source, confidence }) => {
    const evidence = { id: makeID(), kind, claim: normalizeText(claim, 10_000), source: normalizeText(source, 1_000), confidence: normalizeText(confidence, 500) };
    const question = await updateLibrary({
      path: libraryPath,
      action: "add_evidence_item",
      details: { questionID, evidenceID: evidence.id, kind },
      mutate: library => {
        const value = findByID(library.questions, questionID, "研究问题");
        value.evidence ??= [];
        value.evidence.push(evidence);
        if (kind === "gap") value.openGapCount = Number(value.openGapCount ?? 0) + 1;
        return value;
      },
    });
    return result({ questionID: question.id, evidence }, `已向《${question.shortTitle}》添加证据卡片。`);
  });

  server.registerTool("get_knowledge_graph_schema", {
    title: "读取文献知识图谱结构",
    description: "读取 ResearchOS 计划采用的可溯源文献知识图谱节点和关系定义。",
    inputSchema: {},
    annotations: READ_ONLY,
  }, async () => result({
    layers: ["source", "evidence", "argument"],
    nodeTypes: ["paper", "claim", "method", "dataset", "finding", "limitation", "research_question", "hypothesis", "evidence_gap", "draft_section"],
    edgeTypes: ["cites", "supports", "contradicts", "extends", "uses_method", "uses_dataset", "answers", "limited_by", "leaves_gap", "used_in_draft"],
    requiredProvenance: ["paperID", "pageOrLocator", "sourceExcerpt", "confidence", "reviewStatus"],
    reviewStatuses: ["ai_suggested", "user_confirmed", "user_rejected"],
  }));
}
