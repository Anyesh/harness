#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { JSDOM } from "jsdom";
import { Readability } from "@mozilla/readability";
import TurndownService from "turndown";

const turndown = new TurndownService({
  headingStyle: "atx",
  codeBlockStyle: "fenced",
});

const server = new McpServer({
  name: "web-strip",
  version: "1.0.0",
});

server.registerTool(
  "fetch",
  {
    description:
      "Fetch a web page and return clean markdown with HTML boilerplate stripped. " +
      "Removes navigation, ads, scripts, sidebars, and footers. " +
      "Use this instead of WebFetch for reading web content to save tokens.",
    inputSchema: z.object({
      url: z.string().url().describe("The URL to fetch"),
      raw: z
        .boolean()
        .optional()
        .default(false)
        .describe("Return raw HTML instead of clean markdown (for webdev/debugging tasks)"),
      max_length: z
        .number()
        .optional()
        .default(50000)
        .describe("Maximum character length of returned content"),
    }),
  },
  async ({ url, raw, max_length }) => {
    try {
      const response = await fetch(url, {
        headers: {
          "User-Agent":
            "Mozilla/5.0 (compatible; Harness/1.0; +https://github.com/anyesh/harness)",
          Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        redirect: "follow",
        signal: AbortSignal.timeout(15000),
      });

      if (!response.ok) {
        return {
          content: [{ type: "text", text: `HTTP ${response.status}: ${response.statusText}` }],
          isError: true,
        };
      }

      const contentType = response.headers.get("content-type") || "";
      if (!contentType.includes("html") && !contentType.includes("xml")) {
        const text = await response.text();
        return {
          content: [{ type: "text", text: text.slice(0, max_length) }],
        };
      }

      const html = await response.text();

      if (raw) {
        return { content: [{ type: "text", text: html.slice(0, max_length) }] };
      }

      const dom = new JSDOM(html, { url });
      const reader = new Readability(dom.window.document);
      const article = reader.parse();

      let markdown;
      if (article) {
        const md = turndown.turndown(article.content);
        const meta = [
          `# ${article.title}`,
          article.byline ? `*${article.byline}*` : null,
          article.siteName ? `Source: ${article.siteName}` : null,
          `~${article.textContent.split(/\s+/).length} words`,
          "---",
        ]
          .filter(Boolean)
          .join("\n");
        markdown = `${meta}\n\n${md}`;
      } else {
        markdown = turndown.turndown(html);
      }

      if (markdown.length > max_length) {
        markdown = markdown.slice(0, max_length) + "\n\n[truncated]";
      }

      return { content: [{ type: "text", text: markdown }] };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Fetch failed: ${err.message}` }],
        isError: true,
      };
    }
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
