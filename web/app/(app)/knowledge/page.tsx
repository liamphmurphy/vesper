import { use } from "react";
import { parseKind } from "@/lib/knowledge";
import { KnowledgeHome } from "./_components/home";
import { KindStart } from "./_components/start-view";

// ?kind= shows that kind's start page (Documents, Decks, Designs); anything else is Home.
export default function Page({ searchParams }: PageProps<"/knowledge">) {
  const kind = parseKind(use(searchParams).kind);
  return kind ? <KindStart key={kind} kind={kind} /> : <KnowledgeHome />;
}
