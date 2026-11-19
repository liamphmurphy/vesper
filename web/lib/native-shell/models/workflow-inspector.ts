import type { InspectorItem, InspectorOption, InspectorSection, NavItem } from "../protocol.ts";

export interface WorkflowNodeInput {
  id: string;
  type: string;
  title: string;
  config: {
    prompt?: string;
    persona_id?: string;
    web?: boolean;
    images?: boolean;
    image_engine?: string;
    check?: boolean;
    retry_from?: string;
    max_attempts?: number;
    requires_check?: string;
    path?: string;
    mode?: string;
    title?: string;
  };
}

export interface WorkflowInspectorInput {
  workflowName: string;
  workflowDescription: string;
  publishedVersion: number;
  unpublishedChanges: boolean;
  preview: boolean;
  selectedNode?: WorkflowNodeInput;
  personaOptions: readonly InspectorOption[];
  rerunnableOptions: readonly InspectorOption[];
  parentCheckOptions: readonly InspectorOption[];
  issues: readonly { node?: string; message: string }[];
  error?: string | null;
}

export function buildWorkflowInspectorSections(input: WorkflowInspectorInput): InspectorSection[] {
  const sections: InspectorSection[] = [];
  const disabled = input.preview;

  if (input.error) {
    sections.push({
      id: "error",
      items: [{ id: "workflow_error", kind: "note", label: "Error", detail: input.error, tone: "blocked" }],
    });
  }

  if (input.selectedNode) {
    const n = input.selectedNode;
    const c = n.config;
    const items: InspectorItem[] = [
      { id: "node.title", kind: "text", label: "Title", value: n.title, disabled },
      { id: "node.output", kind: "fact", label: "Output token", value: `{{${n.id}.output}}`, mono: true },
    ];

    if (n.type !== "trigger") {
      const promptLabel =
        n.type === "enrich"
          ? "Extra instructions (optional)"
          : n.type === "agent"
            ? "What this step should do"
            : n.type === "gate"
              ? "Message to the reviewer"
              : "Body (empty uses previous output)";
      items.push({
        id: "node.prompt",
        kind: "text",
        label: promptLabel,
        value: c.prompt ?? "",
        multiline: true,
        disabled,
      });
    }

    if (n.type === "agent") {
      items.push(
        {
          id: "node.persona_id",
          kind: "picker",
          label: "Persona",
          value: c.persona_id ?? "",
          options: [...input.personaOptions],
          disabled,
        },
        {
          id: "node.web",
          kind: "toggle",
          label: "Read the web",
          checked: !!c.web,
          detail: "Disables workspace access for this step.",
          disabled,
        },
        {
          id: "node.images",
          kind: "toggle",
          label: "Generate images",
          checked: !!c.images,
          disabled,
        },
      );
      if (c.images) {
        items.push({
          id: "node.image_engine",
          kind: "picker",
          label: "Image engine",
          value: c.image_engine ?? "",
          options: [
            { value: "", label: "Persona / workspace default" },
            { value: "auto", label: "Auto (first connected)" },
            { value: "codex", label: "Codex" },
            { value: "antigravity", label: "Antigravity" },
          ],
          disabled,
        });
      }
      items.push({
        id: "node.check",
        kind: "toggle",
        label: "Pass/fail check",
        checked: !!c.check,
        detail: "Stops downstream steps unless it passes.",
        disabled,
      });
      if (c.check) {
        items.push({
          id: "node.retry_from",
          kind: "picker",
          label: "If check fails",
          value: c.retry_from ?? "",
          options: [...input.rerunnableOptions],
          disabled,
        });
        if (c.retry_from) {
          items.push({
            id: "node.max_attempts",
            kind: "text",
            label: "Failures allowed",
            value: String(c.max_attempts ?? 3),
            placeholder: "1-5",
            disabled,
          });
        }
      }
    }

    if (n.type === "gate") {
      items.push({
        id: "node.retry_from",
        kind: "picker",
        label: "If changes requested",
        value: c.retry_from ?? "",
        options: [...input.rerunnableOptions],
        disabled,
      });
      if (c.retry_from) {
        items.push({
          id: "node.max_attempts",
          kind: "text",
          label: "Reviews allowed",
          value: String(c.max_attempts ?? 3),
          placeholder: "1-5",
          disabled,
        });
      }
      items.push({
        id: "node.requires_check",
        kind: "picker",
        label: "Needs check",
        value: c.requires_check ?? "",
        options: [...input.parentCheckOptions],
        disabled,
      });
    }

    if (n.type === "wiki") {
      items.push(
        {
          id: "node.path",
          kind: "text",
          label: "Page path",
          value: c.path ?? "",
          placeholder: "Research/Findings",
          mono: true,
          disabled,
        },
        {
          id: "node.mode",
          kind: "picker",
          label: "If page exists",
          value: c.mode ?? "replace",
          options: [
            { value: "replace", label: "Replace (keeps history)" },
            { value: "append", label: "Append to end" },
          ],
          disabled,
        },
      );
    }

    if (n.type === "library" || n.type === "ticket") {
      items.push({
        id: "node.item_title",
        kind: "text",
        label: n.type === "ticket" ? "Ticket title" : "Item title",
        value: c.title ?? "",
        disabled,
      });
    }

    if (n.type !== "trigger") {
      items.push({
        id: "node_actions",
        kind: "actions",
        actions: [{ id: "delete_node", label: "Delete node", icon: "trash", destructive: true, disabled }],
      });
    }

    sections.push({
      id: "node",
      title: `Step · ${n.type}`,
      items,
    });
  } else {
    const versionText =
      input.publishedVersion > 0
        ? `v${input.publishedVersion}${input.unpublishedChanges ? " · edited" : ""}`
        : "Draft";
    sections.push({
      id: "workflow",
      title: "Workflow settings",
      items: [
        { id: "workflow.status", kind: "fact", label: "Version", value: versionText, mono: true },
        { id: "workflow.name", kind: "text", label: "Name", value: input.workflowName, disabled },
        {
          id: "workflow.description",
          kind: "text",
          label: "When to use",
          value: input.workflowDescription,
          placeholder: "Personas read this to recognize a request",
          multiline: true,
          disabled,
        },
        {
          id: "workflow.hint",
          kind: "note",
          detail: "Select a node on the canvas to configure it.",
          tone: "neutral",
        },
      ],
    });
  }

  if (input.issues.length > 0) {
    sections.push({
      id: "issues",
      title: "Before you can publish",
      aside: String(input.issues.length),
      items: [
        {
          id: "issue_list",
          kind: "list",
          actionId: "select_issue_node",
          rows: input.issues.map(
            (issue, idx): NavItem => ({
              id: issue.node ?? `issue:${idx}`,
              title: issue.message,
              status: "human",
            }),
          ),
        },
      ],
    });
  }

  return sections;
}
