import path from "node:path";
import { Menu, nativeImage, Tray, type MenuItemConstructorOptions, type NativeImage } from "electron";
import { buildTrayMenu, trayTitle, trayTooltip, type TrayAction, type TrayMenuInput } from "./tray-model";
import { trayIconState } from "./stack-health";

const ICON_DIR = path.resolve(__dirname, "../renderer/tray");

/** Maps the tray model (tray-model.ts) onto an Electron Tray. macOS only. */
export class TrayController {
  private tray: Tray | null = null;
  private readonly icons = new Map<string, NativeImage>();
  private readonly onAction: (action: TrayAction) => void;

  constructor(onAction: (action: TrayAction) => void) {
    this.onAction = onAction;
  }

  get active(): boolean {
    return this.tray !== null;
  }

  ensure(): void {
    if (this.tray || process.platform !== "darwin") return;
    this.tray = new Tray(this.icon("running"));
    this.tray.setIgnoreDoubleClickEvents(true);
  }

  destroy(): void {
    this.tray?.destroy();
    this.tray = null;
  }

  render(input: TrayMenuInput, count: number, showCount: boolean): void {
    if (!this.tray) return;
    this.tray.setImage(this.icon(trayIconState(input.health.phase)));
    this.tray.setTitle(trayTitle(count, showCount), { fontType: "monospacedDigit" });
    this.tray.setToolTip(trayTooltip(input.health, count));
    const template: MenuItemConstructorOptions[] = buildTrayMenu(input).map((item) => {
      if (item.type === "separator") return { type: "separator" };
      if (item.type === "header") return { label: item.label, enabled: false };
      return {
        label: item.label,
        enabled: item.enabled !== false,
        ...(item.accelerator ? { accelerator: item.accelerator, registerAccelerator: false } : {}),
        click: () => this.onAction(item.action),
      };
    });
    this.tray.setContextMenu(Menu.buildFromTemplate(template));
  }

  private icon(state: "running" | "starting" | "error"): NativeImage {
    const file = state === "running" ? "trayTemplate.png" : state === "starting" ? "trayStartingTemplate.png" : "trayError.png";
    let img = this.icons.get(file);
    if (!img) {
      // createFromPath picks up the @2x file beside it; *Template names are tinted by macOS.
      img = nativeImage.createFromPath(path.join(ICON_DIR, file));
      this.icons.set(file, img);
    }
    return img;
  }
}
