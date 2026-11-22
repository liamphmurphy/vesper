import { Suspense, type ReactNode } from "react";
import { KnowledgeChatProvider } from "./_components/chat-context";

export default function KnowledgeLayout({ children }: { children: ReactNode }) {
  // The native macOS shell hosts the Knowledge explorer, home, search, and connect screens.
  // Keep only the chat context and full-height flex container for hosted page and graph routes.
  return (
    <Suspense fallback={null}>
      <KnowledgeChatProvider>
        <div className="flex h-dvh min-h-0 min-w-0 flex-none flex-col bg-bg">{children}</div>
      </KnowledgeChatProvider>
    </Suspense>
  );
}
