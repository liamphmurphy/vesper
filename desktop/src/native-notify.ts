import { Notification } from "electron";
import { alertActionFor, alertGroupId, type DesktopAlert, type NotificationPolicy } from "./notifications";

export interface AlertHandlers {
  open: (alert: DesktopAlert) => void;
  decide: (alert: DesktopAlert, decision: "approve" | "deny") => void;
  reply: (alert: DesktopAlert, text: string) => void;
}

/**
 * Shows inbox alerts in Notification Center with Approve/Decline or inline
 * Reply, grouped by ticket or run (LAZYAGENTS-241). Keeps a reference to each
 * notification until it's dismissed so its handlers aren't collected.
 */
export class NotificationPresenter {
  private readonly live = new Set<Notification>();

  show(alert: DesktopAlert, policy: NotificationPolicy, handlers: AlertHandlers): void {
    if (!Notification.isSupported()) return;
    const action = alertActionFor(alert, policy);
    const groupId = alertGroupId(alert, policy);
    const n = new Notification({
      title: alert.title,
      body: alert.body,
      silent: !policy.sound,
      ...(groupId ? { groupId } : {}),
      ...(action.type === "decide"
        ? { actions: action.labels.map((text) => ({ type: "button" as const, text })), closeButtonText: "Later" }
        : {}),
      ...(action.type === "reply" ? { hasReply: true, replyPlaceholder: action.placeholder } : {}),
    });
    const release = () => this.live.delete(n);
    n.on("click", () => {
      release();
      handlers.open(alert);
    });
    n.on("action", (details) => {
      release();
      if (action.type !== "decide") return;
      handlers.decide(alert, details.actionIndex === 0 ? "approve" : "deny");
    });
    n.on("reply", (details) => {
      release();
      if (action.type === "reply") handlers.reply(alert, details.reply);
    });
    n.on("close", release);
    n.on("failed", release);
    this.live.add(n);
    n.show();
  }

  /** A plain notice (an action's result, a stack error); clicking runs onClick. */
  notice(title: string, body: string, onClick?: () => void, silent = false): void {
    if (!Notification.isSupported()) return;
    const n = new Notification({ title, body, silent });
    const release = () => this.live.delete(n);
    n.on("click", () => {
      release();
      onClick?.();
    });
    n.on("close", release);
    n.on("failed", release);
    this.live.add(n);
    n.show();
  }
}
