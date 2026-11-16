import { app, BrowserWindow, Menu, shell } from "electron";

export interface MenuActions {
  newTab: (focusedWin?: BrowserWindow) => void;
  newWindow: () => void;
  reopenClosedTab: (focusedWin?: BrowserWindow) => void;
  closeTab: (focusedWin?: BrowserWindow) => void;
  closeAllTabsInWindow: (focusedWin?: BrowserWindow) => void;
  selectNextTab: (focusedWin?: BrowserWindow) => void;
  selectPreviousTab: (focusedWin?: BrowserWindow) => void;
  selectTabIndex: (index: number, focusedWin?: BrowserWindow) => void;
  goBack: (focusedWin?: BrowserWindow) => void;
  goForward: (focusedWin?: BrowserWindow) => void;
  openSettings: () => void;
}

export function buildApplicationMenu(actions: MenuActions): void {
  const isMac = process.platform === "darwin";

  const tabNumberItems: Electron.MenuItemConstructorOptions[] = [1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => ({
    label: n === 9 ? "Last Tab" : `Tab ${n}`,
    accelerator: `CmdOrCtrl+${n}`,
    click: (_item, win) => actions.selectTabIndex(n, win instanceof BrowserWindow ? win : undefined),
  }));

  const template: Electron.MenuItemConstructorOptions[] = [
    ...(isMac
      ? [
          {
            label: app.name,
            submenu: [
              { role: "about" as const },
              { type: "separator" as const },
              {
                label: "Settings…",
                accelerator: "CmdOrCtrl+,",
                click: () => actions.openSettings(),
              },
              { type: "separator" as const },
              { role: "services" as const },
              { type: "separator" as const },
              { role: "hide" as const },
              { role: "hideOthers" as const },
              { role: "unhide" as const },
              { type: "separator" as const },
              { role: "quit" as const },
            ],
          },
        ]
      : []),
    {
      label: "File",
      submenu: [
        {
          label: "New Tab",
          accelerator: "CmdOrCtrl+T",
          click: (_item, win) => actions.newTab(win instanceof BrowserWindow ? win : undefined),
        },
        {
          label: "New Window",
          accelerator: "CmdOrCtrl+N",
          click: () => actions.newWindow(),
        },
        {
          label: "Reopen Closed Tab",
          accelerator: "CmdOrCtrl+Shift+T",
          click: (_item, win) => actions.reopenClosedTab(win instanceof BrowserWindow ? win : undefined),
        },
        { type: "separator" },
        {
          label: "Change Server URL…",
          accelerator: isMac ? undefined : "CmdOrCtrl+,",
          click: () => actions.openSettings(),
        },
        { type: "separator" },
        {
          label: "Close Tab",
          accelerator: "CmdOrCtrl+W",
          click: (_item, win) => actions.closeTab(win instanceof BrowserWindow ? win : undefined),
        },
        {
          label: "Close Window",
          accelerator: "CmdOrCtrl+Shift+W",
          click: (_item, win) => actions.closeAllTabsInWindow(win instanceof BrowserWindow ? win : undefined),
        },
        ...(!isMac ? [{ type: "separator" as const }, { role: "quit" as const }] : []),
      ],
    },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        { role: "reload" },
        { role: "forceReload" },
        { role: "toggleDevTools" },
        { type: "separator" },
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        ...(isMac ? [{ role: "toggleTabBar" as const }, { role: "showAllTabs" as const }, { type: "separator" as const }] : []),
        { role: "togglefullscreen" },
      ],
    },
    {
      label: "History",
      submenu: [
        {
          label: "Back",
          accelerator: isMac ? "Cmd+[" : "Alt+Left",
          click: (_item, win) => actions.goBack(win instanceof BrowserWindow ? win : undefined),
        },
        {
          label: "Forward",
          accelerator: isMac ? "Cmd+]" : "Alt+Right",
          click: (_item, win) => actions.goForward(win instanceof BrowserWindow ? win : undefined),
        },
      ],
    },
    {
      label: "Window",
      submenu: [
        { role: "minimize" },
        { role: "zoom" },
        { type: "separator" },
        {
          label: "Show Next Tab",
          accelerator: "Ctrl+Tab",
          click: (_item, win) => actions.selectNextTab(win instanceof BrowserWindow ? win : undefined),
        },
        {
          label: "Show Next Tab (Bracket)",
          accelerator: "CmdOrCtrl+Shift+]",
          visible: false,
          click: (_item, win) => actions.selectNextTab(win instanceof BrowserWindow ? win : undefined),
        },
        {
          label: "Show Previous Tab",
          accelerator: "Ctrl+Shift+Tab",
          click: (_item, win) => actions.selectPreviousTab(win instanceof BrowserWindow ? win : undefined),
        },
        {
          label: "Show Previous Tab (Bracket)",
          accelerator: "CmdOrCtrl+Shift+[",
          visible: false,
          click: (_item, win) => actions.selectPreviousTab(win instanceof BrowserWindow ? win : undefined),
        },
        ...(isMac
          ? [
              { role: "moveTabToNewWindow" as const },
              { role: "mergeAllWindows" as const },
            ]
          : []),
        { type: "separator" },
        ...tabNumberItems,
        ...(isMac ? [{ type: "separator" as const }, { role: "front" as const }] : []),
      ],
    },
    {
      label: "Help",
      submenu: [
        {
          label: "Change Server URL…",
          click: () => actions.openSettings(),
        },
        {
          label: "Vesper Repository & Docs",
          click: () => {
            void shell.openExternal("https://github.com/liamphmurphy/vesper").catch(() => {});
          },
        },
      ],
    },
  ];

  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}
